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
