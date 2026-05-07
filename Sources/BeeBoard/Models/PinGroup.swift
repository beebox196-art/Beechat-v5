import Foundation
import GRDB

public struct PinGroup: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, Identifiable, Sendable {
    public static let databaseTableName = "pin_groups"

    public var id: String
    public var boardId: String
    public var name: String
    public var colorHex: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        boardId: String,
        name: String = "Group",
        colorHex: String = "#8fa895",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.boardId = boardId
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
