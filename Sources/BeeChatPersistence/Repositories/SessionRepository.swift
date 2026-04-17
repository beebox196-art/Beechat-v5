import Foundation
import GRDB

public class SessionRepository {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }
    
    /// Upsert a session — preserves createdAt on conflict.
    public func save(_ session: Session) throws {
        try dbManager.write { db in
            var session = session
            try session.upsertAndFetch(
                db,
                onConflict: ["id"],
                updating: .noColumnUnlessSpecified,
                doUpdate: { excluded in
                    Session.upsertColumns.map { column in
                        column.set(to: excluded[column])
                    }
                }
            )
        }
    }
    
    /// Bulk upsert sessions — preserves createdAt on conflict.
    public func upsert(_ sessions: [Session]) throws {
        try dbManager.write { db in
            for session in sessions {
                var session = session
                try session.upsertAndFetch(
                    db,
                    onConflict: ["id"],
                    updating: .noColumnUnlessSpecified,
                    doUpdate: { excluded in
                        Session.upsertColumns.map { column in
                            column.set(to: excluded[column])
                        }
                    }
                )
            }
        }
    }
    
    public func fetchAll(limit: Int, offset: Int) throws -> [Session] {
        try dbManager.reader.read { db in
            try Session.limit(limit, offset: offset)
                .order(Column("lastMessageAt").desc)
                .fetchAll(db)
        }
    }
    
    public func fetchById(_ id: String) throws -> Session? {
        try dbManager.reader.read { db in
            try Session.fetchOne(db, key: id)
        }
    }
    
    public func delete(_ id: String) throws {
        try dbManager.write { db in
            try Session.deleteOne(db, key: id)
        }
    }
    
    /// Delete a session and all its messages and attachments (cascade).
    public func deleteCascading(_ id: String) throws {
        try dbManager.write { db in
            // Delete attachments for messages in this session
            try db.execute(sql: """
                DELETE FROM attachments WHERE messageId IN (
                    SELECT id FROM messages WHERE sessionId = ?
                )
                """, arguments: [id])
            // Delete messages in this session
            try db.execute(sql: "DELETE FROM messages WHERE sessionId = ?", arguments: [id])
            // Delete the session itself
            try Session.deleteOne(db, key: id)
        }
    }
    
    public func updateUnreadCount(id: String, count: Int) throws {
        try dbManager.write { db in
            try db.execute(sql: "UPDATE sessions SET unreadCount = ? WHERE id = ?", arguments: [count, id])
        }
    }
}