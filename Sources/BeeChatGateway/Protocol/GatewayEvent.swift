public enum GatewayEvent: String, Codable, Sendable {
    // Real-time agent/streaming events (delta/final/error states)
    // This is the primary transcript event — NOT "chat" as previously assumed
    case agent
    
    // Session list invalidation — triggers sessions.list refresh
    case sessionsChanged = "sessions.changed"
    
    // Per-session transcript updates (for subscribed sessions)
    case sessionMessage = "session.message"
    
    // Tool call/result updates (for subscribed sessions)
    case sessionTool = "session.tool"
    
    // Health/status events
    case health
    
    // User presence updates
    case presence
    
    // Keepalive/liveness
    case tick
    
    // Handshake challenge (received before connect)
    case connectChallenge = "connect.challenge"
    
    // Error event
    case error
}