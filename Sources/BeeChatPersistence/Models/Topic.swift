import Foundation
import GRDB

/// A user-facing topic in the BeeChat sidebar.
/// Topics are what the user sees — NOT gateway sessions.
/// Each topic maps to a gateway session via the topic_session_bridge table.
public struct Topic: Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "topics"

    public var id: String
    public var name: String
    public var lastMessagePreview: String?
    public var lastActivityAt: Date?
    public var unreadCount: Int = 0
    public var sessionKey: String?       // gateway session key (nullable until first message creates one)
    public var isArchived: Bool = false
    public var createdAt: Date
    public var updatedAt: Date
    public var metadataJSON: String?    // optional JSON blob for extensibility

    public init(
        id: String = UUID().uuidString,
        name: String,
        lastMessagePreview: String? = nil,
        lastActivityAt: Date? = nil,
        unreadCount: Int = 0,
        sessionKey: String? = nil,
        isArchived: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadataJSON: String? = nil
    ) {
        self.id = id
        self.name = name
        self.lastMessagePreview = lastMessagePreview
        self.lastActivityAt = lastActivityAt
        self.unreadCount = unreadCount
        self.sessionKey = sessionKey
        self.isArchived = isArchived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadataJSON = metadataJSON
    }

    /// Columns that should be updated on conflict (upsert). Excludes createdAt and id.
    public static let upsertColumns: [Column] = [
        Column("name"), Column("lastMessagePreview"), Column("lastActivityAt"),
        Column("unreadCount"), Column("sessionKey"), Column("isArchived"),
        Column("updatedAt"), Column("metadataJSON")
    ]
}

/// Bridge table mapping topics to gateway sessions.
/// A topic maps to one gateway session key.
/// When a user creates a topic, it starts with no session key.
/// The first message sent via chat.send creates a gateway session,
/// and we store the mapping here.
public struct TopicSessionBridge: Codable, FetchableRecord, MutablePersistableRecord {
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
}