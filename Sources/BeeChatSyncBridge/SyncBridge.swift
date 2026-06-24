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
    let rpcClient: RPCClientProtocol
    private var eventRouter: EventRouter?

    private let reconciler: Reconciler
    private let ledgerRepo: DeliveryLedgerRepository

    /// Session keys known from the last fetchSessions() call
    package var knownSessionKeys: Set<String> = []

    /// Test helper: inject known session keys for testing resolveToCanonicalKey.
    package func setKnownSessionKeys(_ keys: Set<String>) {
        knownSessionKeys = keys
    }

    public weak var delegate: SyncBridgeDelegate?

    public func setDelegate(_ delegate: SyncBridgeDelegate?) {
        self.delegate = delegate
    }

    private var lastSeenEventSeq: Int?
    private var streamingBuffer: [String: String] = [:]
    private var completedContent: [String: String] = [:] // Final content after streaming ends (Phase 2)
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
    /// Tracks sessions that have already received topic context injection
    private var contextInjectedKeys: Set<String> = []
    /// Pending reset context payloads: sessionKey -> formatted context string
    /// Written by manualReset(), consumed and cleared by sendMessage()
    private var pendingResetContext: [String: String] = [:]

    /// File provider for reading project context files.
    /// macOS: LocalProjectFileProvider reads from filesystem.
    /// iOS: StubProjectFileProvider returns degraded result.
    /// Default: nil — falls back to LocalProjectFileProvider on macOS.
    private let fileProvider: ProjectFileProvider

    /// REST-over-Tailscale topic server for iPhone sync.
    /// Listens on localhost:8976, proxied via Tailscale Serve.
    /// Only active on macOS.
    #if os(macOS)
    private var topicServer: TopicServer?
    #endif

    public init(config: SyncBridgeConfiguration, fileProvider: ProjectFileProvider? = nil) {
        self.config = config
        self.fileProvider = fileProvider ?? LocalProjectFileProvider()
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

        // Subscribe to message events for all known sessions.
        // Without this, the gateway only sends `sessions.changed` (metadata) events,
        // not `session.message` (content) events. The Mac control UI calls this per-session
        // when selecting a topic; the iPhone needs it upfront for all sessions.
        for sessionKey in knownSessionKeys {
            try? await rpcClient.sessionsMessagesSubscribe(sessionKey: sessionKey)
        }

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

        // Start the REST topic server for iPhone sync (macOS only)
        #if os(macOS)
        topicServer = TopicServer()
        topicServer?.start()
        #endif
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

        // Stop the REST topic server
        #if os(macOS)
        topicServer?.stop()
        topicServer = nil
        #endif
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

        // C1 fix: Use infos (all gateway sessions) not sessions (filtered by token count).
        // A newly-created session with 0 tokens still needs to be resolvable by
        // resolveToCanonicalKey, otherwise sendMessage/manualReset fall back to the
        // stale local UUID key until the session accumulates tokens.
        knownSessionKeys = Set(infos.map { $0.key })

        try config.persistenceStore.upsertSessions(sessions)

        // Option A: Align local topic session keys with gateway canonical keys.
        // When the gateway returns a session whose key differs from the local topic's
        // sessionKey, update the local DB to use the gateway's canonical key.
        // This ensures manualReset() and sendMessage() send the correct key.
        let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
        for info in infos {
            await alignSessionKey(gatewayKey: info.key, beechatMetadata: info.beechatMetadata, topicRepo: topicRepo)
        }

        return sessions
    }

    /// Align a local topic's sessionKey with the gateway's canonical key.
    /// Called after each fetchSessions() to fix stale UUID-format keys.
    package func alignSessionKey(gatewayKey: String, beechatMetadata: BeeChatTopicMetadata?, topicRepo: TopicRepository) async {
        do {
            // Strategy 1: If the gateway session has beechat metadata with a topicId,
            // look up the local topic directly.
            // Note: fetchById now does case-insensitive matching to handle
            // UUIDs that differ in case between gateway (lowercase) and local (uppercase).
            if let meta = beechatMetadata {
                let topicId = meta.topicId
                if let topic = try topicRepo.fetchById(topicId) {
                    let localKey = topic.sessionKey ?? ""
                    if localKey != gatewayKey {
                        print("[SyncBridge] Aligning topic \(topicId) key: \(localKey) → \(gatewayKey)")
                        try topicRepo.updateSessionKey(topicId: topicId, sessionKey: gatewayKey)
                        try topicRepo.saveBridge(topicId: topicId, sessionKey: gatewayKey)
                        // Store Telegram metadata for future Strategy 4 alignments
                        if let (groupId, threadId) = SessionKeyNormalizer.parseTelegramKey(gatewayKey) {
                            try topicRepo.updateTelegramMetadata(topicId: topicId, groupId: groupId, threadId: threadId)
                        }
                        // C2 fix: Migrate messages stored under the old key so they
                        // remain reachable after alignment.
                        try DatabaseManager.shared.write { db in
                            try db.execute(
                                sql: "UPDATE messages SET sessionId = ? WHERE sessionId = ?",
                                arguments: [gatewayKey, localKey]
                            )
                        }
                    }
                    return
                }
            }

            // Strategy 2: For Telegram-discovered sessions (keys matching
            // agent:main:telegram:group:*:topic:*), try suffix-based matching
            // against local topic IDs.
            if gatewayKey.contains(":telegram:") {
                let stripped = SessionKeyNormalizer.stripPrefix(gatewayKey).lowercased()
                if let topicId = try topicRepo.resolveTopicIdBySuffix(gatewayKey: gatewayKey, stripped: stripped) {
                    if let topic = try topicRepo.fetchById(topicId) {
                        let localKey = topic.sessionKey ?? ""
                        if localKey != gatewayKey {
                            print("[SyncBridge] Aligning telegram topic \(topicId) key via suffix: \(localKey) → \(gatewayKey)")
                            try topicRepo.updateSessionKey(topicId: topicId, sessionKey: gatewayKey)
                            try topicRepo.saveBridge(topicId: topicId, sessionKey: gatewayKey)
                            // Store Telegram metadata for future alignments
                            if let (groupId, threadId) = SessionKeyNormalizer.parseTelegramKey(gatewayKey) {
                                try topicRepo.updateTelegramMetadata(topicId: topicId, groupId: groupId, threadId: threadId)
                            }
                            // C2 fix: Migrate messages stored under the old key
                            try DatabaseManager.shared.write { db in
                                try db.execute(
                                    sql: "UPDATE messages SET sessionId = ? WHERE sessionId = ?",
                                    arguments: [gatewayKey, localKey]
                                )
                            }
                        }
                    }
                    return
                }
            }

            // Strategy 4: For Telegram gateway keys where suffix matching failed,
            // parse the gateway key to extract groupId and threadId, then match
            // against local topics that have stored Telegram metadata.
            // This handles the case where a local topic was created with a random
            // UUID key (e.g., agent:main:491EA8D6-...) but the gateway key is
            // agent:main:telegram:group:-1003830552971:topic:1 — suffix match
            // can't connect them, but stored telegramThreadId can.
            if let (groupId, threadId) = SessionKeyNormalizer.parseTelegramKey(gatewayKey) {
                if let topicId = try topicRepo.resolveTopicIdByTelegramThread(groupId: groupId, threadId: threadId) {
                    if let topic = try topicRepo.fetchById(topicId) {
                        let localKey = topic.sessionKey ?? ""
                        if localKey != gatewayKey {
                            print("[SyncBridge] Aligning telegram topic \(topicId) key via thread ID match: \(localKey) → \(gatewayKey)")
                            try topicRepo.updateSessionKey(topicId: topicId, sessionKey: gatewayKey)
                            try topicRepo.saveBridge(topicId: topicId, sessionKey: gatewayKey)
                            // C2 fix: Migrate messages stored under the old key
                            try DatabaseManager.shared.write { db in
                                try db.execute(
                                    sql: "UPDATE messages SET sessionId = ? WHERE sessionId = ?",
                                    arguments: [gatewayKey, localKey]
                                )
                            }
                        }
                    }
                    // M3: No updateTelegramMetadata needed here — the topic already has
                    // telegramGroupId/telegramThreadId stored (that's how Strategy 4 found it).
                    return
                }
            }

            // Strategy 3: For gateway keys that don't match above, try a general
            // suffix match against local topic UUIDs.
            let stripped = SessionKeyNormalizer.stripPrefix(gatewayKey).lowercased()
            if stripped != gatewayKey.lowercased(),
               let topicId = try topicRepo.resolveTopicIdBySuffix(gatewayKey: gatewayKey, stripped: stripped) {
                if let topic = try topicRepo.fetchById(topicId) {
                    let localKey = topic.sessionKey ?? ""
                    if localKey != gatewayKey {
                        print("[SyncBridge] Aligning topic \(topicId) key via general suffix: \(localKey) → \(gatewayKey)")
                        try topicRepo.updateSessionKey(topicId: topicId, sessionKey: gatewayKey)
                        try topicRepo.saveBridge(topicId: topicId, sessionKey: gatewayKey)
                        // C2 fix: Migrate messages stored under the old key
                        try DatabaseManager.shared.write { db in
                            try db.execute(
                                sql: "UPDATE messages SET sessionId = ? WHERE sessionId = ?",
                                arguments: [gatewayKey, localKey]
                            )
                        }
                    }
                }
            }
        } catch {
            print("[SyncBridge] alignSessionKey error for \(gatewayKey): \(error)")
        }
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

    /// Subscribe to message events for new sessions that appeared after startup.
    /// Called by EventRouter when sessions.changed delivers new session keys.
    package func subscribeNewSessions(sessionKeys: Set<String>) async {
        let newKeys = sessionKeys.subtracting(knownSessionKeys)
        for key in newKeys {
            try? await rpcClient.sessionsMessagesSubscribe(sessionKey: key)
        }
        knownSessionKeys = knownSessionKeys.union(newKeys)
    }

    public func sendMessage(sessionKey: String, text: String, thinking: String? = nil, attachments: [ChatAttachment]? = nil, topic: Topic? = nil) async throws -> String {
        // Resolve local key to gateway canonical key if they differ
        var effectiveSessionKey = sessionKey
        if let canonicalKey = await resolveToCanonicalKey(localKey: sessionKey) {
            print("[SyncBridge] sendMessage: resolved \(sessionKey) → \(canonicalKey)")
            effectiveSessionKey = canonicalKey
        }
        
        guard !sendingSessionKeys.contains(effectiveSessionKey) else {
            throw SyncBridgeError.concurrentSendInProgress
        }
        sendingSessionKeys.insert(effectiveSessionKey)
        defer { sendingSessionKeys.remove(effectiveSessionKey) }
        
        // Abort any in-flight generation before auto-reset
        if streamingSessionKeys.contains(effectiveSessionKey) {
            do {
                try await abortGeneration(sessionKey: effectiveSessionKey)
            } catch {
                print("[SyncBridge] Abort failed during auto-reset prep: \(error)")
            }
        }
        
        var effectiveText = text
        var didAutoReset = false
        
        // Inject pending manual reset context if present (consumed once)
        // Check both original and canonical keys for pending context
        if let pendingContext = pendingResetContext.removeValue(forKey: effectiveSessionKey) ?? pendingResetContext.removeValue(forKey: sessionKey) {
            if effectiveText.isEmpty {
                effectiveText = pendingContext
            } else {
                effectiveText = "\(pendingContext)\n\n\(effectiveText)"
            }
            didAutoReset = true  // Reuse flag to skip topic context injection below
        }
        
        // Auto-reset at 80% safety ceiling — always fires, no cooldown check
        // Cooldown only applies to sub-threshold resets (which don't exist in hybrid model)
        let cooldownLeft = resetCooldownCount[effectiveSessionKey] ?? resetCooldownCount[sessionKey] ?? 0
        if cooldownLeft > 0 {
            resetCooldownCount[effectiveSessionKey] = cooldownLeft - 1
            if cooldownLeft - 1 == 0 {
                resetCooldownCount.removeValue(forKey: effectiveSessionKey)
            }
        }
        
        // Usage check for auto-reset (80% ceiling)
        if !didAutoReset {
            do {
                let usage = try await rpcClient.sessionsUsage(sessionKey: effectiveSessionKey)
                if usage > 1.0 {
                    print("[SyncBridge] Usage RPC returned unexpected value: \(usage), capping at 1.0")
                }
                let cappedUsage = min(usage, 1.0)
                let autoThreshold = await sessionResetManager.config.autoResetThreshold
                if cappedUsage >= autoThreshold {
                    delegate?.syncBridge(self, didStartAutoReset: effectiveSessionKey)
                    do {
                        // Try both keys for history lookup
                        var recentMessages = try fetchLocalHistory(sessionKey: effectiveSessionKey, limit: 30)
                        if recentMessages.isEmpty && effectiveSessionKey != sessionKey {
                            recentMessages = try fetchLocalHistory(sessionKey: sessionKey, limit: 30)
                        }
                        if recentMessages.isEmpty {
                            print("[SyncBridge] fetchLocalHistory: no messages found for session \(effectiveSessionKey)")
                        }
                        let ok = try await resetSession(sessionKey: effectiveSessionKey)
                        if ok {
                            effectiveText = formatCombinedContext(recentMessages, userMessage: text)
                            let cooldown = await sessionResetManager.config.cooldownMessages
                            resetCooldownCount[effectiveSessionKey] = cooldown
                            didAutoReset = true
                        }
                    } catch {
                        print("[SyncBridge] Auto-reset failed for \(effectiveSessionKey): \(error)")
                    }
                    delegate?.syncBridge(self, didStopAutoReset: effectiveSessionKey)
                }
            } catch {
                // Gateway unreachable — send without reset
                print("[SyncBridge] Usage check failed, sending without reset: \(error)")
            }
        }
        
        // Topic context injection
        if isTopicContextEnabled, let topic, !contextInjectedKeys.contains(effectiveSessionKey) {
            if !didAutoReset {
                let topicContextHeader = buildContextHeader(topic: topic)

                // Phase 2: include [TOPIC-SUMMARY] size in the budget guard
                let summarySize: Int = {
                    let workspacePath = "/Users/openclaw/.openclaw/workspace/"
                    guard let projectPath = topic.projectPath else { return 0 }
                    return TopicSummaryWriter.read(
                        topicId: topic.id,
                        projectPath: projectPath,
                        workspacePath: workspacePath
                    )?.utf8.count ?? 0
                }()

                // Kieran Warning-3: combined 50KB cap for auto-reset + topic context + summary
                let autoResetBytes = effectiveText.utf8.count
                let topicContextBytes = topicContextHeader.utf8.count + summarySize
                if autoResetBytes + topicContextBytes > 50_000 {
                    let remaining = 50_000 - autoResetBytes
                    if remaining > 0 {
                        // Trim summary first (most likely to be stale), then project context
                        var adjusted = topicContextHeader
                        if summarySize > 0 && summarySize < remaining {
                            // Summary fits, trim project context
                            let forProject = remaining - summarySize
                            if forProject > 0 {
                                let prefixBytes = topicContextHeader.utf8.prefix(forProject)
                                adjusted = String(data: Data(prefixBytes), encoding: .utf8) ?? ""
                                    + "\n... [context truncated]"
                            } else {
                                // Only room for summary
                                adjusted = ""
                            }
                        } else {
                            // Trim topic context
                            let prefixBytes = topicContextHeader.utf8.prefix(remaining)
                            adjusted = String(data: Data(prefixBytes), encoding: .utf8) ?? ""
                                + "\n... [context truncated]"
                        }
                        effectiveText = "\(adjusted)\n\n\(effectiveText)"
                    }
                    // else: auto-reset alone exceeds budget; skip topic context
                } else {
                    effectiveText = "\(topicContextHeader)\n\n\(effectiveText)"
                }
            }
            contextInjectedKeys.insert(effectiveSessionKey)
        }
        
        // Create delivery ledger entry — use canonical key for session tracking
        let idempotencyKey = UUID().uuidString
        let entry = DeliveryLedgerEntry(
            id: UUID(),
            sessionKey: effectiveSessionKey,
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
                sessionKey: effectiveSessionKey,
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
        // DB-first: Resolve via database if possible, same pattern as manualReset.
        // This ensures auto-reset also uses the canonical key from alignment,
        // not a stale UUID key from the in-memory Topic struct.
        var effectiveKey = sessionKey
        let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
        if let topicId = try? topicRepo.resolveTopicId(for: sessionKey),
           let dbKey = try? topicRepo.resolveCurrentSessionKey(topicId: topicId),
           dbKey != sessionKey {
            effectiveKey = dbKey
        }

        // H2 fix: clear contextInjectedKeys
        contextInjectedKeys.remove(effectiveKey)
        for key in contextInjectedKeys {
            if let canonical = await resolveToCanonicalKey(localKey: key), canonical == effectiveKey {
                contextInjectedKeys.remove(key)
            }
        }
        return try await rpcClient.sessionsReset(sessionKey: effectiveKey, reason: "new")
    }

    /// Manual reset triggered by user (amber dot tap or context menu).
    /// Fetches local history, resets session on gateway, stores context for next send.
    /// Returns true if reset succeeded, false if already pending or failed.
    /// No cooldown — user-initiated resets always execute.
    public func manualReset(sessionKey: String) async throws -> Bool {
        // DB-first: If the caller passed a topic-derived key that may be stale,
        // look up the current canonical key from the database (which alignment
        // has already updated). This avoids sending a stale UUID key to the gateway.
        var effectiveSessionKey = sessionKey
        let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
        if let topicId = try? topicRepo.resolveTopicId(for: sessionKey),
           let dbKey = try? topicRepo.resolveCurrentSessionKey(topicId: topicId),
           dbKey != sessionKey {
            print("[SyncBridge] manualReset: DB lookup resolved \(sessionKey) → \(dbKey)")
            effectiveSessionKey = dbKey
        }

        // Then also try resolveToCanonicalKey as before (covers cases where DB
        // hasn't been aligned yet but knownSessionKeys has the mapping)
        if let canonicalKey = await resolveToCanonicalKey(localKey: effectiveSessionKey) {
            print("[SyncBridge] manualReset: resolved \(effectiveSessionKey) → \(canonicalKey)")
            effectiveSessionKey = canonicalKey
        }

        // Guard against double-tap: if pending context already exists for either key, skip
        guard pendingResetContext[effectiveSessionKey] == nil && pendingResetContext[sessionKey] == nil else {
            print("[SyncBridge] manualReset: pending context already exists for \(sessionKey), skipping")
            return true
        }

        // Abort any in-flight generation
        if streamingSessionKeys.contains(sessionKey) || streamingSessionKeys.contains(effectiveSessionKey) {
            try? await abortGeneration(sessionKey: effectiveSessionKey)
        }

        delegate?.syncBridge(self, didStartManualReset: effectiveSessionKey)

        // Fetch local history BEFORE reset (reads from local SQLite, not gateway)
        // Try both the original key and the canonical key for history lookup
        var recentMessages: [Message]
        do {
            recentMessages = try fetchLocalHistory(sessionKey: sessionKey, limit: 30)
            // If no messages found under the original key, try the canonical key
            if recentMessages.isEmpty && effectiveSessionKey != sessionKey {
                recentMessages = try fetchLocalHistory(sessionKey: effectiveSessionKey, limit: 30)
            }
        } catch {
            recentMessages = try fetchLocalHistory(sessionKey: effectiveSessionKey, limit: 30)
        }

        // Reset session on gateway using the canonical key
        let ok = try await resetSession(sessionKey: effectiveSessionKey)

        if ok {
            // Format context and store for next send
            let contextPayload = formatCombinedContext(recentMessages, userMessage: "")
            pendingResetContext[sessionKey] = contextPayload
            if effectiveSessionKey != sessionKey {
                pendingResetContext[effectiveSessionKey] = contextPayload
            }

            // Update usage cache so UI reflects the reset immediately
            sessionUsageCache[effectiveSessionKey] = 0
            if effectiveSessionKey != sessionKey {
                sessionUsageCache[sessionKey] = 0
            }

            // Clear local Session.totalTokens so the GRDB observation in
            // MessageViewModel.startSessionUsageObservation() fires,
            // which calls refreshUsageFromSessions() and clears the
            // orange-dot indicator (which reads from sessionUsageMap,
            // not from this in-memory cache).
            // Clear both keys to handle both the old local key and the canonical key.
            do {
                try DatabaseManager.shared.write { db in
                    try db.execute(
                        sql: "UPDATE sessions SET totalTokens = NULL WHERE id IN (?, ?)",
                        arguments: [effectiveSessionKey, sessionKey]
                    )
                }
            } catch {
                // Non-fatal: in-memory cache is still cleared, and the next
                // fetchSessions() will refresh totalTokens from the gateway.
                print("[SyncBridge] manualReset: failed to clear local totalTokens for \(effectiveSessionKey): \(error)")
            }
        }

        delegate?.syncBridge(self, didStopManualReset: effectiveSessionKey)
        return ok
    }

    /// Clear pending reset context for all sessions except the given one.
    /// Called on topic switch to avoid stale context being injected into the wrong session.
    /// H1 fix: Accepts optional additional except keys so both the local and canonical
    /// key forms are preserved when key resolution is known.
    public func clearPendingResetContext(except sessionKey: String?, exceptAdditional additionalExceptKeys: Set<String>? = nil) {
        let exceptKeys: Set<String>
        if let key = sessionKey {
            exceptKeys = Set([key]).union(additionalExceptKeys ?? [])
        } else {
            exceptKeys = additionalExceptKeys ?? []
        }
        if exceptKeys.isEmpty {
            pendingResetContext.removeAll()
        } else {
            for k in pendingResetContext.keys where !exceptKeys.contains(k) {
                pendingResetContext.removeValue(forKey: k)
            }
        }
    }

    // MARK: - Session Key Resolution

    /// Resolve a local session key to the canonical gateway key.
    /// Checks the gateway's session list for a session whose beechat metadata
    /// references the same topic, or whose key suffix-matches the local key.
    /// Returns nil if the local key is already canonical or no mapping is found.
    public func resolveToCanonicalKey(localKey: String) async -> String? {
        // If already a canonical gateway key (contains "telegram:" or matches known keys), no resolution needed
        if localKey.contains(":telegram:") || knownSessionKeys.contains(localKey) {
            return nil
        }

        // Check knownSessionKeys for a gateway session whose stripped suffix matches
        // our local key's stripped suffix (i.e., the UUID part after "agent:main:")
        let strippedLocal = SessionKeyNormalizer.stripPrefix(localKey).lowercased()
        for gatewayKey in knownSessionKeys {
            let strippedGateway = SessionKeyNormalizer.stripPrefix(gatewayKey).lowercased()
            if strippedGateway == strippedLocal && gatewayKey != localKey {
                return gatewayKey
            }
        }

        // Check local DB for topics whose sessionKey is the local key,
        // and see if any gateway session has beechat metadata with that topicId
        do {
            let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
            if let topicId = try topicRepo.resolveTopicId(for: localKey) {
                // We have a local topic for this key; check gateway sessions
                // whose key might map to this same topicId
                for gatewayKey in knownSessionKeys {
                    let stripped = SessionKeyNormalizer.stripPrefix(gatewayKey).lowercased()
                    if stripped == topicId.lowercased() && gatewayKey != localKey {
                        return gatewayKey
                    }
                }
            }
        } catch {
            print("[SyncBridge] resolveToCanonicalKey error: \(error)")
        }

        return nil
    }

    // MARK: - Topic Context Injection

    /// Feature flag for topic context injection. Uses UserDefaults directly
    /// because @AppStorage doesn't compile in an actor context.
    private var isTopicContextEnabled: Bool {
        UserDefaults.standard.object(forKey: "feature_topicContextInjection") as? Bool ?? true
    }

    /// Build a context header that tells the agent which topic the user is in.
    /// Reads actual project files via the injected ProjectFileProvider and injects
    /// their content — no longer just instructions to read files.
    ///
    /// Phase 2 upgrade: also injects [TOPIC-SUMMARY] when a summary file exists.
    func buildContextHeader(topic: Topic) -> String {
        var header = "[TOPIC-CONTEXT]\nTopic: \(topic.name)"

        guard let projectPath = topic.projectPath else { return header }

        header += "\n[PROJECT-CONTEXT]\nProject: \(URL(fileURLWithPath: projectPath).lastPathComponent)"
        header += "\nProject path: \(projectPath)"
        header += "\n---"

        // Read and inject actual file content via the provider
        let result = fileProvider.readContextFiles(projectPath: projectPath)
        if !result.text.isEmpty {
            header += "\n\(result.text)"
        } else {
            header += "\n(no project files found)"
        }

        header += "\n---"
        // Kieran Warning-5: use file modification time, not Date.now
        let statusPath = (projectPath as NSString).appendingPathComponent("STATUS.md")
        if let modDate = try? FileManager.default.attributesOfItem(atPath: statusPath)[.modificationDate] as? Date {
            header += "\nProject context read at \(modDate.formatted(date: .abbreviated, time: .shortened))."
        } else {
            header += "\nProject context read at \(Date.now.formatted(date: .abbreviated, time: .shortened))."
        }
        header += "\nUse the project files above as your working context. Reference STATUS.md for current state before making changes."

        // Phase 2: inject topic summary if one exists
        let workspacePath = "/Users/openclaw/.openclaw/workspace/"
        if let summaryContent = TopicSummaryWriter.read(
            topicId: topic.id,
            projectPath: projectPath,
            workspacePath: workspacePath
        ) {
            header += "\n\n[TOPIC-SUMMARY]"
            header += "\n\(summaryContent)"
        }

        return header
    }

    /// Clear context injection state for a session so the next message re-injects the full header.
    /// Called when a topic's project binding changes, so [PROJECT-CONTEXT] appears without a full reset.
    public func requeueContextInjection(sessionKey: String) {
        contextInjectedKeys.remove(sessionKey)
    }

    // MARK: - Topic Summary Pipeline (Phase 2)

    /// Sends a message for topic summary extraction and returns the runId.
    /// Called by TopicSummaryExtractor — separate from sendMessage so it doesn't
    /// trigger topic context injection or auto-reset logic.
    internal func sendExtractionMessage(
        sessionKey: String,
        message: String,
        idempotencyKey: String
    ) async throws -> String {
        // Don't gate on sendingSessionKeys — extraction is a low-priority background send
        // that shouldn't block user messages. If a user message is in flight, the extraction
        // will queue behind it naturally (gateway handles ordering).
        let runId = try await rpcClient.chatSend(
            sessionKey: sessionKey,
            message: message,
            idempotencyKey: idempotencyKey,
            thinking: nil,
            attachments: nil
        )
        return runId
    }

    /// Returns true if the given session is currently streaming (has an in-progress response).
    public func isSessionStreaming(_ sessionKey: String) -> Bool {
        streamingSessionKeys.contains(sessionKey)
    }

    /// Triggers the full topic summary extraction + write pipeline.
    ///
    /// Called from TopicViewModel.saveTopicSummary() when the user clicks
    /// "Save Topic Summary" in the context menu.
    ///
    /// - Parameter topicId: The topic's unique identifier.
    /// - Returns: The path to the written summary file, or nil if nothing was saved.
    public func triggerTopicSummary(topicId: String) async -> String? {
        // Look up the topic
        let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
        guard let topic = try? topicRepo.fetchById(topicId) else {
            print("[SyncBridge] triggerTopicSummary: topic not found: \(topicId)")
            return nil
        }

        guard let sessionKey = topic.sessionKey else {
            print("[SyncBridge] triggerTopicSummary: topic has no session key: \(topicId)")
            return nil
        }

        // Extract durable items from the conversation
        let extracted = await TopicSummaryExtractor.extract(
            topicId: topicId,
            topicName: topic.name,
            projectPath: topic.projectPath,
            bridge: self
        )

        guard let extracted = extracted, !extracted.isEmpty else {
            print("[SyncBridge] triggerTopicSummary: no durable items extracted for \(topicId)")
            return nil
        }

        // Write/merge the summary
        let workspacePath = "/Users/openclaw/.openclaw/workspace/"
        let resultPath = TopicSummaryWriter.write(
            topicId: topicId,
            topicName: topic.name,
            projectPath: topic.projectPath,
            workspacePath: workspacePath,
            extracted: extracted
        )

        if let resultPath = resultPath {
            print("[SyncBridge] Topic summary written: \(resultPath)")
        } else {
            print("[SyncBridge] triggerTopicSummary: write failed for \(topicId)")
        }

        return resultPath
    }

    /// Look up the project path for a session key by resolving the topic.
    private func projectPathForSession(_ sessionKey: String) throws -> String? {
        let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
        guard let topicId = try topicRepo.resolveTopicId(for: sessionKey) else { return nil }
        let topic = try topicRepo.fetchById(topicId)
        return topic?.projectPath
    }

    /// Compose a concise 1–2 paragraph summary from recent messages.
    /// Target 200–400 characters. Falls back to a minimal string on low content or poor quality.
    /// Appends `[PROJECT-CONTEXT]` lines if a projectPath is provided.
    func formatSessionSummary(_ recentMessages: [Message], projectPath: String? = nil) -> String {
        // Filter and extract meaningful content
        var userTopics: [String] = []
        var assistantOutcomes: [String] = []

        for msg in recentMessages {
            let content = msg.content ?? ""
            if msg.role == "user" {
                if !content.isEmpty {
                    let firstLine = content.split(separator: "\n").first.flatMap { String($0) } ?? ""
                    if !firstLine.isEmpty { userTopics.append(firstLine) }
                }
            } else if msg.role == "assistant" {
                if !content.isEmpty {
                    let firstLine = content.split(separator: "\n").first.flatMap { String($0) } ?? ""
                    if !firstLine.isEmpty { assistantOutcomes.append(firstLine) }
                }
            }
        }

        // Quality gate: need some signal
        let totalSignal = userTopics.joined() + assistantOutcomes.joined()
        if recentMessages.count < 3 || totalSignal.count < 50 {
            return "Previous session reset. Brief conversation history available if needed."
        }

        // Compose paragraph 1 — Topics + Progress
        var para1 = "We were discussing "
        if userTopics.count >= 2 {
            para1 += userTopics.prefix(2).joined(separator: " and ") + "."
        } else if let first = userTopics.first {
            para1 += first + "."
        } else {
            para1 = "Recent conversation covered several topics."
        }

        // Add outcomes from assistant
        if !assistantOutcomes.isEmpty {
            let outcomeText = assistantOutcomes.prefix(2).joined(separator: "; ")
            para1 += " " + outcomeText + "."
        }

        // Compose paragraph 2 — Next steps
        var para2 = ""
        if userTopics.count > 2 {
            let remaining = userTopics.dropFirst(2).prefix(2)
            para2 = "Next: " + remaining.joined(separator: ", ") + "."
        }

        var summary = para1
        if !para2.isEmpty {
            summary += "\n\n" + para2
        }

        // Append project context if available
        if let projectPath = projectPath {
            summary += "\n\n[PROJECT-CONTEXT]\nProject: \(projectPath)"
            summary += "\nRead \(projectPath)STATUS.md for project context."
            summary += "\nRead \(projectPath)decisions.md and \(projectPath)corrections.md if they exist."
            summary += "\nWhen this session ends or significant progress is made, append a dated entry to \(projectPath)ACTIVITY.md using the format: ### YYYY-MM-DD — One-line summary."
        }

        return summary
    }

    // MARK: - Auto-reset helpers

    /// Fetch recent non-system, non-context-polluted messages from local SQLite.
    /// IMPORTANT: This deliberately reads from local SQLite, not the gateway.
    /// After a session reset, the gateway's history is wiped, so reading from the gateway
    /// would return empty. Local SQLite preserves messages for context carry-forward.
    /// Changing this to call the gateway would break the reset flow.
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
                    if content.hasPrefix("[TOPIC-CONTEXT]") { return false }
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
        if let content = streamingBuffer[sessionKey], !content.isEmpty {
            return content
        }
        return completedContent[sessionKey] ?? ""
    }

    /// Clear the cached completed content for a session key (Phase 2).
    public func clearCompletedContent(for sessionKey: String) {
        completedContent.removeValue(forKey: sessionKey)
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

    /// Handle "chat" delta event - v4 sends incremental text with replace semantics.
    /// - Parameter replace: When true, set the buffer to `text` (full replacement or first delta).
    ///   When false, append `text` to the existing buffer.
    ///   v3 compat: callers pass replace=true when using cumulative message.content.
       internal func processChatDelta(sessionKey: String, text: String, replace: Bool = true) async {
        let isFirstDelta = !streamingSessionKeys.contains(sessionKey)
        streamingSessionKeys.insert(sessionKey)
        if replace || isFirstDelta {
            streamingBuffer[sessionKey] = text
        } else {
            streamingBuffer[sessionKey, default: ""] += text
        }
        resetStallTimer(for: sessionKey)
        if isFirstDelta {
            delegate?.syncBridge(self, didStartStreaming: sessionKey)
        }
    }

    internal func processChatFinal(sessionKey: String) async {
        // Idempotency guard — skip if already finalized
        guard streamingSessionKeys.remove(sessionKey) != nil else { return }
        cancelStallTimer(for: sessionKey)
        // Capture final content BEFORE clearing the buffer (Phase 2 race fix)
        completedContent[sessionKey] = streamingBuffer[sessionKey]
        streamingBuffer.removeValue(forKey: sessionKey)

        // Notify delegate FIRST so the UI transitions out of streaming immediately.
        // Fetch history in a detached task so a slow/failing RPC never blocks
        // didStopStreaming — the streaming state must always reset.
        delegate?.syncBridge(self, didStopStreaming: sessionKey)
        Task {
            do {
                _ = try await fetchHistory(sessionKey: sessionKey)
                try? config.persistenceStore.dedupLocalMessages(sessionKey: sessionKey)
            } catch {
                print("[SyncBridge] fetchHistory failed in processChatFinal: \(error)")
            }
        }
    }

    internal func processChatError(sessionKey: String, errorMessage: String) async {
        cancelStallTimer(for: sessionKey)
        completedContent[sessionKey] = streamingBuffer[sessionKey]
        streamingBuffer.removeValue(forKey: sessionKey)
        streamingSessionKeys.remove(sessionKey)

        delegate?.syncBridge(self, didStopStreaming: sessionKey)
        Task {
            do {
                _ = try await fetchHistory(sessionKey: sessionKey)
                try? config.persistenceStore.dedupLocalMessages(sessionKey: sessionKey)
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
            completedContent[sessionKey] = streamingBuffer[sessionKey]
            streamingBuffer.removeValue(forKey: sessionKey)
            streamingSessionKeys.remove(sessionKey)
            try await fetchHistory(sessionKey: sessionKey)
            try? config.persistenceStore.dedupLocalMessages(sessionKey: sessionKey)
            delegate?.syncBridge(self, didStopStreaming: sessionKey)
        case "error":
            cancelStallTimer(for: sessionKey)
            completedContent[sessionKey] = streamingBuffer[sessionKey]
            streamingBuffer.removeValue(forKey: sessionKey)
            streamingSessionKeys.remove(sessionKey)
            // Fetch history before notifying the delegate
            try await fetchHistory(sessionKey: sessionKey)
            try? config.persistenceStore.dedupLocalMessages(sessionKey: sessionKey)
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
