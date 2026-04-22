import Foundation
import BeeChatGateway
import BeeChatPersistence

public struct Reconciler {
    private let rpcClient: RPCClientProtocol
    private let persistenceStore: BeeChatPersistenceStore
    private let topicRepo = TopicRepository()

    private let ledgerRepo: DeliveryLedgerRepository
    
    /// Check whether a session key belongs to a BeeChat topic.
    private func isBeeChatSession(_ sessionKey: String) -> Bool {
        // Check topics table (sessionKey column)
        if let _ = try? topicRepo.resolveTopicId(for: sessionKey) {
            return true
        }
        // Try suffix matching for "agent:main:<uuid>" format
        let stripped: String
        if sessionKey.hasPrefix("agent:main:") {
            stripped = String(sessionKey.dropFirst("agent:main:".count))
        } else {
            stripped = sessionKey
        }
        if stripped != sessionKey, let _ = try? topicRepo.resolveTopicIdBySuffix(gatewayKey: sessionKey, stripped: stripped) {
            return true
        }
        return false
    }
    
    public init(rpcClient: RPCClientProtocol, persistenceStore: BeeChatPersistenceStore, ledgerRepo: DeliveryLedgerRepository) {
        self.rpcClient = rpcClient
        self.persistenceStore = persistenceStore
        self.ledgerRepo = ledgerRepo
    }
    
    /// Normalize a gateway session key to the local topic ID.
    private func normalizeSessionKey(_ gatewayKey: String) -> String {
        let stripped: String
        if gatewayKey.hasPrefix("agent:main:") {
            stripped = String(gatewayKey.dropFirst("agent:main:".count))
        } else {
            stripped = gatewayKey
        }
        if let topicId = try? topicRepo.resolveTopicIdBySuffix(gatewayKey: gatewayKey, stripped: stripped) {
            return topicId
        }
        return gatewayKey
    }
    
    public func reconcile(activeSessionKey: String?) async throws {
        // 1. Refresh sessions list — but only persist BeeChat topic sessions
        let sessions = try await rpcClient.sessionsList()
        
        // Filter to only BeeChat topic sessions
        let beechatSessions = sessions.filter { isBeeChatSession($0.key) }
        
        let sessionModels = beechatSessions.map { info in
            let lastMsgDate = info.lastMessageAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            return Session(
                id: info.key,
                agentId: info.key, // Mapping key to agentId for v1
                channel: info.channel,
                title: info.label,
                lastMessageAt: lastMsgDate,
                updatedAt: Date()
            )
        }
        try persistenceStore.upsertSessions(sessionModels)
        
        // 2. Refresh active session history — only if it's a BeeChat topic
        if let key = activeSessionKey, isBeeChatSession(key) {
            let localKey = normalizeSessionKey(key)
            let history = try await rpcClient.chatHistory(sessionKey: key, limit: 200)
            let messageModels = history.map { payload in
                Message(
                    id: payload.id,
                    sessionId: localKey,
                    role: payload.role,
                    content: payload.content,
                    timestamp: payload.timestamp
                )
            }
            try persistenceStore.upsertMessages(messageModels)
        }
        
        // 3. Reconcile delivery ledger
        let pending = try ledgerRepo.fetchPending()
        for entry in pending {
            if let history = try? await rpcClient.chatHistory(sessionKey: entry.sessionKey, limit: 200),
               history.contains(where: { $0.id == entry.idempotencyKey || $0.runId == entry.runId }) {
                try? ledgerRepo.updateStatus(idempotencyKey: entry.idempotencyKey, status: .delivered)
            } else if entry.retryCount < 3 {
                // Retry logic would be triggered here via SyncBridge
            } else {
                try? ledgerRepo.updateStatus(idempotencyKey: entry.idempotencyKey, status: .failed)
            }
        }
    }
}
