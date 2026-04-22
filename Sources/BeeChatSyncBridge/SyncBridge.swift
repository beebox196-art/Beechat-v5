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
    
    /// Maps gateway session keys (e.g. "agent:main:05549141-d6da-...") to local topic IDs
    /// (e.g. "05549141-D6DA-..."). Populated during fetchSessions and on demand.
    private var sessionKeyMap: [String: String] = [:]
    
    /// Cache of session keys that belong to BeeChat topics.
    /// Populated during fetchSessions and on demand. Used by EventRouter
    /// to filter out non-BeeChat events (Telegram, cron, subagent sessions).
    private var beechatSessionKeys: Set<String> = []
    
    public weak var delegate: SyncBridgeDelegate?
    
    /// Set the delegate from outside the actor. Needed because the delegate property
    /// is actor-isolated and cannot be mutated from the main actor.
    public func setDelegate(_ delegate: SyncBridgeDelegate?) {
        self.delegate = delegate
    }
    
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
    
    // MARK: - BeeChat session filtering
    
    /// Check whether a gateway session key belongs to a BeeChat topic.
    /// Returns true only if the session key maps to a known topic (via sessionKeyMap,
    /// topics table, or topic_session_bridge table). All other sessions (Telegram,
    /// cron, subagent) return false so their events are silently dropped.
    func isBeeChatSession(_ sessionKey: String) -> Bool {
        // Direct map hit
        if sessionKeyMap[sessionKey] != nil { return true }
        
        // Check the in-memory set
        if beechatSessionKeys.contains(sessionKey) { return true }
        
        // Database lookup via TopicRepository
        let topicRepo = TopicRepository()
        if (try? topicRepo.resolveTopicId(for: sessionKey)) != nil {
            beechatSessionKeys.insert(sessionKey)
            return true
        }
        
        // Also try suffix matching (handles "agent:main:<uuid>" format)
        let stripped: String
        if sessionKey.hasPrefix("agent:main:") {
            stripped = String(sessionKey.dropFirst("agent:main:".count))
        } else {
            stripped = sessionKey
        }
        if stripped != sessionKey, let topicId = try? topicRepo.resolveTopicIdBySuffix(gatewayKey: sessionKey, stripped: stripped) {
            sessionKeyMap[sessionKey] = topicId
            beechatSessionKeys.insert(sessionKey)
            return true
        }
        
        return false
    }
    
    // MARK: - Session key normalization
    
    /// Normalize a gateway session key to the local topic ID.
    /// Gateway keys look like "agent:main:<uuid>" (lowercase). Local topic IDs
    /// are the original UUID (may differ in case). This method strips the
    /// "agent:main:" prefix and resolves to the correct local topic ID.
    func normalizeSessionKey(_ gatewayKey: String) -> String {
        // Check the map first (O(1))
        if let localId = sessionKeyMap[gatewayKey] {
            return localId
        }
        
        // Strip "agent:main:" prefix if present
        let stripped: String
        if gatewayKey.hasPrefix("agent:main:") {
            stripped = String(gatewayKey.dropFirst("agent:main:".count))
        } else {
            stripped = gatewayKey
        }
        
        // Try to find a topic whose ID matches case-insensitively
        let topicRepo = TopicRepository()
        if let topicId = try? topicRepo.resolveTopicIdBySuffix(gatewayKey: gatewayKey, stripped: stripped) {
            sessionKeyMap[gatewayKey] = topicId
            return topicId
        }
        
        // No mapping found — return the original key unchanged
        return gatewayKey
    }
    
    public func fetchSessions() async throws -> [Session] {
        let infos = try await rpcClient.sessionsList()
        
        // Populate the session key map and beechatSessionKeys from topics FIRST
        let topicRepo = TopicRepository()
        let allTopics = (try? topicRepo.fetchAllActive(limit: 500)) ?? []
        let topicIdMap = Dictionary(uniqueKeysWithValues: allTopics.map { ($0.id.uppercased(), $0.id) })
        
        // Also index by sessionKey column (which stores gateway-format keys)
        var sessionKeyToTopicId: [String: String] = [:]
        for topic in allTopics {
            if let sk = topic.sessionKey, !sk.isEmpty {
                sessionKeyToTopicId[sk] = topic.id
            }
        }
        
        // Also index the bridge table entries
        let bridgeEntries = (try? topicRepo.listAllBridgeSessionKeys()) ?? []
        for (sessionKey, topicId) in bridgeEntries {
            sessionKeyToTopicId[sessionKey] = topicId
        }
        
        // Filter sessions: only keep those that map to BeeChat topics
        var beechatSessions: [Session] = []
        for info in infos {
            let gatewayKey = info.key
            let stripped: String
            if gatewayKey.hasPrefix("agent:main:") {
                stripped = String(gatewayKey.dropFirst("agent:main:".count))
            } else {
                stripped = gatewayKey
            }
            
            // Check if this session belongs to a BeeChat topic
            let topicId: String? = sessionKeyToTopicId[gatewayKey]
                ?? topicIdMap[stripped.uppercased()]
            
            if let topicId = topicId {
                // This session maps to a BeeChat topic — keep it
                sessionKeyMap[gatewayKey] = topicId
                beechatSessionKeys.insert(gatewayKey)
                
                let lastMsgDate = info.lastMessageAt.flatMap { ISO8601DateFormatter().date(from: $0) }
                beechatSessions.append(Session(
                    id: info.key,
                    agentId: info.key,
                    channel: info.channel,
                    title: info.label,
                    lastMessageAt: lastMsgDate,
                    updatedAt: Date()
                ))
            }
            // Non-BeeChat sessions are silently ignored
        }
        
        // Only persist BeeChat topic sessions (sidebar is topic-driven, not session-driven)
        try config.persistenceStore.upsertSessions(beechatSessions)
        
        return beechatSessions
    }
    
    public func fetchHistory(sessionKey: String, limit: Int? = nil) async throws -> [Message] {
        // Only fetch history for sessions that belong to BeeChat topics
        guard isBeeChatSession(sessionKey) else {
            return []
        }
        
        let fetchLimit = limit ?? config.historyFetchLimit
        let history = try await rpcClient.chatHistory(sessionKey: sessionKey, limit: fetchLimit)
        let localSessionKey = normalizeSessionKey(sessionKey)
        let messages = history.map { payload in
            Message(
                id: payload.id,
                sessionId: localSessionKey,
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
    
    /// Save a message from the gateway, normalizing the session key to the local topic ID.
    internal func saveGatewayMessage(_ message: Message) {
        let localKey = normalizeSessionKey(message.sessionId)
        let normalized = Message(
            id: message.id,
            sessionId: localKey,
            role: message.role,
            content: message.content,
            senderName: message.senderName,
            senderId: message.senderId,
            timestamp: message.timestamp,
            editedAt: message.editedAt,
            isRead: message.isRead,
            metadata: message.metadata,
            createdAt: message.createdAt
        )
        try? config.persistenceStore.saveMessage(normalized)
    }
    
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
        
        // Fetch history BEFORE notifying the delegate so the persisted message
        // is in the DB when the UI clears the streaming content.
        // This prevents the visual gap where streaming content disappears
        // before the persisted message appears.
        do {
            _ = try await fetchHistory(sessionKey: sessionKey)
        } catch {
            // Post-stream fetchHistory failed — non-critical
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
        
        // Fetch history before notifying the delegate so persisted messages are in the DB
        try? await fetchHistory(sessionKey: sessionKey)
        
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
        
        _ = event.runId
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
                saveGatewayMessage(message)
            }
            streamingBuffer.removeValue(forKey: sessionKey)
            // Fetch history before notifying the delegate so persisted messages are in the DB
            try? await fetchHistory(sessionKey: sessionKey)
            delegate?.syncBridge(self, didStopStreaming: sessionKey)
        case "error":
            cancelStallTimer()
            streamingBuffer.removeValue(forKey: sessionKey)
            // Fetch history before notifying the delegate
            try? await fetchHistory(sessionKey: sessionKey)
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
        cancelStallTimer()
        streamingBuffer.removeValue(forKey: sessionKey)
        currentStreamingSessionKey = nil
        // Fetch history before notifying so any partial message is persisted
        try? await fetchHistory(sessionKey: sessionKey)
        delegate?.syncBridge(self, didStopStreaming: sessionKey)
    }
}
