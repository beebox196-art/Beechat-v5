import Foundation
import GRDB
import BeeChatPersistence

public enum DeliveryLedgerError: LocalizedError {
    case malformedRow(String)
    
    public var errorDescription: String? {
        switch self {
        case .malformedRow(let msg): return "Malformed delivery ledger row: \(msg)"
        }
    }
}

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
    
    /// Safely extract a Date from a GRDB Row, handling both Date and String (ISO8601) storage formats.
    private func extractDate(_ row: Row, column: String) throws -> Date {
        // GRDB stores Date values as Date objects — try that first
        if let dateVal: Date = row[column] {
            return dateVal
        }
        // Fallback: ISO8601 string (for legacy data or manual SQL inserts)
        if let strVal: String = row[column],
           let parsed = ISO8601DateFormatter().date(from: strVal) {
            return parsed
        }
        throw DeliveryLedgerError.malformedRow("invalid or missing \(column)")
    }
    
    public func fetchPending() throws -> [DeliveryLedgerEntry] {
        try dbManager.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM delivery_ledger WHERE status = 'pending'")
            return try rows.map { row in
                let createdAt = try extractDate(row, column: "createdAt")
                let updatedAt = try extractDate(row, column: "updatedAt")
                
                guard let idString: String = row["id"],
                      let id = UUID(uuidString: idString) else {
                    throw DeliveryLedgerError.malformedRow("invalid id")
                }
                guard let sessionKey: String = row["sessionKey"], !sessionKey.isEmpty else {
                    throw DeliveryLedgerError.malformedRow("missing sessionKey")
                }
                guard let idempotencyKey: String = row["idempotencyKey"], !idempotencyKey.isEmpty else {
                    throw DeliveryLedgerError.malformedRow("missing idempotencyKey")
                }
                guard let content: String = row["content"] else {
                    throw DeliveryLedgerError.malformedRow("missing content")
                }
                guard let statusRaw: String = row["status"],
                      let status = DeliveryLedgerEntry.DeliveryStatus(rawValue: statusRaw) else {
                    throw DeliveryLedgerError.malformedRow("invalid status")
                }
                
                return DeliveryLedgerEntry(
                    id: id,
                    sessionKey: sessionKey,
                    idempotencyKey: idempotencyKey,
                    content: content,
                    status: status,
                    runId: row["runId"] as? String,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    retryCount: Int(row["retryCount"] as? Int64 ?? 0)
                )
            }
        }
    }
    
    public func fetchByIdempotencyKey(_ key: String) throws -> DeliveryLedgerEntry? {
        try dbManager.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM delivery_ledger WHERE idempotencyKey = ?", arguments: [key]) else { return nil }
            
            let createdAt = try extractDate(row, column: "createdAt")
            let updatedAt = try extractDate(row, column: "updatedAt")
            
            guard let idString: String = row["id"],
                  let id = UUID(uuidString: idString) else {
                throw DeliveryLedgerError.malformedRow("invalid id")
            }
            guard let sessionKey: String = row["sessionKey"], !sessionKey.isEmpty else {
                throw DeliveryLedgerError.malformedRow("missing sessionKey")
            }
            guard let idempotencyKey: String = row["idempotencyKey"], !idempotencyKey.isEmpty else {
                throw DeliveryLedgerError.malformedRow("missing idempotencyKey")
            }
            guard let content: String = row["content"] else {
                throw DeliveryLedgerError.malformedRow("missing content")
            }
            guard let statusRaw: String = row["status"],
                  let status = DeliveryLedgerEntry.DeliveryStatus(rawValue: statusRaw) else {
                throw DeliveryLedgerError.malformedRow("invalid status")
            }
            
            return DeliveryLedgerEntry(
                id: id,
                sessionKey: sessionKey,
                idempotencyKey: idempotencyKey,
                content: content,
                status: status,
                runId: row["runId"] as? String,
                createdAt: createdAt,
                updatedAt: updatedAt,
                retryCount: Int(row["retryCount"] as? Int64 ?? 0)
            )
        }
    }
}
