import Foundation
import GRDB
import BeeChatPersistence

public enum BeeBoardMigrator {
    public static func migrate(dbManager: DatabaseManager = .shared) throws {
        let writer = try dbManager.writer
        var migrator = DatabaseMigrator()

        migrator.registerMigration("BeeBoardMigration001_CreateBoardsAndPins") { db in
            if try !db.tableExists("beeboard_boards") {
                try db.create(table: "beeboard_boards") { t in
                    t.column("id", .text).primaryKey()
                    t.column("name", .text).notNull().defaults(to: "Main")
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                    t.column("updatedAt", .datetime).notNull().defaults(to: Date())
                }
            }

            if try !db.tableExists("beeboard_pins") {
                try db.create(table: "beeboard_pins") { t in
                    t.column("id", .text).primaryKey()
                    t.column("boardId", .text).notNull()
                        .references("beeboard_boards", column: "id", onDelete: .cascade)
                    t.column("title", .text).notNull()
                    t.column("content", .text)
                    t.column("colorHex", .text).notNull().defaults(to: "#f5a623")
                    t.column("positionX", .double).notNull().defaults(to: 0)
                    t.column("positionY", .double).notNull().defaults(to: 0)
                    t.column("width", .double).notNull().defaults(to: 200)
                    t.column("height", .double).notNull().defaults(to: 100)
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                    t.column("updatedAt", .datetime).notNull().defaults(to: Date())
                }

                try db.create(index: "idx_beeboard_pins_boardId", on: "beeboard_pins", columns: ["boardId"])
            }
        }

        try migrator.migrate(writer)
    }
}
