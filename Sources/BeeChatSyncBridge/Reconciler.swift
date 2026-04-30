import Foundation
import BeeChatGateway
import BeeChatPersistence

public struct Reconciler {
    private let rpcClient: RPCClientProtocol
    private let persistenceStore: BeeChatPersistenceStore
    private let ledgerRepo: DeliveryLedgerRepository
    
    public init(rpcClient: RPCClientProtocol, persistenceStore: BeeChatPersistenceStore, ledgerRepo: DeliveryLedgerRepository) {
        self.rpcClient = rpcClient
        self.persistenceStore = persistenceStore
        self.ledgerRepo = ledgerRepo
    }
    
    public func reconcile(activeSessionKeys: [String]) async throws {
        // 1. Refresh sessions list — upsert all sessions directly
        let sessions = try await rpcClient.sessionsList()
        
        let sessionModels = sessions.map { info in
            let lastMsgDate = info.lastMessageAt.flatMap { ISO8601DateFormatter().date(from: $0) }
            return Session(
                id: info.key,
                agentId: info.key,
                channel: info.channel,
                title: info.label,
                lastMessageAt: lastMsgDate,
                updatedAt: Date(),
                totalTokens: info.totalTokens
            )
        }
        try persistenceStore.upsertSessions(sessionModels)
        
        // 2. Refresh active session history
        for key in Set(activeSessionKeys) {
            let history = try await rpcClient.chatHistory(sessionKey: key, limit: 200)
            let messageModels = history.map { payload in
                Message(
                    id: payload.id,
                    sessionId: key,
                    role: payload.role,
                    content: payload.content,
                    timestamp: payload.timestamp
                )
            }
            try persistenceStore.upsertMessages(messageModels)
        }
        
        // 3. Reconcile delivery ledger — session keys are now gateway keys directly
        let pending = try ledgerRepo.fetchPending()
        for entry in pending {
            let history = try await rpcClient.chatHistory(sessionKey: entry.sessionKey, limit: 200)
            if history.contains(where: { $0.id == entry.idempotencyKey || $0.runId == entry.runId }) {
                try ledgerRepo.updateStatus(idempotencyKey: entry.idempotencyKey, status: .delivered)
            } else if entry.retryCount < 3 {
                // Retry logic would be triggered here via SyncBridge
            } else {
                try ledgerRepo.updateStatus(idempotencyKey: entry.idempotencyKey, status: .failed)
            }
        }
    }
}