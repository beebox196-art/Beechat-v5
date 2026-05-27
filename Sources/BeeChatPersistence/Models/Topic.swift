import Foundation
import GRDB

// MARK: - Topic Metadata (stored in metadataJSON column)

public struct TopicMetadata: Codable {
    public var projectPath: String?

    public init(projectPath: String? = nil) {
        self.projectPath = projectPath
    }
}

// MARK: - Topic Error

public enum TopicError: LocalizedError {
    case invalidProjectPath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProjectPath(let msg):
            return msg
        }
    }
}

/// A user-facing topic in the BeeChat sidebar.
public struct Topic: Codable, UpsertableRecord {
    public static let databaseTableName = "topics"

    public var id: String
    public var name: String
    public var lastMessagePreview: String?
    public var lastActivityAt: Date?
    public var unreadCount: Int = 0
    public var sessionKey: String?   
    public var isArchived: Bool = false
    public var pendingGatewaySync: Bool = false
    public var createdAt: Date
    public var updatedAt: Date
    public var metadataJSON: String?
    public var messageCount: Int = 0
    public var origin: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        lastMessagePreview: String? = nil,
        lastActivityAt: Date? = nil,
        unreadCount: Int = 0,
        sessionKey: String? = nil,
        isArchived: Bool = false,
        pendingGatewaySync: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadataJSON: String? = nil,
        messageCount: Int = 0,
        origin: String? = nil
    ) {
        self.id = id
        self.name = name
        self.lastMessagePreview = lastMessagePreview
        self.lastActivityAt = lastActivityAt
        self.unreadCount = unreadCount
        self.sessionKey = sessionKey
        self.isArchived = isArchived
        self.pendingGatewaySync = pendingGatewaySync
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataJSON = metadataJSON
        self.messageCount = messageCount
        self.origin = origin
    }

    // messageCount excluded from upsertColumns — maintained by DB trigger, not Swift code
    public static let upsertColumns: [Column] = [
        Column("name"), Column("lastMessagePreview"), Column("lastActivityAt"),
        Column("unreadCount"), Column("sessionKey"), Column("isArchived"),
        Column("updatedAt"), Column("metadataJSON"),
        Column("pendingGatewaySync"), Column("origin")
    ]

    // MARK: - Project Path (via metadataJSON)

    /// The project path bound to this topic, stored in metadataJSON.
    /// Returns nil if no project is bound or if metadataJSON is malformed.
    public var projectPath: String? {
        guard let json = metadataJSON,
              let data = json.data(using: .utf8),
              let meta = try? JSONDecoder().decode(TopicMetadata.self, from: data) else { return nil }
        return meta.projectPath
    }

    /// Set or clear the project path for this topic.
    /// On macOS, validates that the path starts with `/Users/openclaw/Projects/` and that
    /// the directory exists. On iOS, skips filesystem validation since paths come from Mac via gateway.
    /// - Parameters:
    ///   - path: The project directory path, or nil to clear the binding.
    /// - Throws: `TopicError.invalidProjectPath` if validation fails.
    public mutating func setProjectPath(_ path: String?) throws {
        guard let path = path else {
            self.metadataJSON = nil
            return
        }

        #if os(macOS)
        // Resolve symlinks before prefix check
        let resolved: String
        do {
            let symlinkDest = try FileManager.default.destinationOfSymbolicLink(atPath: path)
            resolved = symlinkDest
        } catch {
            // Not a symlink or resolution failed; use original path
            resolved = path
        }

        guard resolved.hasPrefix("/Users/openclaw/Projects/") else {
            throw TopicError.invalidProjectPath("Path must be within /Users/openclaw/Projects/")
        }
        guard FileManager.default.fileExists(atPath: resolved) else {
            throw TopicError.invalidProjectPath("Directory does not exist: \(resolved)")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            throw TopicError.invalidProjectPath("Path is not a directory: \(resolved)")
        }
        #else
        // iOS: path comes from Mac via gateway metadata — skip filesystem validation
        guard !path.isEmpty else {
            throw TopicError.invalidProjectPath("Project path cannot be empty")
        }
        #endif

        var meta = TopicMetadata()
        if let json = metadataJSON,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TopicMetadata.self, from: data) {
            meta = decoded
        }
        meta.projectPath = path
        if let data = try? JSONEncoder().encode(meta) {
            metadataJSON = String(data: data, encoding: .utf8)
        }
    }
}

public struct TopicSessionBridge: Codable, UpsertableRecord {
    public static let databaseTableName = "topic_session_bridge"

    public var topicId: String
    public var spaceId: String
    public var openclawSessionKey: String
    public var bridgeVersion: Int = 1
    public var status: String = "active"
    public var createdAt: Date
    public var updatedAt: Date
    public var lastSyncAt: Date?
    public var lastError: String?
    public var retryCount: Int = 0

    public init(
        topicId: String,
        spaceId: String = "default",
        openclawSessionKey: String,
        bridgeVersion: Int = 1,
        status: String = "active",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastSyncAt: Date? = nil,
        lastError: String? = nil,
        retryCount: Int = 0
    ) {
        self.topicId = topicId
        self.spaceId = spaceId
        self.openclawSessionKey = openclawSessionKey
        self.bridgeVersion = bridgeVersion
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncAt = lastSyncAt
        self.lastError = lastError
        self.retryCount = retryCount
    }

    public static let upsertColumns: [Column] = [
        Column("spaceId"), Column("openclawSessionKey"), Column("bridgeVersion"),
        Column("status"), Column("updatedAt"), Column("lastSyncAt"),
        Column("lastError"), Column("retryCount")
    ]
}