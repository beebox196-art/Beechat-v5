import Foundation
import GRDB

public class MessageRepository {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }
    
    public func save(_ message: Message) throws {
        try dbManager.write { db in
            var message = message
            try message.upsertPreservingCreatedAt(db)
        }
    }
    
    public func upsert(_ messages: [Message]) throws {
        try dbManager.write { db in
            try upsertBatch(messages, into: db)
        }
    }
    
    public func fetchBySession(sessionId: String, limit: Int, before: Date?) throws -> [Message] {
        try dbManager.reader.read { db in
            var query = Message.filter(Column("sessionId") == sessionId)
            if let before = before {
                query = query.filter(Column("timestamp") < before)
            }
            return try query.order(Column("timestamp").asc)
                             .limit(limit)
                             .fetchAll(db)
        }
    }
    
    public func fetchById(_ id: String) throws -> Message? {
        try dbManager.reader.read { db in
            try Message.fetchOne(db, key: id)
        }
    }
    
    public func delete(_ id: String) throws {
        try dbManager.write { db in
            try Message.deleteOne(db, key: id)
        }
    }
    
    public func markAsRead(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try dbManager.write { db in
            try db.execute(sql: "UPDATE messages SET isRead = 1 WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(ids))
        }
    }

    /// Deduplicate local user messages that have a gateway counterpart.
    /// Removes the local-UUID copy when a gateway message with matching content
    /// and close timestamp exists for the same session.
    ///
    /// Guards: user-role only, ≥20 chars content, 10s window, 1:1 matching.
    /// Single SQL DELETE — no Swift memory loading.
    ///
    /// Note: LIMIT 1 is intentional as a safety net — only one local message
    /// is deleted per call, even if multiple matches exist. This prevents
    /// accidental bulk deletion from false-positive matches.
    ///
    /// Note: Both `?` positional parameters bind to `sessionKey` — the first
    /// for the outer DELETE WHERE clause, the second for the subquery WHERE.
    /// If refactoring the SQL, ensure parameter order stays consistent.
    public func dedupLocalMessages(sessionKey: String) throws {
        try dbManager.write { db in
            try db.execute(sql: """
                DELETE FROM messages
                WHERE role = 'user'
                  AND sessionId = ?          -- outer param 1: sessionKey
                  AND LENGTH(TRIM(COALESCE(content, ''))) >= 20
                  AND id IN (
                    SELECT local.id FROM messages local
                    INNER JOIN messages gateway ON local.sessionId = gateway.sessionId
                      AND gateway.role = 'user'
                      AND TRIM(COALESCE(local.content, '')) = TRIM(COALESCE(gateway.content, ''))
                      AND ABS(local.timestamp - gateway.timestamp) < 10.0
                      AND local.id != gateway.id   -- prevent self-match
                    WHERE local.sessionId = ?    -- inner param 2: sessionKey
                      AND local.role = 'user'
                    LIMIT 1   -- safety net: delete at most one local message per call
                  )
                """, arguments: [sessionKey, sessionKey])
        }
    }
}