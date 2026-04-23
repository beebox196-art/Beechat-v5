import Foundation

// MARK: - Chat event payload (gateway "chat" event)

/// Payload for the "chat" event from the gateway.
/// Handles the polymorphic `content` field (String or array of content blocks).
public struct ChatEventPayload: Codable, Sendable {
    public let sessionKey: String
    public let state: String
    public let errorMessage: String?
    public let message: ChatMessage?
    
    public struct ChatMessage: Codable, Sendable {
        public let id: String?
        public let timestamp: Int64?
        public let content: String
        
        enum CodingKeys: String, CodingKey {
            case id, timestamp, content
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp)
            
            // Handle polymorphic content: String or array of content blocks
            if let text = try? container.decode(String.self, forKey: .content) {
                content = text
            } else if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                content = blocks.filter { $0.type == "text" }.compactMap { $0.text }.joined()
            } else {
                content = ""
            }
        }
    }
    
    public struct ContentBlock: Codable, Sendable {
        public let type: String
        public let text: String?
    }
}

// MARK: - Session message payload (gateway "session.message" event)

/// Payload for the "session.message" event from the gateway.
public struct SessionMessagePayload: Codable, Sendable {
    public let sessionKey: String
    public let data: SessionMessageData
    public let ts: Int64?
}

public struct SessionMessageData: Codable, Sendable {
    public let id: String?
    public let content: String
    public let role: String
}

// MARK: - Agent event payload (gateway "agent" event)
// Already defined in AgentEvent.swift — no changes needed.
