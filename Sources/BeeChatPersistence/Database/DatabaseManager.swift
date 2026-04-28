import Foundation
import GRDB

public enum DatabaseManagerError: Error, LocalizedError {
    case notOpen
    
    public var errorDescription: String? {
        switch self {
        case .notOpen: return "Database is not open. Call openDatabase(at:) first."
        }
    }
}

public class DatabaseManager {
    public static let shared = DatabaseManager()
    private var dbPool: DatabasePool?
    
    public init() {}
    
    /// Whether the session key alignment data migration still needs to run.
    /// Set to true by Migration010 schema changes; cleared once data migration completes.
    public var sessionKeyAlignmentPending = false

    /// Run the data migration phase of Session Key Alignment.
    /// Called after SyncBridge.start() populates sessionKeyMap from the gateway.
    /// If the gateway is unreachable, this should NOT be called — the app runs
    /// in compatibility mode until the gateway is available.
    ///
    /// - Parameter topicToGatewayKey: Inverted sessionKeyMap (local UUID → gateway key).
    ///   Built by inverting SyncBridge.sessionKeyMap after fetchSessions() succeeds.
    public func runSessionKeyAlignmentMigration(topicToGatewayKey: [String: String]) throws {
        guard sessionKeyAlignmentPending else {
            // Already migrated or not needed
            return
        }

        try write { db in
            // Step 1: Persist the gateway key mapping to session_key_mapping table
            // (Table created by Migration010 schema phase)
            if try db.tableExists("session_key_mapping") {
                for (localId, gatewayKey) in topicToGatewayKey {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO session_key_mapping (localId, gatewayKey) VALUES (?, ?)",
                        arguments: [localId, gatewayKey]
                    )
                }
            }

            // Step 3: Populate new columns from topics data
            // For each known mapping, find the topic and copy metadata to the session
            let allTopics = try Topic.fetchAll(db)
            let topicById = Dictionary(uniqueKeysWithValues: allTopics.map { ($0.id, $0) })

            for (localId, gatewayKey) in topicToGatewayKey {
                // Only update sessions that exist in the sessions table
                let sessionExists = try Bool.fetchOne(db, sql: "SELECT 1 FROM sessions WHERE id = ?", arguments: [gatewayKey]) ?? false
                guard sessionExists else { continue }

                if let topic = topicById[localId] {
                    // Only set customName if it differs from the gateway title
                    let customName: String? = topic.name != (try String.fetchOne(db, sql: "SELECT title FROM sessions WHERE id = ?", arguments: [gatewayKey])) ? topic.name : nil

                    try db.execute(
                        sql: """
                        UPDATE sessions SET
                            customName = ?,
                            lastMessagePreview = ?,
                            messageCount = ?,
                            isArchived = ?,
                            unreadCount = ?
                        WHERE id = ?
                        """,
                        arguments: [
                            customName,
                            topic.lastMessagePreview,
                            topic.messageCount,
                            topic.isArchived,
                            topic.unreadCount,
                            gatewayKey
                        ]
                    )
                }
            }

            // Step 4: Rewrite messages.sessionId and delivery_ledger.sessionKey
            // from local UUIDs to gateway keys
            for (localId, gatewayKey) in topicToGatewayKey {
                try db.execute(
                    sql: "UPDATE messages SET sessionId = ? WHERE sessionId = ?",
                    arguments: [gatewayKey, localId]
                )
                try db.execute(
                    sql: "UPDATE delivery_ledger SET sessionKey = ? WHERE sessionKey = ?",
                    arguments: [gatewayKey, localId]
                )
            }

            // Handle orphaned messages: sessionId not in mapping and not already a gateway key
            if try db.tableExists("messages") {
                let unmappedSessionIds = try String.fetchAll(db, sql: """
                    SELECT DISTINCT sessionId FROM messages
                    WHERE sessionId NOT IN (SELECT localId FROM session_key_mapping)
                    AND sessionId NOT IN (SELECT id FROM sessions)
                    """)

                for orphanId in unmappedSessionIds {
                    let syntheticKey = "orphan:\(orphanId)"
                    let topicName = topicById[orphanId]?.name ?? "Orphaned messages"

                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO sessions
                            (id, agentId, title, customName, isArchived, createdAt, updatedAt)
                        VALUES (?, 'main', ?, ?, 1, datetime('now'), datetime('now'))
                        """,
                        arguments: [syntheticKey, topicName, topicName]
                    )
                    try db.execute(
                        sql: "UPDATE messages SET sessionId = ? WHERE sessionId = ?",
                        arguments: [syntheticKey, orphanId]
                    )
                    try db.execute(
                        sql: "UPDATE delivery_ledger SET sessionKey = ? WHERE sessionKey = ?",
                        arguments: [syntheticKey, orphanId]
                    )
                }
            }

            // Backfill sessions.messageCount from actual message counts
            // (ensures accuracy even if topic data was stale)
            try db.execute(sql: """
                UPDATE sessions SET messageCount = COALESCE((
                    SELECT COUNT(*) FROM messages WHERE messages.sessionId = sessions.id
                ), 0)
                WHERE sessions.messageCount = 0
                """)
        }

        sessionKeyAlignmentPending = false

        // Persist the completion flag so it survives app restarts
        try? write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO _migration_metadata (key, value) VALUES (?, ?)",
                arguments: ["session_key_alignment_pending", "0"]
            )
        }
    }

    public func openDatabase(at path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=OFF")
        }
        
        self.dbPool = try DatabasePool(path: path, configuration: config)
        
        try migrate()

        // Check if session key alignment data migration is pending
        if let pool = dbPool {
            let pending = try? pool.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM _migration_metadata WHERE key = ?", arguments: ["session_key_alignment_pending"])
            }
            sessionKeyAlignmentPending = (pending == "1")
        }
    }
    
    public func closeDatabase() {
        dbPool = nil
    }
    
    public var reader: DatabaseReader {
        get throws {
            guard let pool = dbPool else {
                throw DatabaseManagerError.notOpen
            }
            return pool
        }
    }
    
    public var writer: DatabaseWriter {
        get throws {
            guard let pool = dbPool else {
                throw DatabaseManagerError.notOpen
            }
            return pool
        }
    }
    
    public func write<T>(_ updates: (Database) throws -> T) throws -> T {
        guard let pool = dbPool else {
            throw DatabaseManagerError.notOpen
        }
        return try pool.write(updates)
    }
    
    public func read<T>(_ updates: (Database) throws -> T) throws -> T {
        guard let pool = dbPool else {
            throw DatabaseManagerError.notOpen
        }
        return try pool.read(updates)
    }
    
    private func migrate() throws {
        var migrator = DatabaseMigrator()
        
        migrator.registerMigration("Migration001_CreateSessions") { db in
            if try !db.tableExists("sessions") {
                try db.create(table: "sessions") { t in
                    t.column("id", .text).primaryKey()
                    t.column("agentId", .text).notNull()
                    t.column("channel", .text)
                    t.column("title", .text)
                    t.column("lastMessageAt", .datetime)
                    t.column("unreadCount", .integer).defaults(to: 0)
                    t.column("isPinned", .boolean).defaults(to: false)
                    t.column("updatedAt", .datetime).notNull()
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                }
                try db.create(index: "idx_sessions_updated", on: "sessions", columns: ["updatedAt"])
            }
        }
        
        migrator.registerMigration("Migration002_CreateMessages") { db in
            if try !db.tableExists("messages") {
                try db.create(table: "messages") { t in
                    t.column("id", .text).primaryKey()
                    t.column("sessionId", .text).notNull()
                    t.column("role", .text).notNull()
                    t.column("content", .text)
                    t.column("senderName", .text)
                    t.column("senderId", .text)
                    t.column("timestamp", .datetime).notNull()
                    t.column("editedAt", .datetime)
                    t.column("isRead", .boolean).defaults(to: false)
                    t.column("metadata", .text)
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                }
            }
            
            if try !db.tableExists("attachments") {
                try db.create(table: "attachments") { t in
                    t.column("id", .text).primaryKey()
                    t.column("messageId", .text).notNull()
                    t.column("type", .text).notNull()
                    t.column("url", .text)
                    t.column("localPath", .text)
                    t.column("mimeType", .text)
                    t.column("fileName", .text)
                    t.column("fileSize", .integer)
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                }
            }
            
            if try !db.tableExists("idx_messages_session_timestamp") == false,
               try !db.tableExists("messages") {
                try db.create(index: "idx_messages_session_timestamp", on: "messages", columns: ["sessionId", "timestamp"])
                try db.create(index: "idx_messages_session_id", on: "messages", columns: ["sessionId", "id"])
            }
        }
        
        migrator.registerMigration("Migration003_CreateAttachmentsIfMissing") { db in
            if try !db.tableExists("attachments") {
                try db.create(table: "attachments") { t in
                    t.column("id", .text).primaryKey()
                    t.column("messageId", .text).notNull()
                    t.column("type", .text).notNull()
                    t.column("url", .text)
                    t.column("localPath", .text)
                    t.column("mimeType", .text)
                    t.column("fileName", .text)
                    t.column("fileSize", .integer)
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                }
            }
        }
        
        migrator.registerMigration("Migration004_CreateDeliveryLedger") { db in
            if try !db.tableExists("delivery_ledger") {
                try db.create(table: "delivery_ledger") { t in
                    t.column("id", .text).primaryKey()
                    t.column("sessionKey", .text).notNull()
                    t.column("idempotencyKey", .text).notNull().unique()
                    t.column("content", .text).notNull()
                    t.column("status", .text).notNull()
                    t.column("runId", .text)
                    t.column("createdAt", .datetime).notNull()
                    t.column("updatedAt", .datetime).notNull()
                    t.column("retryCount", .integer).notNull().defaults(to: 0)
                }
                
                try db.create(index: "idx_delivery_ledger_status", on: "delivery_ledger", columns: ["status"])
                try db.create(index: "idx_delivery_ledger_session", on: "delivery_ledger", columns: ["sessionKey"])
            }
        }
        
        migrator.registerMigration("Migration005_CreateTopics") { db in
            // Topics table — may already exist from legacy schema
            if try !db.tableExists("topics") {
                try db.create(table: "topics") { t in
                    t.column("id", .text).primaryKey()
                    t.column("name", .text).notNull()
                    t.column("lastMessagePreview", .text)
                    t.column("lastActivityAt", .datetime)
                    t.column("unreadCount", .integer).defaults(to: 0)
                    t.column("sessionKey", .text)
                    t.column("isArchived", .boolean).defaults(to: false)
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                    t.column("updatedAt", .datetime).notNull().defaults(to: Date())
                    t.column("metadataJSON", .text)
                }
                try db.create(index: "idx_topics_lastActivity", on: "topics", columns: ["lastActivityAt"])
                try db.create(index: "idx_topics_isArchived", on: "topics", columns: ["isArchived"])
            } else {
                // Ensure sessionKey column exists (legacy schema may not have it)
                let columns = try db.columns(in: "topics").map { $0.name }
                if !columns.contains("sessionKey") {
                    try db.alter(table: "topics") { t in
                        t.add(column: "sessionKey", .text)
                    }
                }
            }
            
            // Bridge table — may already exist from legacy schema
            if try !db.tableExists("topic_session_bridge") {
                try db.create(table: "topic_session_bridge") { t in
                    t.column("topicId", .text).primaryKey()
                    t.column("spaceId", .text).notNull().defaults(to: "default")
                    t.column("openclawSessionKey", .text).notNull()
                    t.column("bridgeVersion", .integer).defaults(to: 1)
                    t.column("status", .text).defaults(to: "active")
                    t.column("createdAt", .datetime).notNull()
                    t.column("updatedAt", .datetime).notNull()
                    t.column("lastSyncAt", .datetime)
                    t.column("lastError", .text)
                    t.column("retryCount", .integer).defaults(to: 0)
                }
                try db.create(index: "idx_bridge_topicId", on: "topic_session_bridge", columns: ["topicId"])
                try db.create(index: "idx_bridge_sessionKey", on: "topic_session_bridge", columns: ["openclawSessionKey"])
            }
        }
        
        migrator.registerMigration("Migration006_RecreateMessages") { db in
            // Legacy schema had different columns (topicId, senderId NOT NULL,
            // senderName NOT NULL, content NOT NULL, no role/editedAt/metadata/createdAt).
            // Drop and recreate to match the current Message model.
            // Safe because the old schema had no persisted messages at this point.
            try db.drop(table: "messages")
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text).notNull()
                t.column("role", .text).notNull()
                t.column("content", .text)
                t.column("senderName", .text)
                t.column("senderId", .text)
                t.column("timestamp", .datetime).notNull()
                t.column("editedAt", .datetime)
                t.column("isRead", .boolean).defaults(to: false)
                t.column("metadata", .text)
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
            }
            try db.create(index: "idx_messages_session_timestamp", on: "messages", columns: ["sessionId", "timestamp"])
            try db.create(index: "idx_messages_session_id", on: "messages", columns: ["sessionId", "id"])
        }

        migrator.registerMigration("Migration007_AddMessageCount") { db in
            // Add messageCount column to topics
            try db.alter(table: "topics") { t in
                t.add(column: "messageCount", .integer).defaults(to: 0)
            }

            // Backfill existing topics with current message counts
            try db.execute(sql: """
                UPDATE topics SET messageCount = COALESCE((
                    SELECT COUNT(*) FROM messages
                    WHERE messages.sessionId = topics.sessionKey OR messages.sessionId = topics.id
                ), 0)
                """)

            // Auto-increment trigger on message insert (LIMIT 1 prevents double-increment from OR)
            try db.execute(sql: """
                CREATE TRIGGER trg_increment_message_count
                AFTER INSERT ON messages
                BEGIN
                    UPDATE topics SET messageCount = messageCount + 1
                    WHERE topics.id = (
                        SELECT id FROM topics
                        WHERE topics.sessionKey = NEW.sessionId OR topics.id = NEW.sessionId
                        LIMIT 1
                    );
                END
                """)

            // Auto-decrement trigger on message delete (CASE guard prevents negative counts)
            try db.execute(sql: """
                CREATE TRIGGER trg_decrement_message_count
                AFTER DELETE ON messages
                BEGIN
                    UPDATE topics SET messageCount = CASE WHEN messageCount > 0 THEN messageCount - 1 ELSE 0 END
                    WHERE topics.id = (
                        SELECT id FROM topics
                        WHERE topics.sessionKey = OLD.sessionId OR topics.id = OLD.sessionId
                        LIMIT 1
                    );
                END
                """)
        }

        migrator.registerMigration("Migration008_CreateBookmarks") { db in
            if try !db.tableExists("bookmarks") {
                try db.create(table: "bookmarks") { t in
                    t.column("id", .text).primaryKey()
                    t.column("name", .text).notNull()
                    t.column("path", .text).notNull().unique()
                    t.column("securityBookmark", .blob)
                    t.column("iconName", .text).defaults(to: "folder")
                    t.column("sortOrder", .integer).defaults(to: 0)
                    t.column("createdAt", .datetime).notNull().defaults(to: Date())
                }
            }
        }

        migrator.registerMigration("Migration009_AddOriginalContent") { db in
            if try db.tableExists("delivery_ledger") {
                let columns = try db.columns(in: "delivery_ledger").map { $0.name }
                if !columns.contains("originalContent") {
                    try db.alter(table: "delivery_ledger") { t in
                        t.add(column: "originalContent", .text)
                    }
                }
            }
        }

        migrator.registerMigration("Migration010_SessionKeyAlignment_Schema") { db in
            // Step 1: Create session_key_mapping table (populated later by runSessionKeyAlignmentMigration)
            if try !db.tableExists("session_key_mapping") {
                try db.create(table: "session_key_mapping") { t in
                    t.column("localId", .text).primaryKey()
                    t.column("gatewayKey", .text).notNull()
                }
            }

            // Step 2: Add new columns to sessions table
            if try db.tableExists("sessions") {
                let columns = try db.columns(in: "sessions").map { $0.name }
                if !columns.contains("customName") {
                    try db.alter(table: "sessions") { t in
                        t.add(column: "customName", .text)
                    }
                }
                if !columns.contains("lastMessagePreview") {
                    try db.alter(table: "sessions") { t in
                        t.add(column: "lastMessagePreview", .text)
                    }
                }
                if !columns.contains("messageCount") {
                    try db.alter(table: "sessions") { t in
                        t.add(column: "messageCount", .integer).defaults(to: 0)
                    }
                }
                if !columns.contains("totalTokens") {
                    try db.alter(table: "sessions") { t in
                        t.add(column: "totalTokens", .integer)
                    }
                }
                if !columns.contains("isArchived") {
                    try db.alter(table: "sessions") { t in
                        t.add(column: "isArchived", .boolean).defaults(to: false)
                    }
                }
            }

            // Step 5: Replace topic-based message count triggers with session-based triggers
            // Drop old triggers that reference the topics table
            try db.execute(sql: "DROP TRIGGER IF EXISTS trg_increment_message_count")
            try db.execute(sql: "DROP TRIGGER IF EXISTS trg_decrement_message_count")

            // Create new triggers that reference the sessions table
            try db.execute(sql: """
                CREATE TRIGGER trg_session_increment_message_count
                AFTER INSERT ON messages
                BEGIN
                    UPDATE sessions SET messageCount = messageCount + 1 WHERE id = NEW.sessionId;
                END
                """)
            try db.execute(sql: """
                CREATE TRIGGER trg_session_decrement_message_count
                AFTER DELETE ON messages
                BEGIN
                    UPDATE sessions SET messageCount = CASE WHEN messageCount > 0 THEN messageCount - 1 ELSE 0 END WHERE id = OLD.sessionId;
                END
                """)

            // Mark that the data migration phase still needs to run
            // (will be cleared by runSessionKeyAlignmentMigration after boot)
            // We track this in-memory since the flag must survive across app launches
            // until the gateway is reachable. The flag is stored in a simple metadata table.
            if try !db.tableExists("_migration_metadata") {
                try db.create(table: "_migration_metadata") { t in
                    t.column("key", .text).primaryKey()
                    t.column("value", .text).notNull()
                }
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO _migration_metadata (key, value) VALUES (?, ?)",
                arguments: ["session_key_alignment_pending", "1"]
            )
        }

        try migrator.migrate(dbPool!)
    }
}