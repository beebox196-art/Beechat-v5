import Foundation
import BeeChatGateway

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
    
    /// Convenience accessor: decodes `pluginExtensions["beechat"]["metadata"]`
    /// into the typed `BeeChatTopicMetadata` struct. Returns nil when no
    /// beechat metadata exists on this session.
    public var beechatMetadata: BeeChatTopicMetadata? {
        guard let ext = pluginExtensions?["beechat"]?["metadata"],
              let data = try? JSONEncoder().encode(ext),
              let meta = try? JSONDecoder().decode(BeeChatTopicMetadata.self, from: data)
        else { return nil }
        return meta
    }
    
    private enum CodingKeys: String, CodingKey {
        case key, label, channel, model, totalTokens, lastMessageAt, agentId, spawnedBy, pluginExtensions
    }
}
