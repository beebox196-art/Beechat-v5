import Foundation

public struct ChatMessagePayload: Codable, Sendable {
    public let id: String
    public let sessionKey: String
    public let role: String
    public let content: String
    public let timestamp: Date
    public let runId: String?
}
