public enum GatewayEvent: String, Codable, Sendable {
    case chat
    case agent
    case tick
    case presence
    case typing
    case error
    case connectChallenge = "connect.challenge"
    case stateSnapshot = "state.snapshot"
    case sessionUpdate = "session.update"
    case messageUpdate = "message.update"
}
