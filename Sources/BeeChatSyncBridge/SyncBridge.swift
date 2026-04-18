import Foundation
import BeeChatGateway
import BeeChatPersistence
import GRDB

public actor SyncBridge {
    let config: SyncBridgeConfiguration
    private let rpcClient: RPCClientProtocol
    private var eventRouter: EventRouter?

    private let reconciler: Reconciler
    private let ledgerRepo: DeliveryLedgerRepository
    private let sessionObserver: SessionObserver
    private let messageObserver: MessageObserver
    
    public weak var delegate: SyncBridgeDelegate?
    
    private var lastSeenEventSeq: Int?
    private var streamingBuffer: [String: String] = [:]
    public private(set) var currentStreamingSessionKey: String?
    
    /// Max time to wait after last delta before declaring a stream stalled
    private static let streamStallInterval: TimeInterval = 90.0

    private var eventProcessingTask: Task<Void, Never>?
    private var reconnectWatchTask: Task<Void, Never>?
    private var connectionWatchTask: Task<Void, Never>?
    private var stallTimerTask: Task<Void, Never>?

    public init(config: SyncBridgeConfiguration) {
        self.config = config
        let gateway = config.gatewayClient
        let rpc = RPCClient(gateway: gateway)
        self.rpcClient = rpc
        self.ledgerRepo = DeliveryLedgerRepository(dbManager: DatabaseManager.shared)
        
        self.reconciler = Reconciler(
            rpcClient: rpc,
            persistenceStore: config.persistenceStore,
            ledgerRepo: self.ledgerRepo
        )
        
        self.sessionObserver = SessionObserver(dbManager: DatabaseManager.shared)
        self.messageObserver = MessageObserver(dbManager: DatabaseManager.shared)
        
        // Deferred initialization of router to avoid 'self' in init
    }
    
    public func start() async throws {
        // Initialize router now that self is fully initialized
        if eventRouter == nil {
            self.eventRouter = EventRouter(syncBridge: self)
        }

        try await config.gatewayClient.connect()
        
        // Subscribe to session changes
        try await rpcClient.sessionsSubscribe()
        
        // Initial sync
        _ = try await fetchSessions()
        
        // Start event processing loop
        eventProcessingTask = Task {
            let stream = await config.gatewayClient.eventStream()
            for await event in stream {
                await eventRouter?.route(event: event.event, payload: event.payload)
            }
        }
        
        // Reconciliation on reconnect
        reconnectWatchTask = Task {
            for await state in connectionStateStream() {
                if state == .connected {
                    try? await reconciler.reconcile(activeSessionKey: currentStreamingSessionKey)
                }
            }
        }
        
        // A2: Connection loss during streaming — clear stuck state immediately
        connectionWatchTask = Task {
            for await state in connectionStateStream() {
                if state != .connected, currentStreamingSessionKey != nil {
                    await clearStalledStream(reason: "Connection lost while streaming")
                }
            }
        }
    }
    
    public func stop() async {
        eventProcessingTask?.cancel()
        reconnectWatchTask?.cancel()
        connectionWatchTask?.cancel()
        stallTimerTask?.cancel()
        eventProcessingTask = nil
        reconnectWatchTask = nil
        connectionWatchTask = nil
        stallTimerTask = nil
        
        await config.gatewayClient.disconnect()
        
        // Cleanup state
        streamingBuffer.removeAll()
        lastSeenEventSeq = nil
        currentStreamingSessionKey = nil
    }
    
    public func fetchSessions() async throws -> [Session] {
        let infos = try await rpcClient.sessionsList()
        let sessions = infos.map { info in
            let lastMsgDate = info.lastMessageAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            return Session(
                id: info.key,
                agentId: info.key,
                channel: info.channel,
                title: info.label,
                lastMessageAt: lastMsgDate,
                updatedAt: Date()
            )
        }
        try config.persistenceStore.upsertSessions(sessions)
        return sessions
    }
    
    public func fetchHistory(sessionKey: String, limit: Int? = nil) async throws -> [Message] {
        let fetchLimit = limit ?? config.historyFetchLimit
        let history = try await rpcClient.chatHistory(sessionKey: sessionKey, limit: fetchLimit)
        let messages = history.map { payload in
            Message(
                id: payload.id,
                sessionId: payload.sessionKey,
                role: payload.role,
                content: payload.content,
                timestamp: payload.timestamp
            )
        }
        try config.persistenceStore.upsertMessages(messages)
        return messages
    }
    
    public func sendMessage(sessionKey: String, text: String, thinking: String? = nil, attachments: [[String: Any]]? = nil) async throws -> String {
        let idempotencyKey = UUID().uuidString
        let entry = DeliveryLedgerEntry(
            id: UUID(),
            sessionKey: sessionKey,
            idempotencyKey: idempotencyKey,
            content: text,
            status: .pending,
            createdAt: Date(),
            updatedAt: Date(),
            retryCount: 0
        )
        try ledgerRepo.save(entry)
        
        do {
            let runId = try await rpcClient.chatSend(sessionKey: sessionKey, message: text, idempotencyKey: idempotencyKey, thinking: thinking, attachments: attachments)
            try ledgerRepo.updateStatus(idempotencyKey: idempotencyKey, status: .sent, runId: runId)
            return runId
        } catch {
            try? ledgerRepo.updateStatus(idempotencyKey: idempotencyKey, status: .failed)
            throw error
        }
    }
    
    public func abortGeneration(sessionKey: String) async throws {
        cancelStallTimer()
        let ok = try await rpcClient.chatAbort(sessionKey: sessionKey)
        if ok {
            streamingBuffer.removeAll()
            currentStreamingSessionKey = nil
        }
    }
    
    public func sessionListStream() -> AsyncStream<[Session]> {
        return sessionObserver.observeSessions()
    }
    
    public func messageStream(sessionKey: String) -> AsyncStream<[Message]> {
        return messageObserver.observeMessages(sessionKey: sessionKey)
    }
    
    public func connectionStateStream() -> AsyncStream<ConnectionState> {
        AsyncStream(ConnectionState.self, bufferingPolicy: .unbounded) { continuation in
            Task {
                await config.gatewayClient.updateOnStatusChange { state in
                    continuation.yield(state)
                }
            }
        }
    }
    
    public var currentStreamingContent: String {
        guard let key = currentStreamingSessionKey,
              let content = streamingBuffer[key] else { return "" }
        return content
    }
    
    // Internal helpers for EventRouter
    
    // MARK: - Chat event handlers (client-friendly format from gateway)
    
    /// Handle "chat" delta event — gateway sends accumulated text (replacement, not append)
       internal func processChatDelta(sessionKey: String, text: String) async {
        streamingBuffer[sessionKey] = text  // Replacement, not append
        currentStreamingSessionKey = sessionKey
        resetStallTimer()
        delegate?.syncBridge(self, didStartStreaming: sessionKey)
    }
    
    /// Handle "chat" final event — streaming complete
    internal func processChatFinal(sessionKey: String) async {
        cancelStallTimer()
        streamingBuffer.removeValue(forKey: sessionKey)
        if currentStreamingSessionKey == sessionKey {
            currentStreamingSessionKey = nil
        }
        delegate?.syncBridge(self, didStopStreaming: sessionKey)
    }
    
    /// Handle "chat" error event
    internal func processChatError(sessionKey: String, errorMessage: String) async {
        cancelStallTimer()
        streamingBuffer.removeValue(forKey: sessionKey)
        if currentStreamingSessionKey == sessionKey {
            currentStreamingSessionKey = nil
        }
        delegate?.syncBridge(self, didStopStreaming: sessionKey)
    }
    
    // MARK: - Agent event handler (legacy, lower-level format)
    
    internal func processAgentEvent(_ event: AgentEventPayload) async {
        // Seq tracking
        if let seq = event.seq {
            if let last = lastSeenEventSeq, seq <= last { return }
            
            if let last = lastSeenEventSeq, seq > last + 1 {
                // Gap detected
                try? await reconciler.reconcile(activeSessionKey: event.sessionKey)
            }
            
            lastSeenEventSeq = seq
        }
        
        let runId = event.runId
        let sessionKey = event.sessionKey
        
        switch event.data.phase {
        case "delta":
            if let text = event.data.text {
                streamingBuffer[sessionKey, default: ""] += text
                currentStreamingSessionKey = sessionKey
                resetStallTimer()
                delegate?.syncBridge(self, didStartStreaming: sessionKey)
            }
        case "final":
            cancelStallTimer()
            if let text = event.data.text {
                let message = Message(
                    id: event.data.itemId ?? UUID().uuidString,
                    sessionId: sessionKey,
                    role: "assistant",
                    content: text,
                    timestamp: Date(timeIntervalSince1970: Double(event.ts / 1000))
                )
                try? config.persistenceStore.saveMessage(message)
                streamingBuffer.removeValue(forKey: sessionKey)
                delegate?.syncBridge(self, didStopStreaming: sessionKey)
            }
        case "error":
            cancelStallTimer()
            streamingBuffer.removeValue(forKey: sessionKey)
            delegate?.syncBridge(self, didStopStreaming: sessionKey)
        default:
            break
        }
    }
    
    internal func updateLiveness() async {
        // Update internal liveness clock
    }
    
    // MARK: - Stream stall detection (A1)
    
    /// Reset the stall timer — called on every delta to postpone the timeout
    private func resetStallTimer() {
        stallTimerTask?.cancel()
        stallTimerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.streamStallInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await clearStalledStream(reason: "Stream stalled — no delta for \(Int(Self.streamStallInterval))s")
        }
    }
    
    /// Cancel the stall timer — called on final/error/stop
    private func cancelStallTimer() {
        stallTimerTask?.cancel()
        stallTimerTask = nil
    }
    
    /// Clear stuck streaming state — marks the current stream as errored
    internal func clearStalledStream(reason: String) async {
        guard let sessionKey = currentStreamingSessionKey else { return }
        print("[SyncBridge] \(reason) — clearing streaming state for session: \(sessionKey)")
        cancelStallTimer()
        streamingBuffer.removeValue(forKey: sessionKey)
        currentStreamingSessionKey = nil
        delegate?.syncBridge(self, didStopStreaming: sessionKey)
    }
}
