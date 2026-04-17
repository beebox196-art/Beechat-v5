import Foundation
import BeeChatGateway
import BeeChatPersistence

public struct SyncBridgeConfiguration: Sendable {
    public let gatewayClient: GatewayClient
    public let persistenceStore: BeeChatPersistenceStore
    public let historyFetchLimit: Int
    public let reconnectDebounceSeconds: Double
    public let staleTickMultiplier: Double
    
    public init(
        gatewayClient: GatewayClient,
        persistenceStore: BeeChatPersistenceStore,
        historyFetchLimit: Int = 200,
        reconnectDebounceSeconds: Double = 1.0,
        staleTickMultiplier: Double = 2.0
    ) {
        self.gatewayClient = gatewayClient
        self.persistenceStore = persistenceStore
        self.historyFetchLimit = historyFetchLimit
        self.reconnectDebounceSeconds = reconnectDebounceSeconds
        self.staleTickMultiplier = staleTickMultiplier
    }
}
