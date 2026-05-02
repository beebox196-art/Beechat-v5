import Foundation

public struct ChatMessagePayload: Codable, Sendable {
    public let id: String
    public let sessionKey: String
    public let role: String
    public let content: String
    public let timestamp: Date
    public let runId: String?
    public let agentId: String?

    public init(id: String, sessionKey: String, role: String, content: String, timestamp: Date, runId: String?, agentId: String? = nil) {
        self.id = id
        self.sessionKey = sessionKey
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.runId = runId
        self.agentId = agentId
    }
}
