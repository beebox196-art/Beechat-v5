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
    
    public struct DeviceIdentity: Codable, Sendable {
        public let id: String
        public let publicKey: String
        public let signature: String
        public let signedAt: Int
        public let nonce: String
        
        public init(id: String, publicKey: String, signature: String, signedAt: Int, nonce: String) {
            self.id = id
            self.publicKey = publicKey
            self.signature = signature
            self.signedAt = signedAt
            self.nonce = nonce
        }
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
    
    public init(type: String, protocol: Int, server: ServerInfo, features: Features, snapshot: [String: AnyCodable]? = nil, policy: Policy, auth: AuthResult? = nil) {
        self.type = type
        self.protocol = `protocol`
        self.server = server
        self.features = features
        self.snapshot = snapshot
        self.policy = policy
        self.auth = auth
    }
    
    /// Custom decoder: makes non-critical fields resilient to missing/malformed data
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: HelloOkCodingKeys.self)
        self.type = (try? container.decode(String.self, forKey: .type)) ?? "hello-ok"
        self.protocol = (try? container.decode(Int.self, forKey: .protocol)) ?? 3
        self.server = try container.decode(ServerInfo.self, forKey: .server)
        self.features = (try? container.decode(Features.self, forKey: .features)) ?? Features()
        self.snapshot = try? container.decodeIfPresent([String: AnyCodable].self, forKey: .snapshot)
        self.policy = try container.decode(Policy.self, forKey: .policy)
        self.auth = try? container.decodeIfPresent(AuthResult.self, forKey: .auth)
    }
    
    private enum HelloOkCodingKeys: String, CodingKey {
        case type, `protocol`, server, features, snapshot, policy, auth
    }
    
    public struct ServerInfo: Codable, Sendable {
        public let connId: String?
        public let version: String
        
        public init(connId: String? = nil, version: String) {
            self.connId = connId
            self.version = version
        }
        
        /// Custom decoder: the gateway may send "id" instead of "connId"
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: ServerInfoCodingKeys.self)
            // Try "connId" first, fall back to "id"
            if let cid = try container.decodeIfPresent(String.self, forKey: .connId) {
                self.connId = cid
            } else if let id = try container.decodeIfPresent(String.self, forKey: .id) {
                self.connId = id
            } else {
                self.connId = nil
            }
            self.version = try container.decode(String.self, forKey: .version)
        }
        
        private enum ServerInfoCodingKeys: String, CodingKey {
            case connId
            case id
            case version
        }
    }
    
    public struct Features: Codable, Sendable {
        public let methods: [String]?
        public let events: [String]?
        
        public init(methods: [String]? = nil, events: [String]? = nil) {
            self.methods = methods
            self.events = events
        }
    }
    
    public struct Policy: Codable, Sendable {
        public let maxPayload: Int
        public let maxBufferedBytes: Int?
        public let tickIntervalMs: Int?
        
        public init(maxPayload: Int, maxBufferedBytes: Int? = nil, tickIntervalMs: Int? = nil) {
            self.maxPayload = maxPayload
            self.maxBufferedBytes = maxBufferedBytes
            self.tickIntervalMs = tickIntervalMs
        }
        
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: PolicyCodingKeys.self)
            self.maxPayload = (try? container.decode(Int.self, forKey: .maxPayload)) ?? 1048576
            self.maxBufferedBytes = try? container.decodeIfPresent(Int.self, forKey: .maxBufferedBytes)
            self.tickIntervalMs = try? container.decodeIfPresent(Int.self, forKey: .tickIntervalMs)
        }
        
        private enum PolicyCodingKeys: String, CodingKey {
            case maxPayload, maxBufferedBytes, tickIntervalMs
        }
    }
    
    public struct AuthResult: Codable, Sendable {
        public let deviceToken: String?
        public let role: String?
        public let scopes: [String]?
        
        public init(deviceToken: String? = nil, role: String? = nil, scopes: [String]? = nil) {
            self.deviceToken = deviceToken
            self.role = role
            self.scopes = scopes
        }
    }
}
