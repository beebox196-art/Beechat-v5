import Foundation

public struct AgentEventPayload: Codable, Sendable {
    public let runId: String
    public let stream: String
    public let data: AgentEventData
    public let sessionKey: String
    public let seq: Int?
    public let ts: Int64
}

public struct AgentEventData: Codable, Sendable {
    public let itemId: String?
    public let phase: String?
    public let kind: String?
    public let title: String?
    public let status: String?
    public let name: String?
    public let text: String?
    public let toolCallId: String?
    public let meta: String?
    public let progressText: String?
    public let output: String?
}

// MARK: - Chat Event (client-friendly format from gateway)

/// The "chat" event is the client-friendly streaming format used by ClawChat.
/// The gateway emits both "chat" and "agent" events; we prefer "chat" for rendering.
public struct ChatEventPayload: Codable, Sendable {
    public let runId: String
    public let sessionKey: String
    public let seq: Int?
    /// "delta" (streaming), "final" (complete), or "error"
    public let state: String
    /// Present in delta/final events. The assembled message.
    public let message: ChatEventMessage?
    /// Present in error events.
    public let errorMessage: String?
}

public struct ChatEventMessage: Codable, Sendable {
    public let role: String
    /// Content can be a plain string or an array of ContentBlock
    public let content: ChatEventContent
    public let timestamp: Int64?
    public let stopReason: String?
}

public enum ChatEventContent: Codable, Sendable {
    case text(String)
    case blocks([ChatEventContentBlock])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .text(str)
        } else if let blocks = try? container.decode([ChatEventContentBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .text("")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let str): try container.encode(str)
        case .blocks(let blocks): try container.encode(blocks)
        }
    }
    
    /// Extract plain text regardless of content format.
    public var plainText: String {
        switch self {
        case .text(let str): return str
        case .blocks(let blocks): return blocks.filter { $0.type == "text" }.map { $0.text }.joined()
        }
    }
}

public struct ChatEventContentBlock: Codable, Sendable {
    public let type: String
    public let text: String
}
