import Foundation

/// All known gateway event types.
/// Used for typed event routing and filtering.
public enum GatewayEvent: String, Codable, Sendable {
    case chat
    case agent
    case health
    case tick
    case presence
    case error
    case connectChallenge = "connect.challenge"
    case sessionsChanged = "sessions.changed"
    case sessionMessage = "session.message"
    case sessionTool = "session.tool"
}
