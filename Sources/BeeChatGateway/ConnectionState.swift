import Foundation

public enum ConnectionState: String, Sendable, Codable {
    case disconnected
    case connecting
    case handshaking
    case connected
    case error
}
