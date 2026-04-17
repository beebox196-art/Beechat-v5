import Foundation

public struct SessionInfo: Codable, Sendable {
    public let key: String
    public let label: String?
    public let channel: String?
    public let model: String?
    public let totalTokens: Int?
    public let lastMessageAt: String?
}
