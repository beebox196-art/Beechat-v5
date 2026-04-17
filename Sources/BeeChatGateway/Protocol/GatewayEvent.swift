public enum GatewayEvent: String, Codable, Sendable {
    // Real-time transcript streaming (delta/final/error states)
    case chat
    
    // Session list invalidation — triggers sessions.list refresh
    case sessionsChanged = "sessions.changed"
    
    // Per-session transcript updates (for subscribed sessions)
    case sessionMessage = "session.message"
    
    // Tool call/result updates (for subscribed sessions)
    case sessionTool = "session.tool"
    
    // User presence updates
    case presence
    
    // Keepalive/liveness
    case tick
    
    // Handshake challenge (received before connect)
    case connectChallenge = "connect.challenge"
    
    // Error event
    case error
    
    // NOTE: state.snapshot and session.update do NOT exist in the current
    // OpenClaw protocol. Initial state comes from hello-ok.snapshot.
    // Session invalidation comes from sessions.changed.
}