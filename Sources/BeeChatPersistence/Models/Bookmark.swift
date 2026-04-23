import Foundation
import GRDB

/// A bookmarked folder for quick access from the Folder Picker.
public struct Bookmark: Codable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bookmarks"

    public var id: String
    public var name: String
    public var path: String
    public var securityBookmark: Data?
    public var iconName: String
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        securityBookmark: Data? = nil,
        iconName: String = "folder",
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.securityBookmark = securityBookmark
        self.iconName = iconName
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}