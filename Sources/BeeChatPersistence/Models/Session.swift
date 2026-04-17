import Foundation
import GRDB

public struct Session: Codable, FetchableRecord, MutablePersistableRecord {
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
    
    public init(id: String, agentId: String, channel: String? = nil, title: String? = nil, lastMessageAt: Date? = nil, unreadCount: Int = 0, isPinned: Bool = false, updatedAt: Date = Date(), createdAt: Date = Date()) {
        self.id = id
        self.agentId = agentId
        self.channel = channel
        self.title = title
        self.lastMessageAt = lastMessageAt
        self.unreadCount = unreadCount
        self.isPinned = isPinned
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
    
    /// Columns that should be updated on conflict (upsert). Excludes createdAt and id.
    public static let upsertColumns: [Column] = [
        Column("agentId"), Column("channel"), Column("title"),
        Column("lastMessageAt"), Column("unreadCount"), Column("isPinned"),
        Column("updatedAt")
    ]
}