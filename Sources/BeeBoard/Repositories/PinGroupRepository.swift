import Foundation
import GRDB
import BeeChatPersistence

public final class PinGroupRepository {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    public func fetchGroups(boardId: String) throws -> [PinGroup] {
        try dbManager.read { db in
            try PinGroup
                .filter(Column("boardId") == boardId)
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func insert(_ group: PinGroup) throws {
        try dbManager.write { db in
            var group = group
            try group.insert(db)
        }
    }

    public func update(_ group: PinGroup) throws {
        try dbManager.write { db in
            var updated = group
            updated.updatedAt = Date()
            try updated.update(db)
        }
    }

    public func delete(id: String) throws {
        try dbManager.write { db in
            // Explicitly clear member group_id before deleting the group.
            // Foreign keys are OFF in BeeChat, so this isn't automatic.
            try db.execute(
                sql: "UPDATE beeboard_pins SET group_id = NULL, updatedAt = ? WHERE group_id = ?",
                arguments: [Date(), id]
            )
            _ = try PinGroup.deleteOne(db, key: id)
        }
    }
}
