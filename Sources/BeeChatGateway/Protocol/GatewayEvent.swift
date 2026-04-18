public enum GatewayEvent: String, Codable, Sendable {
    // Client-friendly streaming events (delta/final/error with assembled message)
    // This is the preferred event for rendering — used by ClawChat
    case chat
    
    // Lower-level agent/streaming events (delta/final/error with raw data)
    // Still emitted by gateway alongside "chat" but harder to parse
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