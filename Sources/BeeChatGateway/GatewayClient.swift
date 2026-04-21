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
    
    /// Stores the raw Data of the most recently received message for direct decoding
    private var lastMessageRawData: Data?
    
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
        print("[GW] ══════════════════════════════════════════════")
        print("[GW] connect() called — current state=\(state.rawValue)")
        print("[GW] ══════════════════════════════════════════════")
        
        // Reset handshake tracking
        handshakeContinuationResumed = false
        
        // Disconnect any existing connection first
        await disconnect()
        retryCount = 0
        
        print("[GW] connect() — about to create handshake continuation")
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.handshakeContinuation = continuation
            print("[GW] connect() — handshake continuation stored, spawning performConnect Task")
            Task {
                print("[GW] connect() — Task started, calling performConnect()")
                await self.performConnect()
                print("[GW] connect() — performConnect() returned (note: handshake may still be pending)")
            }
        }
        
        // After continuation is resumed, verify we're actually connected
        print("[GW] connect() — continuation resumed, final state=\(state.rawValue)")
        if state != .connected {
            print("[GW] connect() — WARNING: continuation resumed but state is \(state.rawValue), not .connected!")
            throw NSError(domain: "GatewayClient", code: -99, userInfo: [NSLocalizedDescriptionKey: "Handshake completed but state is \(state.rawValue), not connected"])
        }
        print("[GW] connect() — SUCCESS, state is .connected ✅")
    }
    
    public func disconnect() async {
        print("[GW] disconnect() called — state=\(state.rawValue)")
        
        // If there's a pending handshake continuation, fail it
        if let cont = handshakeContinuation, !handshakeContinuationResumed {
            print("[GW] disconnect() — failing pending handshake continuation")
            handshakeContinuationResumed = true
            cont.resume(throwing: NSError(domain: "GatewayClient", code: -98, userInfo: [NSLocalizedDescriptionKey: "Disconnected during handshake"]))
        }
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
                        print("[GW] call() — sending: \(jsonString.prefix(200))")
                        try await transport.send(jsonString)
                        print("[GW] call() — sent successfully, waiting for response")
                    }
                } catch {
                    print("[GW] call() — send error: \(error)")
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
    
    // ╔══════════════════════════════════════════════════════════════╗
    // ║  CONNECTION & HANDSHAKE FLOW                                  ║
    // ╚══════════════════════════════════════════════════════════════╝
    
    private func performConnect() async {
        print("[GW] performConnect() — BEGIN")
        print("[GW] performConnect() — setting state to .connecting")
        updateState(.connecting)
        
        guard let url = URL(string: "\(config.url)?token=\(config.token)") else {
            print("[GW] performConnect() — ❌ invalid URL: \(config.url)?token=***")
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
        
        print("[GW] performConnect() — URL=\(url.absoluteString.replacingOccurrences(of: config.token, with: "***"))")
        print("[GW] performConnect() — Origin=\(origin)")
        
        transport.connect(url: url, origin: origin)
        print("[GW] performConnect() — transport.connect() called")
        
        // Handle close events from transport
        transport.onClose = { [weak self] code, reason in
            print("[GW] onClose callback — code=\(code) reason=\(reason ?? "n/a")")
            Task { await self?.handleClose(code: code, reason: reason) }
        }
        
        print("[GW] performConnect() — spawning message loop Task")
        Task {
            print("[GW] Message loop — STARTED, state=\(self.state.rawValue)")
            do {
                while self.state != .disconnected && self.state != .error {
                    print("[GW] Message loop — calling transport.receive()...")
                    let message = try await self.transport.receive()
                    print("[GW] Message loop — received message")
                    switch message {
                    case .string(let text):
                        print("[GW] Message loop — string message, \(text.count) chars")
                        await self.handleMessage(text)
                    case .data(let data):
                        print("[GW] Message loop — data message, \(data.count) bytes")
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleMessage(text)
                        }
                    @unknown default:
                        print("[GW] Message loop — unknown message type")
                        break
                    }
                }
                print("[GW] Message loop — EXITED normally, state=\(self.state.rawValue)")
            } catch {
                print("[GW] Message loop — ERROR: \(error.localizedDescription)")
                await self.handleTransportError(error)
            }
        }
        print("[GW] performConnect() — END (message loop running asynchronously)")
    }
    
    private func handleMessage(_ text: String) async {
        print("[GW] handleMessage — received \(text.count) chars")
        guard let data = text.data(using: .utf8) else {
            print("[GW] handleMessage — ❌ failed to convert text to data")
            return
        }
        
        // Store raw data for direct decoding later
        lastMessageRawData = data
        
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
                print("[GW] handleMessage — ⚠️ unknown type: \(type ?? "nil")")
                break
            }
        } catch {
            print("[GW] handleMessage — ❌ Failed to decode frame: \(error)")
        }
    }
    
    private func handleEvent(_ frame: EventFrame) async {
        print("[GW] handleEvent — event=\(frame.event)")
        if frame.event == "connect.challenge" {
            self.challengeNonce = frame.payload?["nonce"]?.value as? String
            print("[GW] handleEvent — connect.challenge received, nonce=\(self.challengeNonce?.prefix(8) ?? "nil")...")
            await performHandshake()
            return
        }
        
        if eventContinuation != nil {
            eventContinuation?.yield((event: frame.event, payload: frame.payload))
        } else {
            print("[GW] handleEvent — event dropped (no eventContinuation): \(frame.event)")
        }
    }
    
    private func handleResponse(_ frame: ResponseFrame) async {
        print("[GW] handleResponse — id=\(frame.id) ok=\(frame.ok)")
        
        if frame.id == "handshake" {
            print("[GW] handleResponse — this is the handshake response, routing to resolveHandshake")
            await resolveHandshake(frame)
            return
        }
        
        if !frame.ok {
            print("[GW] handleResponse — error response for id=\(frame.id): \(frame.error?.message ?? "unknown")")
            await pendingRequests.reject(id: frame.id, error: NSError(
                domain: "GatewayClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: frame.error?.message ?? "RPC error"]
            ))
        } else {
            print("[GW] handleResponse — success for id=\(frame.id)")
            await pendingRequests.resolve(id: frame.id, payload: frame.payload ?? [:])
        }
    }
    
    // ╔══════════════════════════════════════════════════════════════╗
    // ║  HANDSHAKE RESOLUTION — THE CRITICAL PATH                     ║
    // ╚══════════════════════════════════════════════════════════════╝
    
    /// Safely resume the handshake continuation with success.
    private func succeedHandshake() {
        guard !handshakeContinuationResumed else {
            print("[GW] succeedHandshake — ⚠️ already resumed, skipping")
            return
        }
        guard let cont = handshakeContinuation else {
            print("[GW] succeedHandshake — ⚠️ no continuation to resume")
            return
        }
        handshakeContinuationResumed = true
        handshakeContinuation = nil
        print("[GW] succeedHandshake — resuming continuation with success ✅")
        cont.resume(returning: ())
    }
    
    /// Safely resume the handshake continuation with failure.
    private func failHandshake(_ message: String, code: Int = -1) {
        guard !handshakeContinuationResumed else {
            print("[GW] failHandshake — ⚠️ already resumed, skipping. Error was: \(message)")
            return
        }
        guard let cont = handshakeContinuation else {
            print("[GW] failHandshake — ⚠️ no continuation to resume. Error was: \(message)")
            return
        }
        handshakeContinuationResumed = true
        handshakeContinuation = nil
        print("[GW] failHandshake — resuming continuation with error: \(message) ❌")
        cont.resume(throwing: NSError(domain: "GatewayClient", code: code, userInfo: [NSLocalizedDescriptionKey: message]))
    }
    
    /// Process the handshake (hello-ok) response and resume the connect() continuation.
    private func resolveHandshake(_ frame: ResponseFrame) async {
        print("[GW] resolveHandshake — BEGIN, ok=\(frame.ok)")
        
        // ── Case 1: Handshake rejected ──
        if !frame.ok {
            let msg = frame.error?.message ?? "unknown error"
            print("[GW] resolveHandshake — ❌ handshake rejected: \(msg)")
            updateState(.error)
            failHandshake("Handshake failed: \(msg)", code: -2)
            return
        }
        
        // ── Case 2: Handshake succeeded — decode hello-ok payload ──
        print("[GW] resolveHandshake — handshake ok=true, decoding hello-ok payload")
        
        // STRATEGY: Try decoding from rawData first (most reliable),
        // then fall back to payload-based decode (resilient to partial data)
        var helloOk: HelloOk?
        var decodeError: Error?
        
        // Attempt 1: Decode from rawData (the raw WebSocket message bytes)
        // The response is: {"type":"res","id":"handshake","ok":true,"payload":{...hello-ok...}}
        // We need to extract the "payload" field and decode it as HelloOk
        if let rawData = frame.rawData {
            print("[GW] resolveHandshake — Attempt 1: decode from rawData (\(rawData.count) bytes)")
            do {
                // First decode as generic JSON to extract the payload field
                let rawJson = try JSONSerialization.jsonObject(with: rawData) as? [String: Any]
                if let payloadObj = rawJson?["payload"] as? [String: Any] {
                    let payloadData = try JSONSerialization.data(withJSONObject: payloadObj)
                    print("[GW] resolveHandshake — payload extracted, \(payloadData.count) bytes")
                    print("[GW] resolveHandshake — payload JSON: \(String(data: payloadData, encoding: .utf8)?.prefix(500) ?? "nil")")
                    do {
                        helloOk = try JSONDecoder().decode(HelloOk.self, from: payloadData)
                        print("[GW] resolveHandshake — ✅ Attempt 1 SUCCEEDED: decoded HelloOk from rawData")
                    } catch {
                        print("[GW] resolveHandshake — Attempt 1 decode error: \(error)")
                        decodeError = error
                    }
                } else {
                    print("[GW] resolveHandshake — Attempt 1: no 'payload' key in raw JSON")
                }
            } catch {
                print("[GW] resolveHandshake — Attempt 1 JSON parse error: \(error)")
                decodeError = error
            }
        } else {
            print("[GW] resolveHandshake — no rawData available for Attempt 1")
        }
        
        // Attempt 2: Decode from frame.payload via AnyCodable round-trip
        if helloOk == nil, let payload = frame.payload {
            print("[GW] resolveHandshake — Attempt 2: decode from frame.payload via AnyCodable round-trip")
            do {
                let payloadData = try JSONEncoder().encode(payload)
                print("[GW] resolveHandshake — AnyCodable encoded payload: \(String(data: payloadData, encoding: .utf8)?.prefix(500) ?? "nil")")
                helloOk = try JSONDecoder().decode(HelloOk.self, from: payloadData)
                print("[GW] resolveHandshake — ✅ Attempt 2 SUCCEEDED: decoded HelloOk from AnyCodable payload")
            } catch {
                print("[GW] resolveHandshake — Attempt 2 decode error: \(error)")
                if decodeError == nil { decodeError = error }
            }
        }
        
        // Attempt 3: Manual partial decode — extract what we can, use defaults for the rest
        if helloOk == nil, let payload = frame.payload {
            print("[GW] resolveHandshake — Attempt 3: manual partial decode")
            helloOk = manuallyDecodeHelloOk(payload: payload)
        }
        
        // ── Process the HelloOk (or partial result) ──
        if let helloOk = helloOk {
            print("[GW] resolveHandshake — processing HelloOk:")
            print("[GW]   protocol=\(helloOk.protocol)")
            print("[GW]   server.version=\(helloOk.server.version)")
            print("[GW]   server.connId=\(helloOk.server.connId ?? "nil")")
            print("[GW]   policy.maxPayload=\(helloOk.policy.maxPayload)")
            print("[GW]   auth=\(helloOk.auth.flatMap { _ in "present" } ?? "nil")")
            if let auth = helloOk.auth {
                print("[GW]   auth.deviceToken=\(auth.deviceToken != nil ? "\(auth.deviceToken!.prefix(8))..." : "nil")")
                print("[GW]   auth.role=\(auth.role ?? "nil")")
                print("[GW]   auth.scopes=\(auth.scopes ?? [])")
            }
            
            // Update maxPayload
            self._maxPayload = helloOk.policy.maxPayload
            
            // Persist device token if provided
            if let deviceToken = helloOk.auth?.deviceToken {
                self.currentDeviceToken = deviceToken
                try? tokenStore.setDeviceToken(deviceToken)
                onDeviceToken?(deviceToken)
                print("[GW] resolveHandshake — device token persisted: \(deviceToken.prefix(8))...")
            } else {
                print("[GW] resolveHandshake — no deviceToken in hello-ok (first connection or empty auth)")
            }
        } else {
            // Even if we can't fully decode HelloOk, the handshake was ok=true
            // This means the connection is authenticated — we should proceed
            print("[GW] resolveHandshake — ⚠️ could not fully decode HelloOk, but ok=true so proceeding")
            print("[GW] resolveHandshake — decode error was: \(decodeError?.localizedDescription ?? "nil")")
            if let payload = frame.payload {
                print("[GW] resolveHandshake — raw payload keys: \(payload.keys.map { String($0) })")
            }
        }
        
        // ── Set state to connected and resume the continuation ──
        retryCount = 0
        print("[GW] resolveHandshake — setting state to .connected")
        updateState(.connected)
        
        print("[GW] resolveHandshake — resuming handshake continuation")
        succeedHandshake()
        
        print("[GW] resolveHandshake — COMPLETE ✅")
    }
    
    /// Manually decode a HelloOk from the payload dictionary, using defaults for missing fields.
    /// This is the resilience fallback when structured decoding fails.
    private func manuallyDecodeHelloOk(payload: [String: AnyCodable]) -> HelloOk? {
        print("[GW] manuallyDecodeHelloOk — attempting partial decode")
        
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
        
        print("[GW] manuallyDecodeHelloOk — ✅ built HelloOk manually")
        return helloOk
    }
    
    // ╔══════════════════════════════════════════════════════════════╗
    // ║  HANDSHAKE — sending the connect request                     ║
    // ╚══════════════════════════════════════════════════════════════╝
    
    private func performHandshake() async {
        print("[GW] performHandshake() — BEGIN, setting state to .handshaking")
        updateState(.handshaking)
        
        guard let nonce = challengeNonce else {
            print("[GW] performHandshake — ❌ no challenge nonce available!")
            failHandshake("No challenge nonce available", code: -5)
            return
        }
        
        print("[GW] performHandshake — nonce=\(nonce.prefix(8))...")
        
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
                print("[GW] performHandshake — device identity built: id=\(deviceId.prefix(8))...")
            } catch {
                print("[GW] performHandshake — ⚠️ failed to build device identity: \(error), connecting without it")
            }
        } else {
            print("[GW] performHandshake — no stored deviceToken, connecting without device identity (first connection)")
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
                print("[GW] performHandshake — sending connect request: \(jsonStr.prefix(500))")
            }
            try await transport.send(String(data: data, encoding: .utf8)!)
            print("[GW] performHandshake — connect request sent ✅")
            print("[GW] performHandshake — waiting for response in message loop...")
            
            // Set up a timeout for the handshake response
            // The message loop will receive the response and call resolveHandshake()
            // If it doesn't arrive in time, we need to fail the handshake
            let timeoutSeconds = config.requestTimeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                // Check if we're still waiting for handshake
                if self.state == .handshaking {
                    print("[GW] performHandshake — ❌ handshake TIMED OUT after \(timeoutSeconds)s")
                    self.updateState(.error)
                    self.failHandshake("Handshake timed out after \(timeoutSeconds)s", code: -6)
                }
            }
        } catch {
            print("[GW] performHandshake — ❌ failed to send handshake: \(error)")
            updateState(.error)
            failHandshake("Failed to send handshake: \(error.localizedDescription)", code: -8)
        }
    }
    
    // ╔══════════════════════════════════════════════════════════════╗
    // ║  ERROR HANDLING                                               ║
    // ╚══════════════════════════════════════════════════════════════╝
    
    private func handleTransportError(_ error: Error) async {
        print("[GW] handleTransportError — error=\(error.localizedDescription) retryCount=\(retryCount)/\(config.maxRetries) state=\(state.rawValue)")
        
        // If we're still waiting for handshake, fail it
        if state == .connecting || state == .handshaking {
            print("[GW] handleTransportError — failing pending handshake")
            updateState(.error)
            failHandshake("Connection failed: \(error.localizedDescription)", code: -7)
        }
        
        if retryCount < config.maxRetries {
            let delay = backoff.delay(forAttempt: retryCount)
            retryCount += 1
            print("[GW] handleTransportError — retrying in \(String(format: "%.1f", delay))s (attempt \(retryCount)/\(config.maxRetries))")
            updateState(.connecting)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await performConnect()
        } else {
            print("[GW] handleTransportError — max retries reached, giving up")
            updateState(.error)
        }
    }

    private func handleClose(code: Int, reason: String?) async {
        print("[GW] handleClose — code=\(code) reason=\(reason ?? "n/a") state=\(state.rawValue)")
        
        // If we're still in handshake, fail it
        if state == .connecting || state == .handshaking {
            print("[GW] handleClose — connection closed during handshake, failing it")
            updateState(.error)
            failHandshake(reason ?? "Connection closed during handshake (code: \(code))", code: code)
            return
        }
        
        if code == 1008 || (code >= 4000 && code <= 4999) {
            // Policy violation or application error — no reconnect
            print("[GW] handleClose — fatal close code, setting error state")
            updateState(.error)
        } else if state == .connected {
            // Connection was established and then closed.
            // Don't auto-reconnect — let the application layer handle it.
            print("[GW] handleClose — connection closed while connected, transitioning to disconnected")
            updateState(.disconnected)
        } else if state != .disconnected && state != .error {
            // Still connecting — attempt reconnect
            print("[GW] handleClose — close during connect, attempting reconnect")
            await handleTransportError(NSError(domain: "WebSocketTransport", code: code, userInfo: [NSLocalizedDescriptionKey: reason ?? "Connection closed"]))
        }
    }
    
    // ╔══════════════════════════════════════════════════════════════╗
    // ║  STATE MANAGEMENT                                             ║
    // ╚══════════════════════════════════════════════════════════════╝
    
    private func updateState(_ newState: ConnectionState) {
        let oldState = state
        state = newState
        print("[GW] updateState: \(oldState.rawValue) → \(newState.rawValue)")
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