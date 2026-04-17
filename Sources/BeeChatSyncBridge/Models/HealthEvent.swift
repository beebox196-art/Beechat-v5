import Foundation

public struct HealthEventPayload: Codable, Sendable {
    public let ok: Bool
    public let ts: Int64
    public let durationMs: Int
    public let channels: [String: HealthChannelStatus]?
    public let agents: [String: HealthAgentStatus]?
    public let sessions: [String: HealthSessionStatus]?
    
    public struct HealthChannelStatus: Codable, Sendable {
        public let status: String
    }
    public struct HealthAgentStatus: Codable, Sendable {
        public let status: String
    }
    public struct HealthSessionStatus: Codable, Sendable {
        public let status: String
    }
}
