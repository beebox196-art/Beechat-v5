import Foundation

/// Lightweight session info for persistence layer — carries the same data
/// as SessionInfo but without AnyCodable (which lives in BeeChatGateway).
public struct GatewaySessionInfo: Sendable {
    public let key: String
    public let label: String?
    public let channel: String?
    public let model: String?
    public let totalTokens: Int?
    public let lastMessageAt: String?
    public let agentId: String?
    public let spawnedBy: String?

    public init(
        key: String,
        label: String? = nil,
        channel: String? = nil,
        model: String? = nil,
        totalTokens: Int? = nil,
        lastMessageAt: String? = nil,
        agentId: String? = nil,
        spawnedBy: String? = nil
    ) {
        self.key = key
        self.label = label
        self.channel = channel
        self.model = model
        self.totalTokens = totalTokens
        self.lastMessageAt = lastMessageAt
        self.agentId = agentId
        self.spawnedBy = spawnedBy
    }
}