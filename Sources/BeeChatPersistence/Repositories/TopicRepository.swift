import Foundation
import GRDB

public class TopicRepository {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }

    /// Create a new topic with an upfront gateway-format session key.
    /// The key is generated as "agent:main:<topicId>" (lowercase) to match
    /// gateway conventions. No nil sessionKey window.
    /// Sets origin = "local" to mark this topic as created on the current device.
    public func create(name: String, pendingGatewaySync: Bool = false) throws -> Topic {
        let topicId = UUID().uuidString
        let gatewayKey = "agent:main:\(topicId.lowercased())"

        let topic = Topic(
            id: topicId,
            name: name,
            sessionKey: gatewayKey,
            pendingGatewaySync: pendingGatewaySync,
            origin: "local"
        )

        try save(topic)
        try saveBridge(topicId: topicId, sessionKey: gatewayKey)

        return topic
    }

    /// Fetch active topics with computed message counts via SQL JOIN.
    /// M010 replaced topic-based triggers with session-based triggers,
    /// so Topic.messageCount must be computed from the messages table.
    public func fetchAllActiveWithCounts(limit: Int = 100) throws -> [Topic] {
        try dbManager.reader.read { db in
            try Topic.fetchAll(db, sql: """
                SELECT t.*,
                       COALESCE((
                           SELECT COUNT(*) FROM messages m
                           JOIN topic_session_bridge b ON b.openclawSessionKey = m.sessionId
                           WHERE b.topicId = t.id
                       ), 0) as messageCount
                FROM topics t
                WHERE t.isArchived = 0
                ORDER BY COALESCE(t.lastActivityAt, t.createdAt) DESC
                LIMIT \(limit)
            """)
        }
    }

    /// Fetch all topics with pendingGatewaySync = true.
    public func fetchPendingSyncTopics() throws -> [Topic] {
        try dbManager.reader.read { db in
            try Topic.filter(Column("pendingGatewaySync") == true).fetchAll(db)
        }
    }

    /// Archive a topic by ID.
    public func archive(topicId: String) throws {
        try dbManager.write { db in
            try db.execute(
                sql: "UPDATE topics SET isArchived = 1, updatedAt = ? WHERE id = ?",
                arguments: [Date(), topicId]
            )
        }
    }

    /// Clear the pendingGatewaySync flag after successful reconciliation.
    public func markSynced(topicId: String) throws {
        try dbManager.write { db in
            try db.execute(
                sql: "UPDATE topics SET pendingGatewaySync = 0, updatedAt = ? WHERE id = ?",
                arguments: [Date(), topicId]
            )
        }
    }

    /// Update topic metadata from gateway session data.
    public func syncMetadataFromSessions(_ sessions: [Session]) throws {
        try dbManager.write { db in
            for session in sessions {
                guard let topicId = try String.fetchOne(db, sql:
                    "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?",
                    arguments: [session.id]
                ) else { continue }

                try db.execute(sql: """
                    UPDATE topics SET
                        lastMessagePreview = ?,
                        lastActivityAt = ?,
                        unreadCount = ?,
                        updatedAt = ?
                    WHERE id = ?
                """, arguments: [
                    session.lastMessagePreview,
                    session.lastMessageAt ?? session.updatedAt,
                    session.unreadCount,
                    Date(),
                    topicId
                ])
            }
        }
    }

    public func save(_ topic: Topic) throws {
        try dbManager.write { db in
            var topic = topic
            try topic.upsertPreservingCreatedAt(db)
        }
    }

    public func fetchAllActive(limit: Int = 100) throws -> [Topic] {
        try dbManager.reader.read { db in
            try Topic
                .filter(Column("isArchived") == false)
                .order(Column("lastActivityAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

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

    public func updateSessionKey(topicId: String, sessionKey: String) throws {
        try dbManager.write { db in
            try db.execute(sql: "UPDATE topics SET sessionKey = ?, updatedAt = ? WHERE id = ?", arguments: [sessionKey, Date(), topicId])
        }
    }


    public func saveBridge(topicId: String, sessionKey: String) throws {
        try dbManager.write { db in
            try db.execute(sql: """
                INSERT INTO topic_session_bridge
                    (topicId, spaceId, openclawSessionKey, bridgeVersion, status, createdAt, updatedAt)
                VALUES
                    (?, 'default', ?, 1, 'active', datetime('now'), datetime('now'))
                ON CONFLICT(topicId) DO UPDATE SET
                    openclawSessionKey = excluded.openclawSessionKey,
                    updatedAt = excluded.updatedAt
            """, arguments: [topicId, sessionKey])
        }
    }

    /// Fetch a single topic by ID, regardless of archived status.
    /// Used for undo operations where the topic may be archived.
    public func fetchById(_ id: String) throws -> Topic? {
        try dbManager.reader.read { db in
            // Primary key lookup (exact match)
            if let topic = try Topic.fetchOne(db, key: id) {
                return topic
            }
            // Case-insensitive fallback — UUIDs may differ in case between
            // topic.id (uppercase from UUID().uuidString) and session key suffixes
            // or gateway metadata (lowercase from agent:main:<uuid> format).
            if let topic = try Topic.fetchOne(db,
                sql: "SELECT * FROM topics WHERE id = ? COLLATE NOCASE LIMIT 1",
                arguments: [id]
            ) {
                return topic
            }
            return nil
        }
    }

    /// Fetch all session keys that already have a topic bridge entry,
    /// regardless of bridge status (active, pending, etc.).
    /// Used by the import flow to check which sessions already have topics.
    public func fetchAllActiveSessionKeys() throws -> Set<String> {
        try dbManager.reader.read { db in
            let bridges = try TopicSessionBridge.fetchAll(db)
            return Set(bridges.map { $0.openclawSessionKey })
        }
    }

    /// Atomically save a topic and its bridge entry in a single write transaction.
    /// If bridge creation fails (e.g., UNIQUE constraint on openclawSessionKey),
    /// the entire transaction rolls back — no orphaned topic is left behind.
    public func saveAndBridgeInTransaction(_ topic: Topic, sessionKey: String) throws {
        try dbManager.write { db in
            var topic = topic
            try topic.save(db)  // GRDB upsert (save is mutating on PersistableRecord)
            // Include spaceId and bridgeVersion to match existing saveBridge() pattern
            try db.execute(
                sql: """
                INSERT INTO topic_session_bridge (topicId, spaceId, openclawSessionKey, bridgeVersion, status, createdAt, updatedAt)
                VALUES (?, 'default', ?, 1, 'active', datetime('now'), datetime('now'))
                """,
                arguments: [topic.id, sessionKey]
            )
        }
    }

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

    /// Update the project path in the topic's metadataJSON.
    /// Preserves existing metadata fields and only changes projectPath.
    public func updateProjectPath(topicId: String, path: String?) throws {
        try dbManager.write { db in
            // Fetch existing metadataJSON
            let existingJSON: String? = try String.fetchOne(
                db, sql: "SELECT metadataJSON FROM topics WHERE id = ?", arguments: [topicId]
            )

            var meta = TopicMetadata()
            if let json = existingJSON,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(TopicMetadata.self, from: data) {
                meta = decoded
            }
            meta.projectPath = path

            let newJSON: String? = try? String(data: JSONEncoder().encode(meta), encoding: .utf8)

            try db.execute(
                sql: "UPDATE topics SET metadataJSON = ?, updatedAt = ? WHERE id = ?",
                arguments: [newJSON ?? "", Date(), topicId]
            )
        }
    }
    
    /// Update the Telegram metadata (groupId and threadId) in a topic's metadataJSON.
    /// Preserves existing metadata fields (like projectPath) and only changes telegram fields.
    public func updateTelegramMetadata(topicId: String, groupId: String, threadId: String) throws {
        try dbManager.write { db in
            let existingJSON: String? = try String.fetchOne(
                db, sql: "SELECT metadataJSON FROM topics WHERE id = ?", arguments: [topicId]
            )

            var meta = TopicMetadata()
            if let json = existingJSON,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(TopicMetadata.self, from: data) {
                meta = decoded
            }
            meta.telegramGroupId = groupId
            meta.telegramThreadId = threadId

            let newJSON: String? = try? String(data: JSONEncoder().encode(meta), encoding: .utf8)

            try db.execute(
                sql: "UPDATE topics SET metadataJSON = ?, updatedAt = ? WHERE id = ?",
                arguments: [newJSON ?? "", Date(), topicId]
            )
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
    
    /// Resolve a local topic ID by matching Telegram group ID and thread ID
    /// stored in the topic's metadataJSON.
    /// This is Strategy 4 in session key alignment — for gateway keys like
    /// "agent:main:telegram:group:-1003830552971:topic:1", we look for local topics
    /// whose metadataJSON contains matching telegramGroupId and telegramThreadId.
    public func resolveTopicIdByTelegramThread(groupId: String, threadId: String) throws -> String? {
        try dbManager.reader.read { db in
            // Fetch all topics with metadataJSON and filter in Swift
            let rows = try Row.fetchAll(db, sql: "SELECT id, metadataJSON FROM topics WHERE metadataJSON IS NOT NULL")
            for row in rows {
                let id: String = row["id"]
                let json: String = row["metadataJSON"]
                guard let data = json.data(using: .utf8),
                      let meta = try? JSONDecoder().decode(TopicMetadata.self, from: data),
                      meta.telegramGroupId == groupId,
                      meta.telegramThreadId == threadId else { continue }
                return id
            }
            return nil
        }
    }
    
    /// List all bridge entries as (sessionKey, topicId) pairs.
    public func listAllBridgeSessionKeys() throws -> [(String, String)] {
        try dbManager.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT openclawSessionKey, topicId FROM topic_session_bridge")
            return rows.map { row in
                (row["openclawSessionKey"] ?? "", row["topicId"] ?? "")
            }
        }
    }
}