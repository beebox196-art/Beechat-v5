import Foundation
import GRDB

public struct Attachment: Codable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "attachments"
    
    public var id: String
    public var messageId: String
    public var type: String
    public var url: String?
    public var localPath: String?
    public var mimeType: String?
    public var fileName: String?
    public var fileSize: Int?
    public var createdAt: Date
    
    public init(id: String, messageId: String, type: String, url: String? = nil, localPath: String? = nil, mimeType: String? = nil, fileName: String? = nil, fileSize: Int? = nil, createdAt: Date = Date()) {
        self.id = id
        self.messageId = messageId
        self.type = type
        self.url = url
        self.localPath = localPath
        self.mimeType = mimeType
        self.fileName = fileName
        self.fileSize = fileSize
        self.createdAt = createdAt
    }
}
