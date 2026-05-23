import Foundation
import GRDB

public class TopicRepository {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
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
            let sessionKey: String? = try String.fetchOne(db, sql:
                "SELECT openclawSessionKey FROM topic_session_bridge WHERE topicId = ?",
                arguments: [id]
            )

            if let key = sessionKey {
                try db.execute(sql: "DELETE FROM attachments WHERE messageId IN (SELECT id FROM messages WHERE sessionId = ?)", arguments: [key])
                try db.execute(sql: "DELETE FROM messages WHERE sessionId = ?", arguments: [key])
                try db.execute(sql: "DELETE FROM delivery_ledger WHERE sessionKey = ?", arguments: [key])
            }

            try db.execute(sql: "DELETE FROM topic_session_bridge WHERE topicId = ?", arguments: [id])
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
            var bridge = TopicSessionBridge(
                topicId: topicId,
                openclawSessionKey: sessionKey
            )
            try bridge.save(db)
        }
    }

    public func resolveSessionKey(topicId: String) throws -> String? {
        try dbManager.reader.read { db in
            if let key = try String.fetchOne(db, sql: "SELECT sessionKey FROM topics WHERE id = ? AND sessionKey IS NOT NULL AND sessionKey != ''", arguments: [topicId]) {
                return key
            }
            return try String.fetchOne(db, sql: "SELECT openclawSessionKey FROM topic_session_bridge WHERE topicId = ?", arguments: [topicId])
        }
    }

    public func resolveTopicId(for sessionKey: String) throws -> String? {
        try dbManager.reader.read { db in
            if let topicId = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [sessionKey]) {
                return topicId
            }
            return try String.fetchOne(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [sessionKey])
        }
    }
    
    /// Resolve the topic ID for a gateway session key using suffix matching.
    public func resolveTopicIdBySuffix(gatewayKey: String, stripped: String) throws -> String? {
        try dbManager.reader.read { db in
            if let topicId = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [gatewayKey]) {
                return topicId
            }
            if let topicId = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [stripped]) {
                return topicId
            }
            if let topicId = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE UPPER(id) = ?", arguments: [stripped.uppercased()]) {
                return topicId
            }
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
    public func listAllBridgeSessionKeys() throws -> [(String, String)] {
        try dbManager.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT openclawSessionKey, topicId FROM topic_session_bridge")
            return rows.map { row in
                (row["openclawSessionKey"] ?? "", row["topicId"] ?? "")
            }
        }
    }

    // MARK: - Phase 2 Prerequisites

    public func fetchAllActiveWithCounts() throws -> [Topic] {
        try dbManager.reader.read { db in
            try Topic
                .filter(Column("isArchived") == false)
                .order(Column("lastActivityAt").desc)
                .fetchAll(db)
        }
    }

    public func fetchPendingSyncTopics() throws -> [Topic] {
        try dbManager.reader.read { db in
            try Topic
                .filter(Column("isArchived") == false)
                .filter(Column("sessionKey") != nil)
                .fetchAll(db)
        }
    }

    public func markSynced(topicId: String) throws {
        try dbManager.write { db in
            try db.execute(
                sql: "UPDATE topics SET updatedAt = ? WHERE id = ?",
                arguments: [Date(), topicId]
            )
        }
    }

    /// Sync metadata from gateway sessions to local topics.
    public func syncMetadataFromSessions(_ sessions: [Session]) throws {
        try dbManager.write { db in
            for session in sessions {
                if let topicId = try String.fetchOne(db,
                    sql: "SELECT id FROM topics WHERE sessionKey = ?",
                    arguments: [session.id]
                ) {
                    var topic = try Topic.fetchOne(db, key: topicId)!
                    if let title = session.title, !title.isEmpty {
                        topic.name = title
                    }
                    if let preview = session.lastMessagePreview {
                        topic.lastMessagePreview = preview
                    }
                    topic.lastActivityAt = session.lastMessageAt ?? session.updatedAt
                    topic.unreadCount = session.unreadCount
                    topic.updatedAt = Date()
                    try topic.update(db)
                }
            }
        }
    }

    public func fetchAllActiveSessionKeys() throws -> Set<String> {
        try dbManager.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT openclawSessionKey FROM topic_session_bridge")
            return Set(rows.compactMap { row in row["openclawSessionKey"] as String? })
        }
    }

    public func fetchById(_ id: String) throws -> Topic? {
        try dbManager.reader.read { db in
            try Topic.fetchOne(db, key: id)
        }
    }

    /// Create a new topic. Generates a UUID-based session key.
    @discardableResult
    public func create(name: String, pendingGatewaySync: Bool = false) throws -> Topic {
        let topicId = UUID().uuidString
        let sessionKey = "agent:main:\(topicId.lowercased())"
        let topic = Topic(
            id: topicId,
            name: name,
            sessionKey: pendingGatewaySync ? nil : sessionKey,
            createdAt: Date(),
            updatedAt: Date()
        )
        try save(topic)
        if let sk = topic.sessionKey {
            try saveBridge(topicId: topic.id, sessionKey: sk)
        }
        return topic
    }

    public func archive(topicId: String) throws {
        try dbManager.write { db in
            try db.execute(
                sql: "UPDATE topics SET isArchived = ?, updatedAt = ? WHERE id = ?",
                arguments: [true, Date(), topicId]
            )
        }
    }

    /// Atomic topic + bridge creation in a single write transaction.
    public func saveAndBridgeInTransaction(_ topic: Topic, sessionKey: String) throws {
        try dbManager.write { db in
            var topic = topic
            topic.sessionKey = sessionKey
            try topic.upsertPreservingCreatedAt(db)
            var bridge = TopicSessionBridge(
                topicId: topic.id,
                openclawSessionKey: sessionKey
            )
            try bridge.insert(db)
        }
    }

    // MARK: - Gateway Upsert (Step 5 — inlined SQL, W4 fix)

    /// Upserts local topics from gateway session data + BeeChatTopicMetadata.
    /// - Matches via 5-step cascade (inlined to avoid nested read-in-write deadlock) — Q W4 fix
    /// - If found: updates name, isArchived, updatedAt
    /// - If not found: creates new topic with metadata.topicId as primary key
    public func upsertTopicsFromGateway(_ entries: [(GatewaySessionInfo, BeeChatTopicMetadata)]) throws {
        try dbManager.write { db in
            for (info, metadata) in entries {
                let strippedKey = SessionKeyNormalizer.stripPrefix(info.key)
                let strippedLower = strippedKey.lowercased()

                // Inlined resolveTopicIdBySuffix (5-step cascade) using the active `db`
                let existingTopicId: String?
                // Step 1: exact match on gateway key
                if let id = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [info.key]) {
                    existingTopicId = id
                }
                // Step 2: exact match on stripped key
                else if let id = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [strippedKey]) {
                    existingTopicId = id
                }
                // Step 3: case-insensitive suffix match on topic UUID
                else if let id = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE UPPER(id) = ?", arguments: [strippedLower.uppercased()]) {
                    existingTopicId = id
                }
                // Step 4: bridge table match on gateway key
                else if let id = try String.fetchOne(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [info.key]) {
                    existingTopicId = id
                }
                // Step 5: bridge table match on stripped key
                else if let id = try String.fetchOne(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [strippedKey]) {
                    existingTopicId = id
                }
                else {
                    existingTopicId = nil
                }

                if let topicId = existingTopicId {
                    var topic = try Topic.fetchOne(db, key: topicId)!
                    if let label = info.label, !label.isEmpty {
                        topic.name = label
                    }
                    topic.isArchived = metadata.isArchived
                    topic.updatedAt = Date()
                    try topic.update(db)
                } else {
                    let metaJSON: String?
                    if let path = metadata.projectPath {
                        if let data = try? JSONSerialization.data(withJSONObject: ["projectPath": path]),
                           let str = String(data: data, encoding: .utf8) {
                            metaJSON = str
                        } else {
                            metaJSON = nil
                        }
                    } else {
                        metaJSON = nil
                    }
                    var topic = Topic(
                        id: metadata.topicId,
                        name: info.label ?? "Conversation",
                        sessionKey: info.key,
                        isArchived: metadata.isArchived,
                        metadataJSON: metaJSON
                    )
                    try topic.insert(db)
                    var bridge = TopicSessionBridge(
                        topicId: topic.id,
                        openclawSessionKey: info.key
                    )
                    try bridge.insert(db)
                }
            }
        }
    }
}
