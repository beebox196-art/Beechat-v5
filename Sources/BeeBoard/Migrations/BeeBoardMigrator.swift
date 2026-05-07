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

        migrator.registerMigration("BeeBoardMigration002_PriorityTagsExpand") { db in
            if try db.columns(in: "beeboard_pins").first(where: { $0.name == "group_id" }) == nil {
                try db.alter(table: "beeboard_pins") { t in
                    t.add(column: "group_id", .text)
                }
            }
            if try db.columns(in: "beeboard_pins").first(where: { $0.name == "priority" }) == nil {
                try db.alter(table: "beeboard_pins") { t in
                    t.add(column: "priority", .integer).defaults(to: 0)
                }
            }
            if try db.columns(in: "beeboard_pins").first(where: { $0.name == "tags" }) == nil {
                try db.alter(table: "beeboard_pins") { t in
                    t.add(column: "tags", .text).defaults(to: "[]")
                }
            }
        }

        migrator.registerMigration("BeeBoardMigration003_PinGroups") { db in
            if try !db.tableExists("pin_groups") {
                try db.create(table: "pin_groups") { t in
                    t.column("id", .text).primaryKey()
                    t.column("boardId", .text).notNull()
                        .references("beeboard_boards", column: "id", onDelete: .cascade)
                    t.column("name", .text).notNull().defaults(to: "Group")
                    t.column("colorHex", .text).notNull().defaults(to: "#8fa895")
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                    t.column("updatedAt", .datetime).notNull().defaults(to: Date())
                }

                try db.create(index: "idx_pin_groups_boardId", on: "pin_groups", columns: ["boardId"])
            }
        }

        migrator.registerMigration("BeeBoardMigration004_PinData") { db in
            if try db.columns(in: "beeboard_pins").first(where: { $0.name == "pinType" }) == nil {
                try db.alter(table: "beeboard_pins") { t in
                    t.add(column: "pinType", .text).notNull().defaults(to: "note")
                }
            }
            if try db.columns(in: "beeboard_pins").first(where: { $0.name == "pinData" }) == nil {
                try db.alter(table: "beeboard_pins") { t in
                    t.add(column: "pinData", .text)  // JSON string, nullable
                }
            }
        }

        try migrator.migrate(writer)
    }
}
