import Foundation

public struct ConnectParams: Codable, Sendable {
    public let minProtocol: Int = 3
    public let maxProtocol: Int = 3
    public let client: ClientInfo
    public let role: String
    public let scopes: [String]
    public let caps: [String]?
    public let commands: [String]?
    public let permissions: [String: Bool]?
    public let auth: AuthInfo
    public let locale: String?
    public let userAgent: String?
    public let device: DeviceIdentity?
    
    public struct ClientInfo: Codable, Sendable {
        public let id: String
        public let version: String
        public let platform: String
        public let mode: String
        
        public init(id: String, version: String, platform: String, mode: String) {
            self.id = id
            self.version = version
            self.platform = platform
            self.mode = mode
        }
    }
    
    public struct AuthInfo: Codable, Sendable {
        public let token: String
        public let deviceToken: String?
    }
}

public struct HelloOk: Codable, Sendable {
    public let type: String
    public let `protocol`: Int
    public let server: ServerInfo
    public let features: Features
    public let snapshot: [String: AnyCodable]?
    public let policy: Policy
    public let auth: AuthResult?
    
    public struct ServerInfo: Codable, Sendable {
        public let connId: String?
        public let version: String
    }
    
    public struct Features: Codable, Sendable {
        public let methods: [String]?
        public let events: [String]?
    }
    
    public struct Policy: Codable, Sendable {
        public let maxPayload: Int
        public let maxBufferedBytes: Int?
        public let tickIntervalMs: Int?
    }
    
    public struct AuthResult: Codable, Sendable {
        public let deviceToken: String?
        public let role: String?
        public let scopes: [String]?
    }
}
