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

    public func openDatabase(at path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=OFF")
        }
        
        self.dbPool = try DatabasePool(path: path, configuration: config)
        
        try migrate()
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
            // NOTE: Migration015 drops this table. The table was never populated in production
            // because topics.sessionKey already stores the canonical gateway key directly, and
            // topic_session_bridge maintains the same mapping. The table is dead schema that
            // would mislead future developers.

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

            // _migration_metadata table — kept for future migrations that need to
            // persist state across app launches. The session_key_alignment_pending
            // flag has been removed (Migration015).
            if try !db.tableExists("_migration_metadata") {
                try db.create(table: "_migration_metadata") { t in
                    t.column("key", .text).primaryKey()
                    t.column("value", .text).notNull()
                }
            }
        }

        migrator.registerMigration("Migration011_AddMessageAgentId") { db in
            guard try db.tableExists("messages") else { return }

            let columns = try db.columns(in: "messages").map { $0.name }
            if !columns.contains("agentId") {
                try db.alter(table: "messages") { t in
                    t.add(column: "agentId", .text)
                }
            }
        }

        migrator.registerMigration("Migration012_AddPendingGatewaySync") { db in
            // 1. Add pendingGatewaySync column to topics table
            guard try db.tableExists("topics") else { return }
            
            let columns = try db.columns(in: "topics").map { $0.name }
            if !columns.contains("pendingGatewaySync") {
                try db.alter(table: "topics") { t in
                    t.add(column: "pendingGatewaySync", .boolean).defaults(to: false)
                }
            }
            
            // 2. Add UNIQUE index on openclawSessionKey in bridge table
            if try db.tableExists("topic_session_bridge") {
                try db.execute(sql: "DROP INDEX IF EXISTS idx_bridge_session_key")
                try db.execute(sql: """
                    CREATE UNIQUE INDEX IF NOT EXISTS idx_bridge_session_key
                    ON topic_session_bridge(openclawSessionKey)
                """)
            }
        }

        migrator.registerMigration("Migration013_AddTopicOrigin") { db in
            guard try db.tableExists("topics") else { return }

            let columns = try db.columns(in: "topics").map { $0.name }
            if !columns.contains("origin") {
                try db.alter(table: "topics") { t in
                    t.add(column: "origin", .text)
                }
            }
        }

        migrator.registerMigration("Migration014_SeedClaudeOversightBookmark") { db in
            guard try db.tableExists("bookmarks") else { return }

            try db.execute(sql: """
                INSERT OR IGNORE INTO bookmarks
                    (id, name, path, iconName, sortOrder, createdAt)
                VALUES
                    (?, ?, ?, ?, ?, ?)
            """, arguments: [
                UUID().uuidString,
                "Claude Oversight Reports",
                "/Users/openclaw/Desktop/Claude Oversight Reports",
                "folder.badge.checkmark",
                4,
                Date()
            ])
        }

        // Migration015: Drop the session_key_mapping table.
        //
        // This table was created by Migration010 to bridge local UUID topic IDs
        // and gateway session keys. Production code never populated it (Q's
        // review found that topics.sessionKey already stores the canonical
        // gateway key directly, and topic_session_bridge maintains the same
        // mapping). Removing it eliminates dead schema that would mislead
        // future developers.
        migrator.registerMigration("Migration015_DropSessionKeyMapping") { db in
            if try db.tableExists("session_key_mapping") {
                try db.drop(table: "session_key_mapping")
            }
            // Also clear the legacy metadata flag from Migration010. The flag was
            // written by Migration010 to track that the data migration phase still
            // needed to run; since runSessionKeyAlignmentMigration is removed,
            // the flag is meaningless.
            try db.execute(
                sql: "DELETE FROM _migration_metadata WHERE key = ?",
                arguments: ["session_key_alignment_pending"]
            )
        }

        try migrator.migrate(dbPool!)
    }
}