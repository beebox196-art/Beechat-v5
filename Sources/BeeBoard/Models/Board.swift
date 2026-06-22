import Foundation
import GRDB

public struct Board: Codable, FetchableRecord, MutablePersistableRecord, TableRecord, Identifiable, Sendable {
    public static let databaseTableName = "beeboard_boards"

    public var id: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String = "Main",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
