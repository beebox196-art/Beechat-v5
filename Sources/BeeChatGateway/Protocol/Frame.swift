import Foundation

public enum FrameType: String, Codable, Sendable {
    case req = "req"
    case res = "res"
    case event = "event"
}

public struct RequestFrame: Codable, Sendable {
    public let type: String = "req"
    public let id: String
    public let method: String
    public let params: [String: AnyCodable]?
    
    public init(id: String, method: String, params: [String: AnyCodable]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct ResponseFrame: Codable, Sendable {
    public let type: String
    public let id: String
    public let ok: Bool
    public let payload: [String: AnyCodable]?
    public let error: ResponseError?
    
    public struct ResponseError: Codable, Sendable {
        public let message: String
        public let code: String?
    }
}

public struct EventFrame: Codable, Sendable {
    public let type: String
    public let event: String
    public let payload: [String: AnyCodable]?
    public let seq: Int?
    public let stateVersion: Int?
}
