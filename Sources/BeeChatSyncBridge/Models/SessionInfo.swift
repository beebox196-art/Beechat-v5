import Foundation
import BeeChatGateway
import BeeChatPersistence

public struct SessionInfo: Codable, Sendable {
    public let key: String
    public let label: String?
    public let channel: String?
    public let model: String?
    public let totalTokens: Int?
    public let lastMessageAt: String?
    public let agentId: String?
    public let spawnedBy: String?
    /// Plugin-specific extension data from the gateway. Nil when the gateway
    /// does not include `pluginExtensions` in the response (backwards compatible).
    public let pluginExtensions: [String: [String: AnyCodable]]?

    public init(
        key: String,
        label: String? = nil,
        channel: String? = nil,
        model: String? = nil,
        totalTokens: Int? = nil,
        lastMessageAt: String? = nil,
        agentId: String? = nil,
        spawnedBy: String? = nil,
        pluginExtensions: [String: [String: AnyCodable]]? = nil
    ) {
        self.key = key
        self.label = label
        self.channel = channel
        self.model = model
        self.totalTokens = totalTokens
        self.lastMessageAt = lastMessageAt
        self.agentId = agentId
        self.spawnedBy = spawnedBy
        self.pluginExtensions = pluginExtensions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        lastMessageAt = try container.decodeIfPresent(String.self, forKey: .lastMessageAt)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        spawnedBy = try container.decodeIfPresent(String.self, forKey: .spawnedBy)
        pluginExtensions = try container.decodeIfPresent([String: [String: AnyCodable]].self, forKey: .pluginExtensions)
    }

    /// Convenience accessor: extracts `pluginExtensions["beechat"]["metadata"]`
    /// into the typed `BeeChatTopicMetadata` struct. Returns nil when no
    /// beechat metadata exists on this session, or when the metadata is malformed
    /// (e.g. wrong types, missing required fields). Unlike an encode-decode round-trip,
    /// this makes type mismatches visible — a `nil` return means the metadata was
    /// absent or structurally invalid, not merely missing.
    public var beechatMetadata: BeeChatTopicMetadata? {
        guard let ext = pluginExtensions?["beechat"]?["metadata"]?.value as? [String: Any],
              let topicId = ext["topicId"] as? String,
              let isArchived = ext["isArchived"] as? Bool,
              let updatedAt = ext["updatedAt"] as? String
        else { return nil }
        return BeeChatTopicMetadata(
            topicId: topicId,
            isArchived: isArchived,
            projectPath: ext["projectPath"] as? String,
            updatedAt: updatedAt
        )
    }

    /// Converts to a lightweight `GatewaySessionInfo` for persistence layer.
    public var asGatewaySessionInfo: GatewaySessionInfo {
        GatewaySessionInfo(
            key: key,
            label: label,
            channel: channel,
            model: model,
            totalTokens: totalTokens,
            lastMessageAt: lastMessageAt,
            agentId: agentId,
            spawnedBy: spawnedBy
        )
    }

    private enum CodingKeys: String, CodingKey {
        case key, label, channel, model, totalTokens, lastMessageAt, agentId, spawnedBy, pluginExtensions
    }
}