import Foundation
import BeeChatGateway
import BeeChatPersistence
import GRDB

public actor SyncBridge {
    private let config: SyncBridgeConfiguration
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
    
    public init(config: SyncBridgeConfiguration) {
        self.config = config
        let gateway = config.gatewayClient
        self.rpcClient = RPCClient(gateway: gateway)
        self.ledgerRepo = DeliveryLedgerRepository(dbManager: DatabaseManager.shared)
        
        self.reconciler = Reconciler(
            rpcClient: RPCClient(gateway: gateway),
            persistenceStore: config.persistenceStore,
            ledgerRepo: DeliveryLedgerRepository(dbManager: DatabaseManager.shared)
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
        Task {
            let stream = await config.gatewayClient.eventStream()
            for await event in stream {
                await eventRouter?.route(event: event.event, payload: event.payload)
            }
        }
        
        // Reconciliation on reconnect
        Task {
            for await state in connectionStateStream() {
                if state == .connected {
                    try? await reconciler.reconcile(activeSessionKey: currentStreamingSessionKey)
                }
            }
        }
    }
    
    public func stop() async {
        await config.gatewayClient.disconnect()
    }
    
    public func fetchSessions() async throws -> [Session] {
        let infos = try await rpcClient.sessionsList()
        let sessions = infos.map { info in
            Session(
                id: info.key,
                agentId: info.key,
                channel: info.channel,
                title: info.label,
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
    
    public func sendMessage(sessionKey: String, text: String) async throws -> String {
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
            let runId = try await rpcClient.chatSend(sessionKey: sessionKey, message: text, idempotencyKey: idempotencyKey)
            try ledgerRepo.updateStatus(idempotencyKey: idempotencyKey, status: .sent, runId: runId)
            return runId
        } catch {
            try? ledgerRepo.updateStatus(idempotencyKey: idempotencyKey, status: .failed)
            throw error
        }
    }
    
    public func abortGeneration(sessionKey: String) async throws {
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
        AsyncStream { continuation in
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
    internal func processAgentEvent(_ event: AgentEventPayload) async {
        // Seq tracking
        if let seq = event.seq {
            if let last = lastSeenEventSeq, seq <= last { return }
            lastSeenEventSeq = seq
        }
        
        let runId = event.runId
        let sessionKey = event.sessionKey
        
        switch event.data.phase {
        case "delta":
            if let text = event.data.text {
                streamingBuffer[sessionKey, default: ""] += text
                currentStreamingSessionKey = sessionKey
                delegate?.syncBridge(self, didStartStreaming: sessionKey)
            }
        case "final":
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
            streamingBuffer.removeValue(forKey: sessionKey)
            delegate?.syncBridge(self, didStopStreaming: sessionKey)
        default:
            break
        }
    }
    
    internal func updateLiveness() async {
        // Update internal liveness clock
    }
}
