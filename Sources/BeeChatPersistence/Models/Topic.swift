import Foundation
import GRDB

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
    public var createdAt: Date
    public var updatedAt: Date
    public var metadataJSON: String?
    public var messageCount: Int = 0

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
        metadataJSON: String? = nil,
        messageCount: Int = 0
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
        self.messageCount = messageCount
    }

    // messageCount excluded from upsertColumns — maintained by DB trigger, not Swift code
    public static let upsertColumns: [Column] = [
        Column("name"), Column("lastMessagePreview"), Column("lastActivityAt"),
        Column("unreadCount"), Column("sessionKey"), Column("isArchived"),
        Column("updatedAt"), Column("metadataJSON")
    ]
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