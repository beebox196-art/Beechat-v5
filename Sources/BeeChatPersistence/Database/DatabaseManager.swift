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
            // DatabasePool manages WAL mode automatically when we use
            // this hook — it runs before any transactions start.
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
        
        migrator.registerMigration("Migration002_CreateMessages") { db in
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
            
            try db.create(index: "idx_messages_session_timestamp", on: "messages", columns: ["sessionId", "timestamp"])
            try db.create(index: "idx_messages_session_id", on: "messages", columns: ["sessionId", "id"])
        }
        
        try migrator.migrate(dbPool!)
    }
}