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

    private var sessionKeyMap: [String: String] = [:]

    private var beechatSessionKeys: Set<String> = []

    public weak var delegate: SyncBridgeDelegate?

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
    private var usagePollingTasks: [String: Task<Void, Never>] = [:]

    public let sessionResetManager: SessionResetManager
    public private(set) var sessionUsageCache: [String: Double] = [:]

    public init(config: SyncBridgeConfiguration) {
        self.config = config
        let gateway = config.gatewayClient
        let rpc = RPCClient(gateway: gateway)
        self.rpcClient = rpc
        self.ledgerRepo = DeliveryLedgerRepository(dbManager: DatabaseManager.shared)
        self.sessionResetManager = SessionResetManager()

        self.reconciler = Reconciler(
            rpcClient: rpc,
            persistenceStore: config.persistenceStore,
            ledgerRepo: self.ledgerRepo
        )
    }

    public func start() async throws {
        if eventRouter == nil {
            self.eventRouter = EventRouter(syncBridge: self)
        }

        try await config.gatewayClient.connect()
        try await rpcClient.sessionsSubscribe()
        _ = try await fetchSessions()

        eventProcessingTask = Task {
            let stream = await config.gatewayClient.eventStream()
            for await event in stream {
                do {
                    try await eventRouter?.route(event: event.event, payload: event.payload)
                } catch {
                    print("[SyncBridge] Event routing error: \(error)")
                }
            }
        }

        reconnectWatchTask = Task {
            for await state in connectionStateStream() {
                if state == .connected {
                    do {
                        try await reconciler.reconcile(activeSessionKey: currentStreamingSessionKey)
                    } catch {
                        print("[SyncBridge] Reconciliation error: \(error)")
                    }
                }
            }
        }

        // Start usage polling for known sessions
        for sessionKey in beechatSessionKeys {
            try? await startUsagePolling(sessionKey: sessionKey)
        }

        connectionWatchTask = Task {
            for await state in connectionStateStream() {
                if state != .connected, currentStreamingSessionKey != nil {
                    do {
                        try await clearStalledStream(reason: "Connection lost while streaming")
                    } catch {
                        print("[SyncBridge] Stream cleanup error: \(error)")
                    }
                }
            }
        }
    }

    public func stop() async {
        eventProcessingTask?.cancel()
        reconnectWatchTask?.cancel()
        connectionWatchTask?.cancel()
        stallTimerTask?.cancel()
        stopUsagePolling()
        eventProcessingTask = nil
        reconnectWatchTask = nil
        connectionWatchTask = nil
        stallTimerTask = nil
        usagePollingTasks.removeAll()

        await config.gatewayClient.disconnect()

        streamingBuffer.removeAll()
        lastSeenEventSeq = nil
        currentStreamingSessionKey = nil
    }

    // MARK: - BeeChat session filtering

    func isBeeChatSession(_ sessionKey: String) throws -> Bool {
        if sessionKeyMap[sessionKey] != nil { return true }
        if beechatSessionKeys.contains(sessionKey) { return true }

        if try BeeChatSessionFilter.isBeeChatSession(sessionKey) {
            beechatSessionKeys.insert(sessionKey)
            return true
        }
        return false
    }

    // MARK: - Session key normalization

    func normalizeSessionKey(_ gatewayKey: String) throws -> String {
        if let localId = sessionKeyMap[gatewayKey] {
            return localId
        }
        let normalized = try BeeChatSessionFilter.normalize(gatewayKey)
        if normalized != gatewayKey {
            sessionKeyMap[gatewayKey] = normalized
        }
        return normalized
    }

    public func fetchSessions() async throws -> [Session] {
        let infos = try await rpcClient.sessionsList()

        let topicRepo = TopicRepository()
        let allTopics = try topicRepo.fetchAllActive(limit: 500)
        let topicIdMap = Dictionary(uniqueKeysWithValues: allTopics.map { ($0.id.uppercased(), $0.id) })

        var sessionKeyToTopicId: [String: String] = [:]
        for topic in allTopics {
            if let sk = topic.sessionKey, !sk.isEmpty {
                sessionKeyToTopicId[sk] = topic.id
            }
        }

        let bridgeEntries = try topicRepo.listAllBridgeSessionKeys()
        for (sessionKey, topicId) in bridgeEntries {
            sessionKeyToTopicId[sessionKey] = topicId
        }

        // Filter sessions: only keep those that map to BeeChat topics
        var beechatSessions: [Session] = []
        for info in infos {
            let gatewayKey = info.key
            let stripped = SessionKeyNormalizer.stripPrefix(gatewayKey)

            let topicId: String? = sessionKeyToTopicId[gatewayKey]
                ?? topicIdMap[stripped.uppercased()]

            if let topicId = topicId {
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
        }

        try config.persistenceStore.upsertSessions(beechatSessions)

        return beechatSessions
    }

    public func fetchHistory(sessionKey: String, limit: Int? = nil) async throws -> [Message] {
        guard try isBeeChatSession(sessionKey) else {
            return []
        }

        let fetchLimit = limit ?? config.historyFetchLimit
        let history = try await rpcClient.chatHistory(sessionKey: sessionKey, limit: fetchLimit)
        let localSessionKey = try normalizeSessionKey(sessionKey)
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

    public func sendMessage(sessionKey: String, text: String, thinking: String? = nil, attachments: [ChatAttachment]? = nil) async throws -> String {
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
            try ledgerRepo.updateStatus(idempotencyKey: idempotencyKey, status: .failed)
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

    // MARK: - Session Reset Flow

    public func resetSession(sessionKey: String) async throws -> Bool {
        return try await rpcClient.sessionsReset(sessionKey: sessionKey, reason: "new")
    }

    public func pollSessionUsage(sessionKey: String) async throws {
        let usage = try await rpcClient.sessionsUsage(sessionKey: sessionKey)
        sessionUsageCache[sessionKey] = usage
    }

    public func startUsagePolling(sessionKey: String) async {
        guard !sessionKey.isEmpty else { return }
        stopUsagePolling(for: sessionKey)
        let task = Task {
            // Immediate check
            try? await pollSessionUsage(sessionKey: sessionKey)
            // Hourly re-checks
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000) // 1 hour
                guard !Task.isCancelled else { return }
                try? await pollSessionUsage(sessionKey: sessionKey)
            }
        }
        usagePollingTasks[sessionKey] = task
    }

    public func stopUsagePolling(for sessionKey: String? = nil) {
        if let key = sessionKey {
            usagePollingTasks[key]?.cancel()
            usagePollingTasks.removeValue(forKey: key)
        } else {
            for (_, task) in usagePollingTasks {
                task.cancel()
            }
            usagePollingTasks.removeAll()
        }
    }

    public func messageStream(sessionKey: String) -> AsyncStream<[Message]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                try Message
                    .filter(Column("sessionId") == sessionKey)
                    .order(Column("timestamp").asc)
                    .limit(500)
                    .fetchAll(db)
            }

            do {
                let writer = try DatabaseManager.shared.writer
                let cancellable = observation.start(
                    in: writer,
                    scheduling: .mainActor,
                    onError: { error in
                        print("[SyncBridge] Message observation error: \(error)")
                    },
                    onChange: { messages in
                        continuation.yield(messages)
                    }
                )
                continuation.onTermination = { _ in cancellable.cancel() }
            } catch {
                print("[SyncBridge] Message observation setup error: \(error)")
            }
        }
    }

    public func connectionStateStream() -> AsyncStream<ConnectionState> {
        AsyncStream(ConnectionState.self, bufferingPolicy: .unbounded) { continuation in
            Task {
                await config.gatewayClient.updateConnectionStateObserver { state in
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

    /// Check if a message with the given ID already exists in the database.
    internal func messageExists(id: String) throws -> Bool {
        let writer = try DatabaseManager.shared.writer
        return try writer.read { db in
            try Message.filter(Column("id") == id).fetchCount(db) > 0
        }
    }

    /// Save a message from the gateway, normalizing the session key to the local topic ID.
    internal func saveGatewayMessage(_ message: Message) throws {
        let localKey = try normalizeSessionKey(message.sessionId)
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
        try config.persistenceStore.saveMessage(normalized)
    }

    // MARK: - Chat event handlers (client-friendly format from gateway)

    /// Handle "chat" delta event - gateway sends accumulated text (replacement, not append)
       internal func processChatDelta(sessionKey: String, text: String) async {
        let isFirstDelta = currentStreamingSessionKey != sessionKey
        currentStreamingSessionKey = sessionKey
        resetStallTimer()
        if isFirstDelta {
            delegate?.syncBridge(self, didStartStreaming: sessionKey)
        }
    }

    internal func processChatFinal(sessionKey: String) async throws {
        print("[SyncBridge] processChatFinal called for sessionKey=\(sessionKey), currentStreamingSessionKey=\(currentStreamingSessionKey ?? "nil")")
        cancelStallTimer()
        streamingBuffer.removeValue(forKey: sessionKey)
        if currentStreamingSessionKey == sessionKey {
            currentStreamingSessionKey = nil
        }

        // Fetch history BEFORE notifying the delegate so the persisted message
        // is in the DB when the UI clears the streaming content.
        // This prevents the visual gap where streaming content disappears
        // before the persisted message appears.
        _ = try await fetchHistory(sessionKey: sessionKey)

        delegate?.syncBridge(self, didStopStreaming: sessionKey)
    }

    internal func processChatError(sessionKey: String, errorMessage: String) async throws {
        cancelStallTimer()
        streamingBuffer.removeValue(forKey: sessionKey)
        if currentStreamingSessionKey == sessionKey {
            currentStreamingSessionKey = nil
        }

        try await fetchHistory(sessionKey: sessionKey)

        delegate?.syncBridge(self, didStopStreaming: sessionKey)
    }

    // MARK: - Agent event handler (legacy, lower-level format)

    internal func processAgentEvent(_ event: AgentEventPayload) async throws {
        // Seq tracking
        if let seq = event.seq {
            if let last = lastSeenEventSeq, seq <= last { return }

            if let last = lastSeenEventSeq, seq > last + 1 {
                // Gap detected
                try await reconciler.reconcile(activeSessionKey: event.sessionKey)
            }

            lastSeenEventSeq = seq
        }

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
                try saveGatewayMessage(message)
            }
            streamingBuffer.removeValue(forKey: sessionKey)
            try await fetchHistory(sessionKey: sessionKey)
            delegate?.syncBridge(self, didStopStreaming: sessionKey)
        case "error":
            cancelStallTimer()
            streamingBuffer.removeValue(forKey: sessionKey)
            // Fetch history before notifying the delegate
            try await fetchHistory(sessionKey: sessionKey)
            delegate?.syncBridge(self, didStopStreaming: sessionKey)
        default:
            break
        }
    }

    internal func updateLiveness() async {
    }

    // MARK: - Stream stall detection (A1)

    private func resetStallTimer() {
        stallTimerTask?.cancel()
        stallTimerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.streamStallInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                try await clearStalledStream(reason: "Stream stalled - no delta for \(Int(Self.streamStallInterval))s")
            } catch {
                print("[SyncBridge] Stall timer cleanup error: \(error)")
            }
        }
    }

    private func cancelStallTimer() {
        stallTimerTask?.cancel()
        stallTimerTask = nil
    }

    internal func clearStalledStream(reason: String) async throws {
        guard let sessionKey = currentStreamingSessionKey else { return }
        cancelStallTimer()
        streamingBuffer.removeValue(forKey: sessionKey)
        currentStreamingSessionKey = nil
        try await fetchHistory(sessionKey: sessionKey)
        delegate?.syncBridge(self, didStopStreaming: sessionKey)
    }
}
