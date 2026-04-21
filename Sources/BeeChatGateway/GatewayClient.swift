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

    public func updateOnStatusChange(_ callback: @escaping (ConnectionState) -> Void) {
        stateObservers.append(callback)
    }
    
    public func removeStatusChangeObserver(_ callback: @escaping (ConnectionState) -> Void) {
        // Remove by identity (closures aren't Equatable, so clear all and re-add non-matching)
        // In practice, we just keep appending; dedup isn't critical
    }

    public init(config: Configuration, tokenStore: TokenStore = KeychainTokenStore()) {
        self.config = config
        self.tokenStore = tokenStore
        // Load stored device token from Keychain if available
        self.currentDeviceToken = config.deviceToken ?? (try? tokenStore.getDeviceToken())
        self.backoff = BackoffCalculator(baseDelay: config.baseRetryDelay, maxDelay: config.maxRetryDelay, maxRetries: config.maxRetries)
    }
    
    /// Connect to the gateway and wait for the handshake to complete.
    /// Throws if the handshake fails or times out.
    public func connect() async throws {
        print("[GW] connect() called — current state=\(state.rawValue)")
        await disconnect()
        retryCount = 0
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.handshakeContinuation = continuation
            Task {
                await self.performConnect()
            }
        }
    }
    
    public func disconnect() async {
        print("[GW] disconnect() called — state=\(state.rawValue)")
        handshakeContinuation = nil
        eventContinuation?.finish()
        eventContinuation = nil
        transport.disconnect()
        await pendingRequests.clearAll(reason: "Client disconnected")
        updateState(.disconnected)
        print("[GW] disconnect() complete — state=\(state.rawValue)")
    }
    
    public func call(method: String, params: [String: AnyCodable]? = nil) async throws -> [String: AnyCodable] {
        print("[GW] call() — method=\(method) state=\(state.rawValue)")
        guard state == .connected else {
            print("[GW] call() REJECTED — not connected (state=\(state.rawValue))")
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
        print("[GW] performConnect() — setting state to .connecting")
        updateState(.connecting)
        
        guard let url = URL(string: "\(config.url)?token=\(config.token)") else {
            print("[GW] performConnect() — invalid URL")
            updateState(.error)
            handshakeContinuation?.resume(throwing: NSError(domain: "GatewayClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid gateway URL"]))
            handshakeContinuation = nil
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
        print("[GW] Transport connect initiated")
        
        // Handle close events from transport
        transport.onClose = { [weak self] code, reason in
            print("[GW] onClose callback — code=\(code) reason=\(reason ?? "n/a")")
            Task { await self?.handleClose(code: code, reason: reason) }
        }
        
        Task {
            print("[GW] Message loop starting — state=\(self.state.rawValue)")
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
                print("[GW] Message loop exited normally — state=\(self.state.rawValue)")
            } catch {
                print("[GW] Message loop error: \(error)")
                await handleTransportError(error)
            }
        }
    }
    
    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        
        do {
            let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
            let type = raw["type"]?.value as? String
            let frameId = raw["id"]?.value as? String ?? raw["event"]?.value as? String ?? "?"
            print("[GW] handleMessage — type=\(type ?? "nil") id/event=\(frameId)")
            
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
                print("[GW] handleMessage — unknown type: \(type ?? "nil")")
                break
            }
        } catch {
            print("[GW] Failed to decode frame: \(error)")
        }
    }
    
    private func handleEvent(_ frame: EventFrame) async {
        print("[GW] handleEvent — event=\(frame.event)")
        if frame.event == "connect.challenge" {
            self.challengeNonce = frame.payload?["nonce"]?.value as? String
            print("[GW] Received connect.challenge — nonce=\(self.challengeNonce?.prefix(8) ?? "nil")...")
            await performHandshake()
            return
        }
        
        if eventContinuation != nil {
            eventContinuation?.yield((event: frame.event, payload: frame.payload))
        } else {
            print("[GW] Event dropped — no eventContinuation: \(frame.event)")
        }
    }
    
    private func handleResponse(_ frame: ResponseFrame) async {
        print("[GW] handleResponse — id=\(frame.id) ok=\(frame.ok)")
        if frame.id == "handshake" {
            // Handshake response — handle directly, don't route to pendingRequests
            // (the pending request for "handshake" is handled by resolveHandshake)
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
    
    /// Process the handshake (hello-ok) response and resume the connect() continuation.
    /// This is the SINGLE handler for the handshake — no double-handling.
    private func resolveHandshake(_ frame: ResponseFrame) async {
        if !frame.ok {
            print("[GW] Handshake rejected: \(frame.error?.message ?? "unknown")")
            let error = NSError(domain: "GatewayClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "Handshake failed: \(frame.error?.message ?? "unknown")"])
            updateState(.error)
            handshakeContinuation?.resume(throwing: error)
            handshakeContinuation = nil
            return
        }
        
        guard let payload = frame.payload else {
            print("[GW] HelloOk: no payload in response")
            let error = NSError(domain: "GatewayClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "Handshake response missing payload"])
            updateState(.error)
            handshakeContinuation?.resume(throwing: error)
            handshakeContinuation = nil
            return
        }
        
        do {
            let payloadData = try JSONEncoder().encode(payload)
            let helloOk = try JSONDecoder().decode(HelloOk.self, from: payloadData)
            self._maxPayload = helloOk.policy.maxPayload
            
            print("[GW] HelloOk decoded — server=\(helloOk.server.version) protocol=\(helloOk.protocol)")
            
            if let deviceToken = helloOk.auth?.deviceToken {
                self.currentDeviceToken = deviceToken
                try? tokenStore.setDeviceToken(deviceToken)
                onDeviceToken?(deviceToken)
                print("[GW] Device token persisted: \(deviceToken.prefix(8))...")
            } else {
                print("[GW] No deviceToken in hello-ok — role=\(helloOk.auth?.role ?? "nil"), scopes=\(helloOk.auth?.scopes ?? [])")
            }
            
            retryCount = 0
            updateState(.connected)
            
            // Resume the connect() continuation — handshake is complete
            handshakeContinuation?.resume(returning: ())
            handshakeContinuation = nil
            
            print("[GW] Handshake complete — connected")
        } catch {
            print("[GW] HelloOk decode error: \(error)")
            let err = NSError(domain: "GatewayClient", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to decode hello-ok: \(error.localizedDescription)"])
            updateState(.error)
            handshakeContinuation?.resume(throwing: err)
            handshakeContinuation = nil
        }
    }
    
    private func performHandshake() async {
        print("[GW] performHandshake() — setting state to .handshaking")
        updateState(.handshaking)
        
        guard let nonce = challengeNonce else {
            print("[GW] performHandshake — no challenge nonce!")
            let error = NSError(domain: "GatewayClient", code: -5, userInfo: [NSLocalizedDescriptionKey: "No challenge nonce available"])
            updateState(.error)
            handshakeContinuation?.resume(throwing: error)
            handshakeContinuation = nil
            return
        }
        
        let role = "operator"
        let scopes = ["operator.read", "operator.write", "operator.approvals", "operator.pairing"]
        
        // Build device identity only when we have a stored deviceToken
        var deviceIdentity: ConnectParams.DeviceIdentity? = nil
        if currentDeviceToken != nil {
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
                print("[GW] Built device identity: id=\(deviceId.prefix(8))...")
            } catch {
                print("[GW] Failed to build device identity, connecting without it: \(error)")
            }
        } else {
            print("[GW] No stored deviceToken — connecting without device identity (first connection)")
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
            let id = "handshake"
            let frame = RequestFrame(id: id, method: "connect", params: try encodeParams(params))
            let data = try JSONEncoder().encode(frame)
            if let jsonStr = String(data: data, encoding: .utf8) {
                print("[GW] Sending connect: \(jsonStr.prefix(500))")
            }
            try await transport.send(String(data: data, encoding: .utf8)!)
            
            // Set up a timeout for the handshake response
            // The message loop will receive the response and call resolveHandshake()
            // If it doesn't arrive in time, we need to fail the handshake
            Task {
                try? await Task.sleep(nanoseconds: UInt64(config.requestTimeout * 1_000_000_000))
                // If we get here, the handshake hasn't completed yet
                if self.state == .handshaking {
                    print("[GW] Handshake timed out after \(self.config.requestTimeout)s")
                    let error = NSError(domain: "GatewayClient", code: -6, userInfo: [NSLocalizedDescriptionKey: "Handshake timed out"])
                    self.updateState(.error)
                    self.handshakeContinuation?.resume(throwing: error)
                    self.handshakeContinuation = nil
                }
            }
        } catch {
            print("[GW] Failed to send handshake: \(error)")
            updateState(.error)
            handshakeContinuation?.resume(throwing: error)
            handshakeContinuation = nil
        }
    }
    
    private func handleTransportError(_ error: Error) async {
        print("[GW] handleTransportError — error=\(error.localizedDescription) retryCount=\(retryCount)/\(config.maxRetries)")
        
        // If we're still waiting for handshake, fail it
        if state == .connecting || state == .handshaking {
            let err = NSError(domain: "GatewayClient", code: -7, userInfo: [NSLocalizedDescriptionKey: "Connection failed: \(error.localizedDescription)"])
            handshakeContinuation?.resume(throwing: err)
            handshakeContinuation = nil
        }
        
        if retryCount < config.maxRetries {
            let delay = backoff.delay(forAttempt: retryCount)
            retryCount += 1
            print("[GW] Retrying in \(delay)s...")
            updateState(.connecting)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await performConnect()
        } else {
            print("[GW] Max retries reached — giving up")
            updateState(.error)
        }
    }

    private func handleClose(code: Int, reason: String?) async {
        print("[GW] handleClose — code=\(code) reason=\(reason ?? "n/a") state=\(state.rawValue)")
        
        // If we're still in handshake, fail it
        if state == .connecting || state == .handshaking {
            let err = NSError(domain: "GatewayClient", code: code, userInfo: [NSLocalizedDescriptionKey: reason ?? "Connection closed during handshake"])
            handshakeContinuation?.resume(throwing: err)
            handshakeContinuation = nil
        }
        
        if code == 1008 || (code >= 4000 && code <= 4999) {
            // Policy violation or application error — no reconnect
            print("[GW] Close code is fatal — setting error state")
            updateState(.error)
        } else if state == .connected {
            // Connection was established and then closed.
            // Don't auto-reconnect — let the application layer handle it.
            // Transition to disconnected so the app can decide to reconnect.
            print("[GW] Connection closed while connected — transitioning to disconnected")
            updateState(.disconnected)
        } else if state != .disconnected && state != .error {
            // Still connecting — attempt reconnect
            print("[GW] Close code during connect — attempting reconnect")
            await handleTransportError(NSError(domain: "WebSocketTransport", code: code, userInfo: [NSLocalizedDescriptionKey: reason ?? "Connection closed"]))
        }
    }
    
    private func updateState(_ newState: ConnectionState) {
        let oldState = state
        state = newState
        print("[GW] updateState: \(oldState.rawValue) -> \(newState.rawValue)")
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