import Foundation
import GRDB

public struct Pin: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, Identifiable, Sendable {
    public static let databaseTableName = "beeboard_pins"

    public var id: String
    public var boardId: String
    public var title: String
    public var content: String?
    public var colorHex: String
    public var positionX: Double
    public var positionY: Double
    public var width: Double
    public var height: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        boardId: String,
        title: String,
        content: String? = nil,
        colorHex: String = "#f5a623",
        positionX: Double = 0,
        positionY: Double = 0,
        width: Double = 200,
        height: Double = 100,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.boardId = boardId
        self.title = title
        self.content = content
        self.colorHex = colorHex
        self.positionX = positionX
        self.positionY = positionY
        self.width = width
        self.height = height
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
