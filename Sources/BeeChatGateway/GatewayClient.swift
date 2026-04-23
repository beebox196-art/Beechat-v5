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
            clientMode: String = "ui",
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
            self.clientInfo = clientInfo ?? .init(id: "openclaw-macos", version: "1.0", platform: "macos", mode: clientMode)
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
    
    /// Continuation that fires when the state machine reaches .connected or .error,
    /// used by connect() to await handshake completion.
    private var handshakeContinuation: CheckedContinuation<Void, Error>?
    
    /// Whether the handshake continuation has already been resumed (prevents double-resume)
    private var handshakeContinuationResumed = false
    
    private var nextRequestId: Int = 0

    private var stateObservers: [(ConnectionState) -> Void] = []
    
    public var connectionState: ConnectionState { state }
    public var maxPayload: Int { _maxPayload }
    
    public var onStatusChange: ((ConnectionState) -> Void)? {
        get { stateObservers.first }
        set {
            if let callback = newValue {
                if stateObservers.isEmpty {
                    stateObservers.append(callback)
                } else {
                    stateObservers[0] = callback
                }
            } else {
                stateObservers.removeAll()
            }
        }
    }
    public var onDeviceToken: ((String) -> Void)?

    public func updateConnectionStateObserver(_ callback: @escaping (ConnectionState) -> Void) {
        stateObservers.append(callback)
    }



    public init(config: Configuration, tokenStore: TokenStore = KeychainTokenStore()) {
        self.config = config
        self.tokenStore = tokenStore
        // Load stored device token from Keychain if available
        self.currentDeviceToken = config.deviceToken ?? (try? tokenStore.getDeviceToken())
        self.backoff = BackoffCalculator(baseDelay: config.baseRetryDelay, maxDelay: config.maxRetryDelay, maxRetries: config.maxRetries)
    }
    
    public func connect() async throws {
        handshakeContinuationResumed = false
        await disconnect()
        retryCount = 0
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.handshakeContinuation = continuation
            Task { await self.performConnect() }
        }
        
        if state != .connected {
            throw NSError(domain: "GatewayClient", code: -99, userInfo: [NSLocalizedDescriptionKey: "Handshake completed but state is \(state.rawValue), not connected"])
        }
    }
    
    public func disconnect() async {
        if let cont = handshakeContinuation, !handshakeContinuationResumed {
            handshakeContinuationResumed = true
            cont.resume(throwing: NSError(domain: "GatewayClient", code: -98, userInfo: [NSLocalizedDescriptionKey: "Disconnected during handshake"]))
        }
        handshakeContinuation = nil
        eventContinuation?.finish()
        eventContinuation = nil
        transport.disconnect()
        await pendingRequests.clearAll(reason: "Client disconnected")
        updateState(.disconnected)
    }
    
    public func call(method: String, params: [String: AnyCodable]? = nil) async throws -> [String: AnyCodable] {
        guard state == .connected else {
            throw NSError(domain: "GatewayClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Not connected (state: \(state.rawValue))"])
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
                    try await transport.send(String(data: data, encoding: .utf8)!) 
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
            failHandshake("Invalid gateway URL")
            return
        }
        
        // Native app — set Origin to gateway host so it passes validation
        let origin: String
        if config.url.contains("127.0.0.1") || config.url.contains("localhost") {
            origin = "http://localhost:18789"
        } else {
            origin = config.url.replacingOccurrences(of: "ws://", with: "http://").replacingOccurrences(of: "wss://", with: "https://")
        }
        
        transport.connect(url: url, origin: origin)
        
        transport.onClose = { [weak self] code, reason in
            Task { await self?.handleClose(code: code, reason: reason) }
        }
        
        Task {
            do {
                while self.state != .disconnected && self.state != .error {
                    let message = try await self.transport.receive()
                    switch message {
                    case .string(let text):
                        await self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                }
            } catch {
                await self.handleTransportError(error)
            }
        }
    }
    
    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8) else {
            return
        }
        
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
            print("[GW] handleMessage decode error: \(error)")
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
        if frame.id == "handshake" {
            await resolveHandshake(frame)
            return
        }
        
        if !frame.ok {
            await pendingRequests.reject(id: frame.id, error: NSError(
                domain: "GatewayClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: frame.error?.message ?? "RPC error"]
            ))
        } else {
            await pendingRequests.resolve(id: frame.id, payload: frame.payload ?? [:])
        }
    }
    
    private func succeedHandshake() {
        guard !handshakeContinuationResumed, let cont = handshakeContinuation else { return }
        handshakeContinuationResumed = true
        handshakeContinuation = nil
        cont.resume(returning: ())
    }
    
    private func failHandshake(_ message: String, code: Int = -1) {
        guard !handshakeContinuationResumed, let cont = handshakeContinuation else { return }
        handshakeContinuationResumed = true
        handshakeContinuation = nil
        cont.resume(throwing: NSError(domain: "GatewayClient", code: code, userInfo: [NSLocalizedDescriptionKey: message]))
    }
    
    private func resolveHandshake(_ frame: ResponseFrame) async {
        if !frame.ok {
            let msg = frame.error?.message ?? "unknown error"
            updateState(.error)
            failHandshake("Handshake failed: \(msg)", code: -2)
            return
        }
        
        var helloOk: HelloOk?
        
        // Attempt 1: Decode from rawData
        if let rawData = frame.rawData {
            do {
                let rawJson = try JSONSerialization.jsonObject(with: rawData) as? [String: Any]
                if let payloadObj = rawJson?["payload"] as? [String: Any] {
                    let payloadData = try JSONSerialization.data(withJSONObject: payloadObj)
                    helloOk = try JSONDecoder().decode(HelloOk.self, from: payloadData)
                }
            } catch {}
        }
        
        // Attempt 2: Decode from frame.payload via AnyCodable round-trip
        if helloOk == nil, let payload = frame.payload {
            do {
                let payloadData = try JSONEncoder().encode(payload)
                helloOk = try JSONDecoder().decode(HelloOk.self, from: payloadData)
            } catch {}
        }
        
        // Attempt 3: Manual partial decode
        if helloOk == nil, let payload = frame.payload {
            helloOk = manuallyDecodeHelloOk(payload: payload)
        }
        
        if let helloOk = helloOk {
            self._maxPayload = helloOk.policy.maxPayload
            
            if let deviceToken = helloOk.auth?.deviceToken {
                self.currentDeviceToken = deviceToken
                try? tokenStore.setDeviceToken(deviceToken)
                onDeviceToken?(deviceToken)
            }
        }
        
        retryCount = 0
        updateState(.connected)
        succeedHandshake()
    }
    
    private func manuallyDecodeHelloOk(payload: [String: AnyCodable]) -> HelloOk? {
        let protocolVersion = (payload["protocol"]?.value as? Int) ?? 3
        let maxPayload = (payload["policy"]?.value as? [String: Any])?["maxPayload"] as? Int
            ?? (payload["policy"]?.value as? [String: AnyCodable])?["maxPayload"]?.value as? Int
            ?? 1048576
        
        // Extract server info
        var serverConnId: String? = nil
        var serverVersion: String = "unknown"
        if let serverAny = payload["server"]?.value {
            if let serverDict = serverAny as? [String: Any] {
                serverConnId = serverDict["connId"] as? String ?? serverDict["id"] as? String
                serverVersion = serverDict["version"] as? String ?? "unknown"
            } else if let serverDict = serverAny as? [String: AnyCodable] {
                serverConnId = serverDict["connId"]?.value as? String ?? serverDict["id"]?.value as? String
                serverVersion = serverDict["version"]?.value as? String ?? "unknown"
            }
        }
        
        // Extract auth info
        var authDeviceToken: String? = nil
        var authRole: String? = nil
        var authScopes: [String]? = nil
        if let authAny = payload["auth"]?.value {
            if let authDict = authAny as? [String: Any] {
                authDeviceToken = authDict["deviceToken"] as? String
                authRole = authDict["role"] as? String
                authScopes = authDict["scopes"] as? [String]
            } else if let authDict = authAny as? [String: AnyCodable] {
                authDeviceToken = authDict["deviceToken"]?.value as? String
                authRole = authDict["role"]?.value as? String
                authScopes = authDict["scopes"]?.value as? [String]
            }
            // Empty dict {} is valid — all fields are nil
        }
        
        // Extract features
        var featuresMethods: [String]? = nil
        var featuresEvents: [String]? = nil
        if let featuresAny = payload["features"]?.value {
            if let featuresDict = featuresAny as? [String: Any] {
                featuresMethods = featuresDict["methods"] as? [String]
                featuresEvents = featuresDict["events"] as? [String]
            } else if let featuresDict = featuresAny as? [String: AnyCodable] {
                featuresMethods = featuresDict["methods"]?.value as? [String]
                featuresEvents = featuresDict["events"]?.value as? [String]
            }
        }
        
        // Build the HelloOk struct
        let helloOk = HelloOk(
            type: (payload["type"]?.value as? String) ?? "hello-ok",
            protocol: protocolVersion,
            server: .init(connId: serverConnId, version: serverVersion),
            features: .init(methods: featuresMethods, events: featuresEvents),
            snapshot: payload["snapshot"] != nil ? payload : nil,
            policy: .init(maxPayload: maxPayload),
            auth: .init(deviceToken: authDeviceToken, role: authRole, scopes: authScopes)
        )
        
        return helloOk
    }
    
    private func performHandshake() async {
        updateState(.handshaking)
        
        guard let nonce = challengeNonce else {
            failHandshake("No challenge nonce available", code: -5)
            return
        }
        
        let role = "operator"
        let scopes = ["operator.read", "operator.write", "operator.approvals", "operator.pairing"]
        
        // Build device identity only when we have a stored deviceToken
        var deviceIdentity: ConnectParams.DeviceIdentity? = nil
        if currentDeviceToken != nil {
            print("[GW] performHandshake — building device identity (have deviceToken)")
            do {
                let keyPair = try DeviceCrypto.getOrCreateKeyPair()
                let deviceId = DeviceCrypto.getDeviceId(keyPair)
                let publicKey = DeviceCrypto.exportPublicKey(keyPair)
                let signedAt = Int(Date().timeIntervalSince1970 * 1000)
                
                let signature = try DeviceCrypto.signChallenge(
                    keyPair,
                    deviceId: deviceId,
                    clientId: config.clientInfo.id,
                    clientMode: config.clientInfo.mode,
                    role: role,
                    scopes: scopes,
                    signedAtMs: signedAt,
                    token: config.token,
                    nonce: nonce,
                    platform: "macos",
                    deviceFamily: "desktop"
                )
                
                deviceIdentity = ConnectParams.DeviceIdentity(
                    id: deviceId,
                    publicKey: publicKey,
                    signature: signature,
                    signedAt: signedAt,
                    nonce: nonce
                )
            } catch {
                // Device identity optional — connect without it
            }
        }
        
        let params = ConnectParams(
            client: config.clientInfo,
            role: role,
            scopes: scopes,
            caps: ["tool-events"],
            commands: nil,
            permissions: nil,
            auth: .init(
                token: config.token,
                deviceToken: currentDeviceToken
            ),
            locale: Locale.current.identifier,
            userAgent: "BeeChat/1.0 (macOS)",
            device: deviceIdentity
        )
        
        do {
            let frame = RequestFrame(id: "handshake", method: "connect", params: try encodeParams(params))
            let data = try JSONEncoder().encode(frame)
            try await transport.send(String(data: data, encoding: .utf8)!)
            
            let timeoutSeconds = config.requestTimeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                if self.state == .handshaking {
                    self.updateState(.error)
                    self.failHandshake("Handshake timed out after \(timeoutSeconds)s", code: -6)
                }
            }
        } catch {
            updateState(.error)
            failHandshake("Failed to send handshake: \(error.localizedDescription)", code: -8)
        }
    }
    
    private func handleTransportError(_ error: Error) async {
        if state == .connecting || state == .handshaking {
            updateState(.error)
            failHandshake("Connection failed: \(error.localizedDescription)", code: -7)
        }
        
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
        if state == .connecting || state == .handshaking {
            updateState(.error)
            failHandshake(reason ?? "Connection closed during handshake (code: \(code))", code: code)
            return
        }
        
        if code == 1008 || (code >= 4000 && code <= 4999) {
            updateState(.error)
        } else if state == .connected {
            updateState(.disconnected)
        } else if state != .disconnected && state != .error {
            await handleTransportError(NSError(domain: "WebSocketTransport", code: code, userInfo: [NSLocalizedDescriptionKey: reason ?? "Connection closed"]))
        }
    }
    
    private func updateState(_ newState: ConnectionState) {
        state = newState
        for observer in stateObservers {
            observer(newState)
        }
    }
    
    private func encodeParams<T: Encodable>(_ params: T) throws -> [String: AnyCodable] {
        let data = try JSONEncoder().encode(params)
        let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        return raw
    }
}