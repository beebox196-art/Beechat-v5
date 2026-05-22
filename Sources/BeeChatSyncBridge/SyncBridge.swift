import Foundation
import BeeChatGateway
import BeeChatPersistence
import GRDB

public enum SyncBridgeError: LocalizedError {
    case concurrentSendInProgress
    
    public var errorDescription: String? {
        switch self {
        case .concurrentSendInProgress:
            return "A message is already being sent. Please retry."
        }
    }
}

public actor SyncBridge {
    let config: SyncBridgeConfiguration
    private let rpcClient: RPCClientProtocol
    private var eventRouter: EventRouter?

    private let reconciler: Reconciler
    private let ledgerRepo: DeliveryLedgerRepository

    /// Session keys known from the last fetchSessions() call
    private var knownSessionKeys: Set<String> = []

    public weak var delegate: SyncBridgeDelegate?

    public func setDelegate(_ delegate: SyncBridgeDelegate?) {
        self.delegate = delegate
    }

    private var lastSeenEventSeq: Int?
    private var streamingBuffer: [String: String] = [:]
    public private(set) var streamingSessionKeys: Set<String> = []

    /// Max time to wait after last delta before declaring a stream stalled
    private static let streamStallInterval: TimeInterval = 30.0

    private var eventProcessingTask: Task<Void, Never>?
    private var reconnectWatchTask: Task<Void, Never>?
    private var connectionWatchTask: Task<Void, Never>?
    private var stallTimerTasks: [String: Task<Void, Never>] = [:]
    private var usagePollingTasks: [String: Task<Void, Never>] = [:]

    public let sessionResetManager: SessionResetManager
    public private(set) var sessionUsageCache: [String: Double] = [:]

    /// Gate to prevent concurrent sendMessage calls
    private var sendingSessionKeys: Set<String> = []
    /// Cooldown tracker: messages remaining before next auto-reset check
    private var resetCooldownCount: [String: Int] = [:]
    private static let resetCooldownMessages = 5

    // MARK: - Topic Publishing

    /// Serialises publishing per topic to prevent stale overwrites on rapid CRUD.
    private let publishQueue = TopicPublishQueue()

    /// Simple helper to extract `projectPath` from `topic.metadataJSON`.
    /// Returns nil if the JSON is missing, empty, or doesn't contain projectPath.
    private func extractProjectPath(from metadataJSON: String) throws -> String? {
        guard let data = metadataJSON.data(using: .utf8) else { return nil }
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return dict?["projectPath"] as? String
    }

    /// Publishes a topic's state (label + metadata) to the gateway.
    ///
    /// The operation is enqueued to `publishQueue` for serial execution per topic.
    /// Metadata is published first — if that fails, the label is not published
    /// (avoids creating a "ghost" session on the gateway).
    public func publishTopicState(topic: Topic, sessionKey: String) {
        // Runtime guard: verify topicId matches session key suffix
        let keySuffix = sessionKey.split(separator: ":").last.map(String.init)?.lowercased()
        if topic.id.lowercased() != keySuffix {
            print("[SyncBridge] topicId \(topic.id) does not match session key suffix \(keySuffix ?? "nil") — skipping publish")
            return
        }

        // Build metadata
        let projectPath: String?
        if let json = topic.metadataJSON {
            projectPath = (try? extractProjectPath(from: json)) ?? nil
        } else {
            projectPath = nil
        }
        let metadata = BeeChatTopicMetadata(
            topicId: topic.id,
            isArchived: topic.isArchived,
            projectPath: projectPath,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        // Enqueue for serial execution per topic
        Task {
            await publishQueue.enqueue(sessionKey: sessionKey) { [weak self] in
            guard let self = self else { return }
            do {
                    // Metadata FIRST — if this fails, don't publish label
                    let metaOk = try await self.rpcClient.sessionsPluginPatch(
                        key: sessionKey,
                        pluginId: "beechat",
                        namespace: "metadata",
                        value: metadata,
                        unset: false
                    )
                    guard metaOk else {
                        print("[SyncBridge] pluginPatch failed for topic \(topic.id)")
                        return  // Skip label — no ghost topic
                    }

                    // Label SECOND
                    let labelOk = try await self.rpcClient.sessionsPatch(
                        key: sessionKey,
                        label: topic.name
                    )
                    if !labelOk {
                        print("[SyncBridge] sessionsPatch failed for topic \(topic.id) — metadata published but label not set")
                    }
                } catch {
                    print("[SyncBridge] publishTopicState failed for \(topic.id): \(error)")
                    // Don't throw — fire-and-forget. reconcileAllTopicState handles retry on reconnect.
                }
            }
        }
    }

    /// Clears the BeeChat metadata for a gateway session (used on topic deletion).
    /// Retries up to 2 attempts with 1s delay between failures.
    public func clearTopicState(sessionKey: String) async {
        for attempt in 1...2 {
            do {
                let ok = try await rpcClient.sessionsPluginPatch(
                    key: sessionKey,
                    pluginId: "beechat",
                    namespace: "metadata",
                    value: nil as BeeChatTopicMetadata?,
                    unset: true
                )
                if ok { return }  // Success
                print("[SyncBridge] clearTopicState attempt \(attempt): pluginPatch(unset) returned false for \(sessionKey)")
            } catch {
                print("[SyncBridge] clearTopicState attempt \(attempt) failed: \(error)")
            }
            if attempt < 2 {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        print("[SyncBridge] clearTopicState: all retries exhausted for \(sessionKey) — ghost metadata may persist")
    }

    /// Republishes all non-archived, non-deleted topics to the gateway.
    /// Called on initial start (after fetchSessions) and after reconnection.
    /// Wrapped in `Task.detached` to avoid blocking the actor.
    /// Concurrency limited to 5 via `TaskGroup`.
    public func reconcileAllTopicState() {
        Task.detached { [weak self] in
            guard let self = self else { return }
            // Use TopicRepository directly — delegate doesn't expose allTopics
            let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
            guard let topics = try? topicRepo.fetchAllActive() else { return }

            await withTaskGroup(of: Void.self) { group in
                var active = 0
                for topic in topics {
                    guard let sessionKey = topic.sessionKey else { continue }
                    group.addTask {
                        await self.publishTopicState(topic: topic, sessionKey: sessionKey)
                    }
                    active += 1
                    if active >= 5 {
                        await group.next()  // Wait for one to finish before adding more
                        active -= 1
                    }
                }
            }
        }
    }

    /// Verifies that the client has `operator.admin` scope on startup.
    /// Logs a warning if the scope is missing — does not prevent the app from functioning.
    func verifyAdminScope() async {
        let scopes = await config.gatewayClient.grantedScopes()
        if scopes.isEmpty {
            print("[SyncBridge] Cannot verify operator.admin scope — handshake auth.scopes unavailable")
            return
        }
        if !scopes.contains("operator.admin") {
            print("[SyncBridge] operator.admin scope MISSING — topic publishing will fail. Scopes granted: \(scopes)")
            // Don't throw — allow app to function without topic sync.
        }
    }

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

        // Verify operator.admin scope before any topic publishing
        await verifyAdminScope()

        // Reconcile existing topics on initial connect
        reconcileAllTopicState()

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
                        try await reconciler.reconcile(activeSessionKeys: Array(streamingSessionKeys))
                    } catch {
                        print("[SyncBridge] Reconciliation error: \(error)")
                    }
                    // Reconcile topic state after reconnection
                    reconcileAllTopicState()
                }
            }
        }

        // Start usage polling for known sessions
        for sessionKey in knownSessionKeys {
            await startUsagePolling(sessionKey: sessionKey)
        }

        connectionWatchTask = Task {
            for await state in connectionStateStream() {
                if state != .connected, !streamingSessionKeys.isEmpty {
                    do {
                        try await clearAllStalledStreams(reason: "Connection lost while streaming")
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
        for task in stallTimerTasks.values { task.cancel() }
        stopUsagePolling()
        eventProcessingTask = nil
        reconnectWatchTask = nil
        connectionWatchTask = nil
        stallTimerTasks.removeAll()
        usagePollingTasks.removeAll()

        await config.gatewayClient.disconnect()

        streamingBuffer.removeAll()
        lastSeenEventSeq = nil
        streamingSessionKeys.removeAll()
    }

    // MARK: - Session filtering

    /// Determine if a session should appear by default in the sidebar.
    func sessionShouldAppearByDefault(_ info: SessionInfo) -> Bool {
        if info.key == "agent:main:main" { return true }
        if (info.totalTokens ?? 0) > 0 { return true }
        return false
    }

    public func fetchSessions() async throws -> [Session] {
        let infos = try await rpcClient.sessionsList()

        // Directly upsert sessions from gateway — no topic mapping needed
        let sessions: [Session] = infos.compactMap { info in
            guard sessionShouldAppearByDefault(info) else { return nil }
            let lastMsgDate = info.lastMessageAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            return Session(
                id: info.key,
                agentId: info.agentId ?? Self.agentId(fromSessionKey: info.key) ?? "main",
                channel: info.channel,
                title: info.label,
                lastMessageAt: lastMsgDate,
                updatedAt: Date(),
                totalTokens: info.totalTokens
            )
        }

        knownSessionKeys = Set(sessions.map { $0.id })

        try config.persistenceStore.upsertSessions(sessions)

        return sessions
    }

    public func fetchHistory(sessionKey: String, limit: Int? = nil) async throws -> [Message] {
        let fetchLimit = limit ?? config.historyFetchLimit
        let history = try await rpcClient.chatHistory(sessionKey: sessionKey, limit: fetchLimit)
        let messages = history.map { payload in
            Message(
                id: payload.id,
                sessionId: sessionKey,
                role: payload.role,
                content: payload.content,
                agentId: payload.agentId ?? Self.agentId(fromSessionKey: sessionKey),
                timestamp: payload.timestamp
            )
        }
        try config.persistenceStore.upsertMessages(messages)
        return messages
    }

    public func sendMessage(sessionKey: String, text: String, thinking: String? = nil, attachments: [ChatAttachment]? = nil) async throws -> String {
        guard !sendingSessionKeys.contains(sessionKey) else {
            throw SyncBridgeError.concurrentSendInProgress
        }
        sendingSessionKeys.insert(sessionKey)
        defer { sendingSessionKeys.remove(sessionKey) }
        
        // Abort any in-flight generation before auto-reset
        if streamingSessionKeys.contains(sessionKey) {
            do {
                try await abortGeneration(sessionKey: sessionKey)
            } catch {
                print("[SyncBridge] Abort failed during auto-reset prep: \(error)")
            }
        }
        
        var effectiveText = text
        
        // Check cooldown
        let cooldownLeft = resetCooldownCount[sessionKey] ?? 0
        if cooldownLeft > 0 {
            resetCooldownCount[sessionKey] = cooldownLeft - 1
            if cooldownLeft - 1 == 0 {
                resetCooldownCount.removeValue(forKey: sessionKey)
            }
        } else {
            // Usage check with graceful fallback
            do {
                let usage = try await rpcClient.sessionsUsage(sessionKey: sessionKey)
                if usage > 1.0 {
                    print("[SyncBridge] Usage RPC returned unexpected value: \(usage), capping at 1.0")
                }
                let cappedUsage = min(usage, 1.0)
                let threshold = await sessionResetManager.config.redDotThreshold
                if cappedUsage >= threshold {
                    delegate?.syncBridge(self, didStartAutoReset: sessionKey)
                    do {
                        let recentMessages = try fetchLocalHistory(sessionKey: sessionKey, limit: 30)
                        if recentMessages.isEmpty {
                            print("[SyncBridge] fetchLocalHistory: no messages found for session \(sessionKey)")
                        }
                        let ok = try await resetSession(sessionKey: sessionKey)
                        if ok {
                            effectiveText = formatCombinedContext(recentMessages, userMessage: text)
                            resetCooldownCount[sessionKey] = Self.resetCooldownMessages
                        }
                    } catch {
                        print("[SyncBridge] Auto-reset failed for \(sessionKey): \(error)")
                    }
                    delegate?.syncBridge(self, didStopAutoReset: sessionKey)
                }
            } catch {
                // Gateway unreachable — send without reset
                print("[SyncBridge] Usage check failed, sending without reset: \(error)")
            }
        }
        
        // Create delivery ledger entry
        let idempotencyKey = UUID().uuidString
        let entry = DeliveryLedgerEntry(
            id: UUID(),
            sessionKey: sessionKey,
            idempotencyKey: idempotencyKey,
            content: effectiveText,
            originalContent: text,
            status: .pending,
            createdAt: Date(),
            updatedAt: Date(),
            retryCount: 0
        )
        try ledgerRepo.save(entry)
        
        do {
            let runId = try await rpcClient.chatSend(
                sessionKey: sessionKey,
                message: effectiveText,
                idempotencyKey: idempotencyKey,
                thinking: thinking,
                attachments: attachments
            )
            try ledgerRepo.updateStatus(idempotencyKey: idempotencyKey, status: .sent, runId: runId)
            return runId
        } catch {
            try? ledgerRepo.updateStatus(idempotencyKey: idempotencyKey, status: .failed)
            throw error
        }
    }

    public func abortGeneration(sessionKey: String) async throws {
        cancelStallTimer(for: sessionKey)
        let ok = try await rpcClient.chatAbort(sessionKey: sessionKey)
        if ok {
            streamingBuffer.removeValue(forKey: sessionKey)
            streamingSessionKeys.remove(sessionKey)
        }
    }

    // MARK: - Session Reset Flow

    public func resetSession(sessionKey: String) async throws -> Bool {
        return try await rpcClient.sessionsReset(sessionKey: sessionKey, reason: "new")
    }

    // MARK: - Auto-reset helpers

    /// Fetch recent non-system, non-context-polluted messages from local SQLite.
    func fetchLocalHistory(sessionKey: String, limit: Int = 30) throws -> [Message] {
        let writer = try DatabaseManager.shared.writer
        return try writer.read { db in
            var messages = try Message
                .filter(Column("sessionId") == sessionKey)
                .filter(Column("role") != "tool")
                .order(Column("timestamp").desc)
                .limit(limit)
                .fetchAll(db)

            messages = messages.filter { msg in
                if let content = msg.content {
                    if content.hasPrefix("[SESSION-CONTEXT]") { return false }
                    if content.hasPrefix("[SESSION-RESET]") { return false }
                    if msg.role == "assistant" && content.contains("[tool_use:") { return false }
                }
                return true
            }

            if messages.isEmpty {
                print("[SyncBridge] fetchLocalHistory: no messages found for session \(sessionKey)")
            }

            return messages.reversed()
        }
    }

    /// Combine recent conversation history with the user's latest message.
    func formatCombinedContext(_ recentMessages: [Message], userMessage: String) -> String {
        var lines = ["[SESSION-CONTEXT] Continuing from a previous session. Recent conversation:"]
        var totalChars = lines.joined(separator: "\n").count
        let maxChars = 100_000

        for msg in recentMessages {
            let role = msg.role == "user" ? "User" : "Assistant"
            let content = msg.content ?? ""
            let msgLine = "\(role): \(content)"
            totalChars += msgLine.count + 1
            if totalChars > maxChars {
                lines.append("... [history truncated — context budget exceeded]")
                break
            }
            lines.append(msgLine)
        }

        lines.append("")
        lines.append("The user's latest message follows:")
        lines.append("")
        lines.append(userMessage)
        return lines.joined(separator: "\n")
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
        return AsyncStream { continuation in
            let observation = ValueObservation.tracking { db in
                let newest = try Message
                    .filter(Column("sessionId") == sessionKey)
                    .order(Column("timestamp").desc, Column("id").desc)
                    .limit(500)
                    .fetchAll(db)
                return Array(newest.reversed())
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

    public func streamingContent(for sessionKey: String) -> String {
        return streamingBuffer[sessionKey] ?? ""
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
        // Session keys are now gateway keys directly — no normalization needed
        try config.persistenceStore.saveMessage(message)
    }

    // MARK: - Chat event handlers (client-friendly format from gateway)

    /// Handle "chat" delta event - gateway sends accumulated text (replacement, not append)
       internal func processChatDelta(sessionKey: String, text: String) async {
        let isFirstDelta = !streamingSessionKeys.contains(sessionKey)
        streamingSessionKeys.insert(sessionKey)
        streamingBuffer[sessionKey] = text
        resetStallTimer(for: sessionKey)
        if isFirstDelta {
            delegate?.syncBridge(self, didStartStreaming: sessionKey)
        }
    }

    internal func processChatFinal(sessionKey: String) async {
        // Idempotency guard — skip if already finalized
        guard streamingSessionKeys.remove(sessionKey) != nil else { return }
        cancelStallTimer(for: sessionKey)
        streamingBuffer.removeValue(forKey: sessionKey)

        // Notify delegate FIRST so the UI transitions out of streaming immediately.
        // Fetch history in a detached task so a slow/failing RPC never blocks
        // didStopStreaming — the streaming state must always reset.
        delegate?.syncBridge(self, didStopStreaming: sessionKey)
        Task {
            do {
                _ = try await fetchHistory(sessionKey: sessionKey)
            } catch {
                print("[SyncBridge] fetchHistory failed in processChatFinal: \(error)")
            }
        }
    }

    internal func processChatError(sessionKey: String, errorMessage: String) async {
        cancelStallTimer(for: sessionKey)
        streamingBuffer.removeValue(forKey: sessionKey)
        streamingSessionKeys.remove(sessionKey)

        delegate?.syncBridge(self, didStopStreaming: sessionKey)
        Task {
            do {
                _ = try await fetchHistory(sessionKey: sessionKey)
            } catch {
                print("[SyncBridge] fetchHistory failed in processChatError: \(error)")
            }
        }
    }

    // MARK: - Agent event handler (legacy, lower-level format)

    internal func processAgentEvent(_ event: AgentEventPayload) async throws {
        // Seq tracking
        if let seq = event.seq {
            if let last = lastSeenEventSeq, seq <= last { return }

            if let last = lastSeenEventSeq, seq > last + 1 {
                // Gap detected
                try await reconciler.reconcile(activeSessionKeys: [event.sessionKey])
            }

            lastSeenEventSeq = seq
        }

        let sessionKey = event.sessionKey

        switch event.data.phase {
        case "delta":
            if let text = event.data.text {
                let isFirstDelta = !streamingSessionKeys.contains(sessionKey)
                streamingBuffer[sessionKey, default: ""] += text
                streamingSessionKeys.insert(sessionKey)
                resetStallTimer(for: sessionKey)
                if isFirstDelta {
                    delegate?.syncBridge(self, didStartStreaming: sessionKey)
                }
            }
        case "final":
            cancelStallTimer(for: sessionKey)
            if let text = event.data.text {
                let message = Message(
                    id: event.data.itemId ?? UUID().uuidString,
                    sessionId: sessionKey,
                    role: "assistant",
                    content: text,
                    agentId: Self.agentId(fromSessionKey: sessionKey),
                    timestamp: Date(timeIntervalSince1970: Double(event.ts / 1000))
                )
                try saveGatewayMessage(message)
            }
            streamingBuffer.removeValue(forKey: sessionKey)
            streamingSessionKeys.remove(sessionKey)
            try await fetchHistory(sessionKey: sessionKey)
            delegate?.syncBridge(self, didStopStreaming: sessionKey)
        case "error":
            cancelStallTimer(for: sessionKey)
            streamingBuffer.removeValue(forKey: sessionKey)
            streamingSessionKeys.remove(sessionKey)
            // Fetch history before notifying the delegate
            try await fetchHistory(sessionKey: sessionKey)
            delegate?.syncBridge(self, didStopStreaming: sessionKey)
        default:
            break
        }
    }

    internal func updateLiveness() async {
    }

    internal nonisolated static func agentId(fromSessionKey sessionKey: String) -> String? {
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1, parts[0] == "agent" else { return nil }
        return String(parts[1])
    }

    /// Normalises a session key for consistent in-memory dictionary lookups.
    /// Strips the `agent:main:` prefix and lowercases so that casing and prefix
    /// differences do not break the streaming state machine.
    private func normalizedSessionKey(_ key: String) -> String {
        SessionKeyNormalizer.stripPrefix(key).lowercased()
    }

    // MARK: - Stream stall detection (A1)

    private func resetStallTimer(for sessionKey: String) {
        stallTimerTasks[sessionKey]?.cancel()
        stallTimerTasks[sessionKey] = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.streamStallInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            do {
                try await clearStalledStream(sessionKey: sessionKey, reason: "Stream stalled - no delta for \(Int(Self.streamStallInterval))s")
            } catch {
                print("[SyncBridge] Stall timer cleanup error for \(sessionKey): \(error)")
            }
        }
    }

    private func cancelStallTimer(for sessionKey: String) {
        stallTimerTasks[sessionKey]?.cancel()
        stallTimerTasks.removeValue(forKey: sessionKey)
    }

    internal func clearStalledStream(sessionKey: String, reason: String) async throws {
        guard streamingSessionKeys.contains(sessionKey) else { return }
        cancelStallTimer(for: sessionKey)
        streamingBuffer.removeValue(forKey: sessionKey)
        streamingSessionKeys.remove(sessionKey)
        try await fetchHistory(sessionKey: sessionKey)
        delegate?.syncBridge(self, didStopStreaming: sessionKey)
    }

    internal func clearAllStalledStreams(reason: String) async throws {
        let keys = streamingSessionKeys
        for key in keys {
            do {
                try await clearStalledStream(sessionKey: key, reason: reason)
            } catch {
                print("[SyncBridge] Stream cleanup error for \(key): \(error)")
            }
        }
    }
}
