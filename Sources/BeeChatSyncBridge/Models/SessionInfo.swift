import Foundation

public struct SessionInfo: Codable, Sendable {
    public let key: String
    public let label: String?
    public let channel: String?
    public let model: String?
    public let totalTokens: Int?
    public let lastMessageAt: String?
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        lastMessageAt = try container.decodeIfPresent(String.self, forKey: .lastMessageAt)
    }
    
    private enum CodingKeys: String, CodingKey {
        case key, label, channel, model, totalTokens, lastMessageAt
    }
}
