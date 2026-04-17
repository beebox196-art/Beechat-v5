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
    
    public func reconcile(activeSessionKey: String?) async throws {
        // 1. Refresh sessions list
        let sessions = try await rpcClient.sessionsList()
        let sessionModels = sessions.map { info in
            Session(
                id: info.key,
                agentId: info.key, // Mapping key to agentId for v1
                channel: info.channel,
                title: info.label,
                lastMessageAt: nil, // In a real app, parse info.lastMessageAt
                updatedAt: Date()
            )
        }
        try persistenceStore.upsertSessions(sessionModels)
        
        // 2. Refresh active session history
        if let key = activeSessionKey {
            let history = try await rpcClient.chatHistory(sessionKey: key, limit: 200)
            let messageModels = history.map { payload in
                Message(
                    id: payload.id,
                    sessionId: payload.sessionKey,
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
