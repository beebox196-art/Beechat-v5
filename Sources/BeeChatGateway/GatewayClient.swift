import Foundation

public actor GatewayClient {
    public struct Configuration: Sendable {
        public let url: String
        public let token: String
        public let deviceToken: String?
        public let clientInfo: ConnectParams.ClientInfo
        public let clientMode: String
        public let requestTimeout: TimeInterval
        public let maxRetries: Int
        public let baseRetryDelay: TimeInterval
        public let maxRetryDelay: TimeInterval
        
        public init(
            url: String,
            token: String,
            deviceToken: String? = nil,
            clientMode: String = "webchat",
            clientInfo: ConnectParams.ClientInfo? = nil,
            requestTimeout: TimeInterval = 30.0,
            maxRetries: Int = 10,
            baseRetryDelay: TimeInterval = 1.0,
            maxRetryDelay: TimeInterval = 30.0
        ) {
            self.url = url
            self.token = token
            self.deviceToken = deviceToken
            self.clientMode = clientMode
            self.clientInfo = clientInfo ?? .init(id: "beechat", version: "1.0", platform: "macos", mode: clientMode)
            self.requestTimeout = requestTimeout
            self.maxRetries = maxRetries
            self.baseRetryDelay = baseRetryDelay
            self.maxRetryDelay = maxRetryDelay
        }
    }
    
    private let config: Configuration
    private let transport = WebSocketTransport()
    private let pendingRequests = PendingRequestMap()
    private let backoff: BackoffCalculator
    private var tokenStore: TokenStore
    
    private var state: ConnectionState = .disconnected
    private var retryCount = 0
    private var _maxPayload: Int = 1048576
    private var currentDeviceToken: String?
    private var challengeNonce: String?
    
    private var eventContinuation: AsyncStream<(event: String, payload: [String: AnyCodable]?)>.Continuation?
    
    private var nextRequestId: Int = 0

    public var connectionState: ConnectionState { state }
    public var maxPayload: Int { _maxPayload }
    
    public var onStatusChange: ((ConnectionState) -> Void)?
    public var onDeviceToken: ((String) -> Void)?

    public func updateOnStatusChange(_ callback: @escaping (ConnectionState) -> Void) {
        self.onStatusChange = callback
    }

    public init(config: Configuration, tokenStore: TokenStore = KeychainTokenStore()) {
        self.config = config
        self.tokenStore = tokenStore
        self.currentDeviceToken = config.deviceToken
        self.backoff = BackoffCalculator(baseDelay: config.baseRetryDelay, maxDelay: config.maxRetryDelay, maxRetries: config.maxRetries)
    }
    
    public func connect() async {
        await disconnect()
        retryCount = 0
        await performConnect()
    }
    
    public func disconnect() async {
        eventContinuation?.finish()
        eventContinuation = nil
        transport.disconnect()
        await pendingRequests.clearAll(reason: "Client disconnected")
        updateState(.disconnected)
    }
    
    public func call(method: String, params: [String: AnyCodable]? = nil) async throws -> [String: AnyCodable] {
        guard state == .connected || method == "connect" else {
            throw NSError(domain: "GatewayClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        
        let id = "bc-\(nextRequestId)"
        nextRequestId += 1
        let frame = RequestFrame(id: id, method: method, params: params)
        
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await pendingRequests.add(id: id, timeout: config.requestTimeout, resolve: { payload in
                    continuation.resume(returning: payload)
                }, reject: { error in
                    continuation.resume(throwing: error)
                })
                
                do {
                    let data = try JSONEncoder().encode(frame)
                    if let jsonString = String(data: data, encoding: .utf8) {
                        try await transport.send(jsonString)
                    }
                } catch {
                    await pendingRequests.remove(id: id, reason: error.localizedDescription)
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func eventStream() -> AsyncStream<(event: String, payload: [String: AnyCodable]?)> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }
    
    private func performConnect() async {
        updateState(.connecting)
        
        guard let url = URL(string: "\(config.url)?token=\(config.token)") else {
            updateState(.error)
            return
        }
        
        transport.connect(url: url)
        
        // Handle close events from transport
        transport.onClose = { [weak self] code, reason in
            Task { await self?.handleClose(code: code, reason: reason) }
        }
        
        Task {
            do {
                while state != .disconnected && state != .error {
                    let message = try await transport.receive()
                    switch message {
                    case .string(let text):
                        await handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                }
            } catch {
                await handleTransportError(error)
            }
        }
    }
    
    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        
        do {
            let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
            let type = raw["type"]?.value as? String
            
            switch type {
            case "event":
                var eventFrame = try JSONDecoder().decode(EventFrame.self, from: data)
                eventFrame.rawData = data
                await handleEvent(eventFrame)
            case "res":
                var resFrame = try JSONDecoder().decode(ResponseFrame.self, from: data)
                resFrame.rawData = data
                await handleResponse(resFrame)
            default:
                break
            }
        } catch {
            print("Failed to decode frame: \(error)")
        }
    }
    
    private func handleEvent(_ frame: EventFrame) async {
        if frame.event == "connect.challenge" {
            self.challengeNonce = frame.payload?["nonce"]?.value as? String
            await performHandshake()
            return
        }
        
        eventContinuation?.yield((event: frame.event, payload: frame.payload))
    }
    
    private func handleResponse(_ frame: ResponseFrame) async {
        if frame.id == "handshake" { // Special ID for handshake
            await handleHelloOk(frame)
        } else {
            await pendingRequests.resolve(id: frame.id, payload: frame.payload ?? [:])
        }
    }
    
    private func handleHelloOk(_ frame: ResponseFrame) async {
        // In a real implementation, the 'connect' call response is the HelloOk object
        // For this simplified version, we treat the response payload as HelloOk
        guard let data = frame.rawData else { return }
        
        do {
            let helloOk = try JSONDecoder().decode(HelloOk.self, from: data)
            self._maxPayload = helloOk.policy.maxPayload
            
            if let deviceToken = helloOk.auth?.deviceToken {
                self.currentDeviceToken = deviceToken
                try? tokenStore.setDeviceToken(deviceToken)
                onDeviceToken?(deviceToken)
            }
            
            retryCount = 0
            updateState(.connected)
        } catch {
            updateState(.error)
        }
    }
    
    private func performHandshake() async {
        updateState(.handshaking)
        
        guard let nonce = challengeNonce else {
            updateState(.error)
            return
        }
        
        var device: DeviceIdentity?
        if let deviceToken = currentDeviceToken {
            do {
                let key = try DeviceCrypto.getOrCreateKeyPair()
                let deviceId = try DeviceCrypto.getDeviceId(key)
                let pubKey = try DeviceCrypto.exportPublicKey(key)
                let signedAt = Int(Date().timeIntervalSince1970 * 1000)
                
                let signature = try DeviceCrypto.signChallenge(
                    key,
                    deviceId: deviceId,
                    clientId: config.clientInfo.id,
                    clientMode: config.clientMode,
                    role: "operator",
                    scopes: ["operator.read", "operator.write"],
                    signedAtMs: signedAt,
                    token: config.token,
                    nonce: nonce
                )
                
                device = DeviceIdentity(id: deviceId, publicKey: pubKey, signature: signature, signedAt: signedAt, nonce: nonce)
            } catch {
                print("Handshake crypto failed: \(error)")
            }
        }
        
        let params = ConnectParams(
            client: config.clientInfo,
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            caps: nil,
            commands: nil,
            permissions: nil,
            auth: .init(token: config.token, deviceToken: currentDeviceToken),
            locale: nil,
            userAgent: nil,
            device: device
        )
        
        do {
            let id = "handshake"
            let frame = RequestFrame(id: id, method: "connect", params: try encodeParams(params))
            let data = try JSONEncoder().encode(frame)
            try await transport.send(String(data: data, encoding: .utf8)!)
            
            await pendingRequests.add(id: id, timeout: config.requestTimeout, resolve: { payload in
                Task { await self.handleResponse(ResponseFrame(type: "res", id: id, ok: true, payload: payload, error: nil)) }
            }, reject: { error in
                Task { self.updateState(.error) }
            })
        } catch {
            updateState(.error)
        }
    }
    
    private func handleTransportError(_ error: Error) async {
        if retryCount < config.maxRetries {
            let delay = backoff.delay(forAttempt: retryCount)
            retryCount += 1
            updateState(.connecting)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await performConnect()
        } else {
            updateState(.error)
        }
    }

    private func handleClose(code: Int, reason: String?) async {
        if code == 1008 || (code >= 4000 && code <= 4999) {
            updateState(.error)
        } else {
            await handleTransportError(NSError(domain: "WebSocketTransport", code: code, userInfo: [NSLocalizedDescriptionKey: reason ?? "Connection closed"]))
        }
    }
    
    private func updateState(_ newState: ConnectionState) {
        state = newState
        onStatusChange?(newState)
    }
    
    private func encodeParams<T: Encodable>(_ params: T) throws -> [String: AnyCodable] {
        let data = try JSONEncoder().encode(params)
        let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        return raw
    }
}
