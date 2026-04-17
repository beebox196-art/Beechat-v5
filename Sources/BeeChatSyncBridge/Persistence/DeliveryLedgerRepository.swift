import Foundation
import GRDB
import BeeChatPersistence

public struct DeliveryLedgerRepository {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }
    
    public func save(_ entry: DeliveryLedgerEntry) throws {
        try dbManager.write { db in
            try db.execute(
                sql: "INSERT INTO delivery_ledger (id, sessionKey, idempotencyKey, content, status, runId, createdAt, updatedAt, retryCount) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [entry.id.uuidString, entry.sessionKey, entry.idempotencyKey, entry.content, entry.status.rawValue, entry.runId, entry.createdAt, entry.updatedAt, entry.retryCount]
            )
        }
    }
    
    public func updateStatus(idempotencyKey: String, status: DeliveryLedgerEntry.DeliveryStatus, runId: String? = nil) throws {
        try dbManager.write { db in
            try db.execute(
                sql: "UPDATE delivery_ledger SET status = ?, runId = ?, updatedAt = ? WHERE idempotencyKey = ?",
                arguments: [status.rawValue, runId, Date(), idempotencyKey]
            )
        }
    }
    
    public func fetchPending() throws -> [DeliveryLedgerEntry] {
        try dbManager.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM delivery_ledger WHERE status = 'pending'")
            return rows.map { row in
                let createdAtStr = row["createdAt"] as! String
                let updatedAtStr = row["updatedAt"] as! String
                
                let formatter = ISO8601DateFormatter()
                let createdAt = formatter.date(from: createdAtStr) ?? Date()
                let updatedAt = formatter.date(from: updatedAtStr) ?? Date()
                
                return DeliveryLedgerEntry(
                    id: UUID(uuidString: row["id"] as! String)!,
                    sessionKey: row["sessionKey"] as! String,
                    idempotencyKey: row["idempotencyKey"] as! String,
                    content: row["content"] as! String,
                    status: DeliveryLedgerEntry.DeliveryStatus(rawValue: row["status"] as! String)!,
                    runId: row["runId"] as? String,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    retryCount: Int(row["retryCount"] as! Int64)
                )
            }
        }
    }
    
    public func fetchByIdempotencyKey(_ key: String) throws -> DeliveryLedgerEntry? {
        try dbManager.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM delivery_ledger WHERE idempotencyKey = ?", arguments: [key]) else { return nil }
            
            let createdAtStr = row["createdAt"] as! String
            let updatedAtStr = row["updatedAt"] as! String
            let formatter = ISO8601DateFormatter()
            let createdAt = formatter.date(from: createdAtStr) ?? Date()
            let updatedAt = formatter.date(from: updatedAtStr) ?? Date()
            
            return DeliveryLedgerEntry(
                id: UUID(uuidString: row["id"] as! String)!,
                sessionKey: row["sessionKey"] as! String,
                idempotencyKey: row["idempotencyKey"] as! String,
                content: row["content"] as! String,
                status: DeliveryLedgerEntry.DeliveryStatus(rawValue: row["status"] as! String)!,
                runId: row["runId"] as? String,
                createdAt: createdAt,
                updatedAt: updatedAt,
                retryCount: Int(row["retryCount"] as! Int64)
            )
        }
    }
}
