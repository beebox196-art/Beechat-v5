import Foundation
import GRDB

public class BookmarkRepository {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    public func save(_ bookmark: Bookmark) throws {
        try dbManager.write { db in
            var bookmark = bookmark
            try bookmark.save(db)
        }
    }

    public func fetchAll() throws -> [Bookmark] {
        try dbManager.reader.read { db in
            try Bookmark
                .order(Column("sortOrder"), Column("createdAt"))
                .fetchAll(db)
        }
    }

    public func fetch(byId id: String) throws -> Bookmark? {
        try dbManager.reader.read { db in
            try Bookmark.fetchOne(db, key: id)
        }
    }

    public func fetch(byPath path: String) throws -> Bookmark? {
        try dbManager.reader.read { db in
            try Bookmark.filter(Column("path") == path).fetchOne(db)
        }
    }

    public func delete(id: String) throws {
        try dbManager.write { db in
            try Bookmark.deleteOne(db, key: id)
        }
    }

    public func exists(path: String) throws -> Bool {
        try dbManager.reader.read { db in
            try Bookmark.filter(Column("path") == path).fetchCount(db) > 0
        }
    }
}