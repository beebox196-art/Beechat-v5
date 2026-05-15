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
    public var groupId: String?
    public var priority: Int
    public var tags: String
    public var pinType: String
    public var pinData: String?
    public var createdAt: Date
    public var updatedAt: Date

    public enum CodingKeys: String, CodingKey {
        case id
        case boardId
        case title
        case content
        case colorHex
        case positionX
        case positionY
        case width
        case height
        case groupId = "group_id"
        case priority
        case tags
        case pinType
        case pinData
        case createdAt
        case updatedAt
    }

    public static let columnNamesForCodingKeys: [CodingKeys: String] = [
        .groupId: "group_id"
    ]

    public init(
        id: String = UUID().uuidString,
        boardId: String,
        title: String,
        content: String? = nil,
        colorHex: String = "#f5a623",
        positionX: Double = 0,
        positionY: Double = 0,
        width: Double = 160,
        height: Double = 140,
        groupId: String? = nil,
        priority: Int = 0,
        tags: String = "[]",
        pinType: String = "note",
        pinData: String? = nil,
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
        self.groupId = groupId
        self.priority = priority
        self.tags = tags
        self.pinType = pinType
        self.pinData = pinData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
