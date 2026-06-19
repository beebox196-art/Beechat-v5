import Foundation
import GRDB
import BeeChatPersistence

public final class BoardRepository {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    public func fetchOrCreateDefaultBoard() throws -> Board {
        try dbManager.write { db in
            if let existing = try Board
                .filter(Column("name") == "Main")
                .order(Column("createdAt"))
                .fetchOne(db) {
                return existing
            }

            var board = Board(name: "Main")
            try board.insert(db)
            return board
        }
    }
}
