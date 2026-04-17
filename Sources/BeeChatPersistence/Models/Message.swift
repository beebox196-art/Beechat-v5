import Foundation
import GRDB

public struct Message: Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "messages"
    
    public var id: String
    public var sessionId: String
    public var role: String
    public var content: String?
    public var senderName: String?
    public var senderId: String?
    public var timestamp: Date
    public var editedAt: Date?
    public var isRead: Bool = false
    public var metadata: String? // JSON blob
    public var createdAt: Date
    
    public init(id: String, sessionId: String, role: String, content: String? = nil, senderName: String? = nil, senderId: String? = nil, timestamp: Date, editedAt: Date? = nil, isRead: Bool = false, metadata: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.senderName = senderName
        self.senderId = senderId
        self.timestamp = timestamp
        self.editedAt = editedAt
        self.isRead = isRead
        self.metadata = metadata
        self.createdAt = createdAt
    }
}
