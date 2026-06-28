import Foundation
import GRDB

// MARK: - Topic Metadata (stored in metadataJSON column)

public struct TopicMetadata: Codable {
    public var projectPath: String?
    /// Telegram group ID (e.g., "-1003830552971") — stored when topic originates from a Telegram forum.
    public var telegramGroupId: String?
    /// Telegram thread/topic ID (e.g., "1" for General) — stored when topic originates from a Telegram forum.
    public var telegramThreadId: String?

    public init(projectPath: String? = nil, telegramGroupId: String? = nil, telegramThreadId: String? = nil) {
        self.projectPath = projectPath
        self.telegramGroupId = telegramGroupId
        self.telegramThreadId = telegramThreadId
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

    // MARK: - Metadata Accessors (via metadataJSON)

    /// Private helper to decode metadataJSON.
    private var decodedMetadata: TopicMetadata? {
        guard let json = metadataJSON,
              let data = json.data(using: .utf8),
              let meta = try? JSONDecoder().decode(TopicMetadata.self, from: data) else { return nil }
        return meta
    }

    /// The project path bound to this topic, stored in metadataJSON.
    /// Returns nil if no project is bound or if metadataJSON is malformed.
    public var projectPath: String? {
        return decodedMetadata?.projectPath
    }

    /// The Telegram group ID for this topic (e.g., "-1003830552971").
    /// Returns nil if this topic is not from a Telegram forum.
    public var telegramGroupId: String? {
        return decodedMetadata?.telegramGroupId
    }

    /// The Telegram thread/topic ID for this topic (e.g., "1" for General).
    /// Returns nil if this topic is not from a Telegram forum.
    public var telegramThreadId: String? {
        return decodedMetadata?.telegramThreadId
    }

    /// Update metadataJSON by applying a mutation to the decoded TopicMetadata.
    /// Handles nil/malformed metadataJSON by starting from a fresh TopicMetadata.
    private mutating func updateMetadata(_ mutation: (inout TopicMetadata) -> Void) {
        var meta = decodedMetadata ?? TopicMetadata()
        mutation(&meta)
        if let data = try? JSONEncoder().encode(meta) {
            metadataJSON = String(data: data, encoding: .utf8)
        }
    }

    /// Set or clear the project path for this topic.
    /// On macOS, validates that the path starts with `/Users/openclaw/Projects/` and that
    /// the directory exists. On iOS, skips filesystem validation since paths come from Mac via gateway.
    /// - Parameters:
    ///   - path: The project directory path, or nil to clear the binding.
    /// - Throws: `TopicError.invalidProjectPath` if validation fails.
    public mutating func setProjectPath(_ path: String?) throws {
        guard let path = path else {
            // Only clear projectPath, preserve other metadata fields
            updateMetadata { meta in
                meta.projectPath = nil
            }
            // If metadata is now empty, set to nil entirely
            if let json = metadataJSON, let data = json.data(using: .utf8),
               let meta = try? JSONDecoder().decode(TopicMetadata.self, from: data),
               meta.projectPath == nil && meta.telegramGroupId == nil && meta.telegramThreadId == nil {
                self.metadataJSON = nil
            }
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

        updateMetadata { meta in
            meta.projectPath = path
        }
    }

    /// Set the Telegram group and thread IDs for this topic.
    /// Called during session key alignment when a local UUID-keyed topic
    /// is matched to a gateway Telegram topic.
    public mutating func setTelegramMetadata(groupId: String, threadId: String) {
        updateMetadata { meta in
            meta.telegramGroupId = groupId
            meta.telegramThreadId = threadId
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