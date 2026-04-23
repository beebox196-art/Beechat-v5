import Foundation

// MARK: - Gateway RPC response types

/// Response from `sessions.list` RPC call.
struct SessionsListResponse: Codable {
    let sessions: [SessionInfo]
}

/// Response from `chat.history` RPC call.
struct ChatHistoryResponse: Codable {
    let messages: [ChatHistoryMessage]
}

/// A single message in the chat.history response.
struct ChatHistoryMessage: Codable {
    let id: String
    let role: String
    let content: String
    let timestamp: TimeInterval
    let runId: String?
}

/// Response from `chat.send` RPC call.
struct ChatSendResponse: Codable {
    let runId: String
}
