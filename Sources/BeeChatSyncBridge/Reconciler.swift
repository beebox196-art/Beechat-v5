import Foundation
import BeeChatGateway
import BeeChatPersistence

public struct Reconciler {
    private let rpcClient: RPCClientProtocol
    private let persistenceStore: BeeChatPersistenceStore
    private let ledgerRepo: DeliveryLedgerRepository
    
    private func isBeeChatSession(_ sessionKey: String) throws -> Bool {
        try BeeChatSessionFilter.isBeeChatSession(sessionKey)
    }
    
    public init(rpcClient: RPCClientProtocol, persistenceStore: BeeChatPersistenceStore, ledgerRepo: DeliveryLedgerRepository) {
        self.rpcClient = rpcClient
        self.persistenceStore = persistenceStore
        self.ledgerRepo = ledgerRepo
    }
    
    private func normalizeSessionKey(_ gatewayKey: String) throws -> String {
        try BeeChatSessionFilter.normalize(gatewayKey)
    }
    
    public func reconcile(activeSessionKey: String?, sessionKeyMap: [String: String] = [:]) async throws {
        // 1. Refresh sessions list — but only persist BeeChat topic sessions
        let sessions = try await rpcClient.sessionsList()
        
        // Filter to only BeeChat topic sessions
        let beechatSessions = try sessions.filter { try isBeeChatSession($0.key) }
        
        let sessionModels = beechatSessions.map { info in
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
        try persistenceStore.upsertSessions(sessionModels)
        
        // 2. Refresh active session history — only if it's a BeeChat topic
        if let key = activeSessionKey, try isBeeChatSession(key) {
            let localKey = try normalizeSessionKey(key)
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
            let rpcSessionKey = sessionKeyMap.first(where: { $0.value == entry.sessionKey })?.key ?? entry.sessionKey
            let history = try await rpcClient.chatHistory(sessionKey: rpcSessionKey, limit: 200)
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
