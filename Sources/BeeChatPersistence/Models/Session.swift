import Foundation
import GRDB

public struct Session: Codable, UpsertableRecord {
    public static let databaseTableName = "sessions"
    
    public var id: String
    public var agentId: String
    public var channel: String?
    public var title: String?
    public var lastMessageAt: Date?
    public var unreadCount: Int = 0
    public var isPinned: Bool = false
    public var updatedAt: Date
    public var createdAt: Date
    
    // Session Key Alignment — Phase 1 new fields
    public var customName: String?
    public var lastMessagePreview: String?
    public var messageCount: Int = 0
    public var totalTokens: Int?
    public var isArchived: Bool = false
    
    public init(
        id: String,
        agentId: String,
        channel: String? = nil,
        title: String? = nil,
        lastMessageAt: Date? = nil,
        unreadCount: Int = 0,
        isPinned: Bool = false,
        updatedAt: Date = Date(),
        createdAt: Date = Date(),
        customName: String? = nil,
        lastMessagePreview: String? = nil,
        messageCount: Int = 0,
        totalTokens: Int? = nil,
        isArchived: Bool = false
    ) {
        self.id = id
        self.agentId = agentId
        self.channel = channel
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.customName = customName
        self.lastMessagePreview = lastMessagePreview
        self.messageCount = messageCount
        self.totalTokens = totalTokens
        self.isArchived = isArchived
    }
    
    public static let upsertColumns: [Column] = [
        Column("agentId"), Column("channel"), Column("title"),
        Column("lastMessageAt"), Column("unreadCount"), Column("isPinned"),
        Column("updatedAt"),
        Column("customName"), Column("lastMessagePreview"),
        Column("totalTokens"), Column("isArchived")
    ]
}