import Foundation
import GRDB

public class SessionRepository {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }
    
    public func save(_ session: Session) throws {
        try dbManager.write { db in
            var session = session
            try session.upsertPreservingCreatedAt(db)
        }
    }

    public func upsert(_ sessions: [Session]) throws {
        try dbManager.write { db in
            try upsertBatch(sessions, into: db)
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
    /// Post-Migration006, messages always use sessionId. Topic cleanup is handled
    /// by TopicRepository.deleteCascading for the Topic-first flow.
    public func deleteCascading(_ id: String) throws {
        try dbManager.write { db in
            // Delete attachments for this session's messages
            if try db.tableExists("attachments") {
                try db.execute(sql: """
                    DELETE FROM attachments WHERE messageId IN (
                        SELECT id FROM messages WHERE sessionId = ?
                    )
                    """, arguments: [id])
            }
            // Delete messages linked via sessionId (always present after Migration006)
            try db.execute(sql: "DELETE FROM messages WHERE sessionId = ?", arguments: [id])

            // Clean up bridge entries for this session
            if try db.tableExists("topic_session_bridge") {
                try db.execute(sql: "DELETE FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [id])
            }

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