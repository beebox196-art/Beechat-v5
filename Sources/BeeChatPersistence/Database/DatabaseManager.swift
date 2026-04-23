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

        try migrator.migrate(dbPool!)
    }
}