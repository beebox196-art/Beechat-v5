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
            return try query.order(Column("timestamp").desc)
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
}