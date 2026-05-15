import Foundation

// MARK: - Chat event payload (gateway "chat" event)

/// Payload for the "chat" event from the gateway.
/// Handles the polymorphic `content` field (String or array of content blocks).
public struct ChatEventPayload: Codable, Sendable {
    public let sessionKey: String
    public let state: String
    public let errorMessage: String?
    public let errorKind: String?
    public let agentId: String?
    public let message: ChatMessage?
    
    // v4 streaming fields
    public let runId: String?
    public let seq: Int?
    public let spawnedBy: String?
    public let deltaText: String?
    public let replace: Bool?
    public let stopReason: String?
    
    private enum CodingKeys: String, CodingKey {
        case sessionKey, state, errorMessage, errorKind, agentId, message
        case runId, seq, spawnedBy, deltaText, replace, stopReason
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        state = try container.decode(String.self, forKey: .state)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        errorKind = try container.decodeIfPresent(String.self, forKey: .errorKind)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        message = try container.decodeIfPresent(ChatEventPayload.ChatMessage.self, forKey: .message)
        runId = try container.decodeIfPresent(String.self, forKey: .runId)
        seq = try container.decodeIfPresent(Int.self, forKey: .seq)
        spawnedBy = try container.decodeIfPresent(String.self, forKey: .spawnedBy)
        deltaText = try container.decodeIfPresent(String.self, forKey: .deltaText)
        replace = try container.decodeIfPresent(Bool.self, forKey: .replace)
        stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
    }
    
    public struct ChatMessage: Codable, Sendable {
        public let id: String?
        public let timestamp: Int64?
        public let agentId: String?
        public let content: String
        
        enum CodingKeys: String, CodingKey {
            case id, timestamp, agentId, content
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            timestamp = try container.decodeIfPresent(Int64.self, forKey: .timestamp)
            agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
            
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
    public let agentId: String?
    public let data: SessionMessageData
    public let ts: Int64?
}

public struct SessionMessageData: Codable, Sendable {
    public let id: String?
    public let content: String
    public let role: String
    public let agentId: String?
}

// MARK: - Agent event payload (gateway "agent" event)
// Already defined in AgentEvent.swift — no changes needed.
