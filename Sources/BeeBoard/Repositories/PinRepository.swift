import Foundation
import GRDB
import BeeChatPersistence

public final class PinRepository {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    public func fetchPins(boardId: String) throws -> [Pin] {
        try dbManager.read { db in
            try Pin
                .filter(Column("boardId") == boardId)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func insert(_ pin: Pin) throws {
        try dbManager.write { db in
            var pin = pin
            try pin.insert(db)
        }
    }

    public func update(_ pin: Pin) throws {
        try dbManager.write { db in
            var updated = pin
            updated.updatedAt = Date()
            try updated.update(db)
        }
    }

    public func updatePosition(id: String, x: Double, y: Double) throws {
        try dbManager.write { db in
            try db.execute(
                sql: """
                UPDATE beeboard_pins
                SET positionX = ?, positionY = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [x, y, Date(), id]
            )
        }
    }

    public func updatePositions(_ updates: [(id: String, x: Double, y: Double)]) throws {
        guard !updates.isEmpty else { return }

        try dbManager.write { db in
            let now = Date()
            for update in updates {
                try db.execute(
                    sql: """
                    UPDATE beeboard_pins
                    SET positionX = ?, positionY = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [update.x, update.y, now, update.id]
                )
            }
        }
    }

    public func updateGroup(id: String, groupId: String?) throws {
        try dbManager.write { db in
            try db.execute(
                sql: "UPDATE beeboard_pins SET group_id = ?, updatedAt = ? WHERE id = ?",
                arguments: [groupId, Date(), id]
            )
        }
    }

    public func updateGroupAssignments(pinIds: [String], groupId: String?) throws {
        guard !pinIds.isEmpty else { return }

        try dbManager.write { db in
            let now = Date()
            for pinId in pinIds {
                try db.execute(
                    sql: "UPDATE beeboard_pins SET group_id = ?, updatedAt = ? WHERE id = ?",
                    arguments: [groupId, now, pinId]
                )
            }
        }
    }

    public func delete(id: String) throws {
        try dbManager.write { db in
            _ = try Pin.deleteOne(db, key: id)
        }
    }
}
