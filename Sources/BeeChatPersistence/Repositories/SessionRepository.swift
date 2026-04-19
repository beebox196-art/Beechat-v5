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
    /// Handles both new schema (messages.sessionId) and legacy schema (messages.topicId).
    public func deleteCascading(_ id: String) throws {
        try dbManager.write { db in
            // Determine which column the messages table uses
            let messagesHasSessionId = try db.columns(in: "messages").contains { $0.name == "sessionId" }
            let messagesHasTopicId = try db.columns(in: "messages").contains { $0.name == "topicId" }

            // Resolve topic IDs for legacy schema cleanup
            var resolvedTopicIds: [String] = []

            if messagesHasSessionId {
                // New schema: messages linked via sessionId
                if try db.tableExists("attachments") {
                    try db.execute(sql: """
                        DELETE FROM attachments WHERE messageId IN (
                            SELECT id FROM messages WHERE sessionId = ?
                        )
                        """, arguments: [id])
                }
                try db.execute(sql: "DELETE FROM messages WHERE sessionId = ?", arguments: [id])
            } else if messagesHasTopicId {
                // Legacy schema: messages linked via topicId
                // The id passed in is a session.id; find corresponding topic(s)
                // via the bridge table, or fall back to matching directly.
                if try db.tableExists("topic_session_bridge") {
                    resolvedTopicIds = try String.fetchAll(db, sql: """
                        SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?
                        UNION
                        SELECT id FROM topics WHERE id = ?
                        """, arguments: [id, id])
                } else if try db.tableExists("topics") {
                    resolvedTopicIds = try String.fetchAll(db, sql: "SELECT id FROM topics WHERE id = ?", arguments: [id])
                } else {
                    resolvedTopicIds = [id]
                }

                for topicId in resolvedTopicIds {
                    try db.execute(sql: "DELETE FROM messages WHERE topicId = ?", arguments: [topicId])
                }
            }

            // Clean up legacy tables if they exist
            if try db.tableExists("topic_session_bridge") {
                if !resolvedTopicIds.isEmpty {
                    let placeholders = resolvedTopicIds.map { _ in "?" }.joined(separator: ",")
                    try db.execute(sql: "DELETE FROM topic_session_bridge WHERE topicId IN (\(placeholders))", arguments: StatementArguments(resolvedTopicIds))
                }
                try db.execute(sql: "DELETE FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [id])
            }
            if try db.tableExists("topics") {
                if !resolvedTopicIds.isEmpty {
                    let placeholders = resolvedTopicIds.map { _ in "?" }.joined(separator: ",")
                    try db.execute(sql: "DELETE FROM topics WHERE id IN (\(placeholders))", arguments: StatementArguments(resolvedTopicIds))
                }
                try db.execute(sql: "DELETE FROM topics WHERE sessionKey = ?", arguments: [id])
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