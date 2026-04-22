import Foundation
import GRDB

public class TopicRepository {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    // MARK: - Topic CRUD

    /// Save a topic — upserts on conflict by id.
    public func save(_ topic: Topic) throws {
        try dbManager.write { db in
            var topic = topic
            try topic.upsertAndFetch(
                db,
                onConflict: ["id"],
                updating: .noColumnUnlessSpecified,
                doUpdate: { excluded in
                    Topic.upsertColumns.map { column in
                        column.set(to: excluded[column])
                    }
                }
            )
        }
    }

    /// Fetch all non-archived topics, ordered by lastActivityAt descending.
    public func fetchAllActive(limit: Int = 100) throws -> [Topic] {
        try dbManager.reader.read { db in
            try Topic
                .filter(Column("isArchived") == false)
                .order(Column("lastActivityAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Fetch a topic by id.
    public func fetchById(_ id: String) throws -> Topic? {
        try dbManager.reader.read { db in
            try Topic.fetchOne(db, key: id)
        }
    }

    /// Delete a topic and all associated data (messages, bridge entries).
    public func deleteCascading(_ id: String) throws {
        try dbManager.write { db in
            // Find the session key for this topic (if any)
            let sessionKey: String? = try String.fetchOne(db, sql:
                "SELECT openclawSessionKey FROM topic_session_bridge WHERE topicId = ?",
                arguments: [id]
            )

            // Delete messages linked via session key
            if let key = sessionKey {
                try db.execute(sql: "DELETE FROM attachments WHERE messageId IN (SELECT id FROM messages WHERE sessionId = ?)", arguments: [key])
                try db.execute(sql: "DELETE FROM messages WHERE sessionId = ?", arguments: [key])
                try db.execute(sql: "DELETE FROM delivery_ledger WHERE sessionKey = ?", arguments: [key])
            }

            // Delete bridge entries
            try db.execute(sql: "DELETE FROM topic_session_bridge WHERE topicId = ?", arguments: [id])

            // Delete the topic itself
            try Topic.deleteOne(db, key: id)
        }
    }

    /// Update the session key for a topic.
    public func updateSessionKey(topicId: String, sessionKey: String) throws {
        try dbManager.write { db in
            try db.execute(sql: "UPDATE topics SET sessionKey = ?, updatedAt = ? WHERE id = ?", arguments: [sessionKey, Date(), topicId])
        }
    }

    /// Update the lastActivityAt timestamp for a topic.
    public func updateActivity(topicId: String, at date: Date = Date()) throws {
        try dbManager.write { db in
            try db.execute(sql: "UPDATE topics SET lastActivityAt = ?, updatedAt = ? WHERE id = ?", arguments: [date, Date(), topicId])
        }
    }

    /// Increment unread count for a topic.
    public func incrementUnread(topicId: String) throws {
        try dbManager.write { db in
            try db.execute(sql: "UPDATE topics SET unreadCount = unreadCount + 1, updatedAt = ? WHERE id = ?", arguments: [Date(), topicId])
        }
    }

    /// Reset unread count for a topic.
    public func resetUnread(topicId: String) throws {
        try dbManager.write { db in
            try db.execute(sql: "UPDATE topics SET unreadCount = 0, updatedAt = ? WHERE id = ?", arguments: [Date(), topicId])
        }
    }

    // MARK: - Bridge CRUD

    /// Save a bridge entry mapping topicId → sessionKey.
    public func saveBridge(topicId: String, sessionKey: String) throws {
        try dbManager.write { db in
            var bridge = TopicSessionBridge(
                topicId: topicId,
                openclawSessionKey: sessionKey
            )
            try bridge.save(db)
        }
    }

    /// Resolve the gateway session key for a topic.
    /// Checks the topics table first (sessionKey column), then falls back to the bridge table.
    public func resolveSessionKey(topicId: String) throws -> String? {
        try dbManager.reader.read { db in
            // Try topics.sessionKey first
            if let key = try String.fetchOne(db, sql: "SELECT sessionKey FROM topics WHERE id = ? AND sessionKey IS NOT NULL AND sessionKey != ''", arguments: [topicId]) {
                return key
            }
            // Fall back to bridge table
            return try String.fetchOne(db, sql: "SELECT openclawSessionKey FROM topic_session_bridge WHERE topicId = ?", arguments: [topicId])
        }
    }

    /// Resolve the topic ID for a gateway session key.
    public func resolveTopicId(for sessionKey: String) throws -> String? {
        try dbManager.reader.read { db in
            // Try topics table first
            if let topicId = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [sessionKey]) {
                return topicId
            }
            // Fall back to bridge table
            return try String.fetchOne(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [sessionKey])
        }
    }
    
    /// Resolve the topic ID for a gateway session key using suffix matching.
    /// Strips the "agent:main:" prefix from the gateway key, then does a
    /// case-insensitive comparison against all topic IDs.
    /// This handles the case where the bridge table hasn't been updated yet
    /// with the gateway-format key.
    public func resolveTopicIdBySuffix(gatewayKey: String, stripped: String) throws -> String? {
        try dbManager.reader.read { db in
            // Try exact match on the gateway key first (in case it's stored directly)
            if let topicId = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [gatewayKey]) {
                return topicId
            }
            // Try exact match on the stripped key
            if let topicId = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [stripped]) {
                return topicId
            }
            // Case-insensitive suffix match: find topic whose ID matches the stripped key
            if let topicId = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE UPPER(id) = ?", arguments: [stripped.uppercased()]) {
                return topicId
            }
            // Fall back to bridge table with both keys
            if let topicId = try String.fetchOne(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [gatewayKey]) {
                return topicId
            }
            if let topicId = try String.fetchOne(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [stripped]) {
                return topicId
            }
            return nil
        }
    }
    
    /// List all bridge entries as (sessionKey, topicId) pairs.
    /// Used to build the BeeChat session filter.
    public func listAllBridgeSessionKeys() throws -> [(String, String)] {
        try dbManager.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT openclawSessionKey, topicId FROM topic_session_bridge")
            return rows.map { row in
                (row["openclawSessionKey"] ?? "", row["topicId"] ?? "")
            }
        }
    }
}