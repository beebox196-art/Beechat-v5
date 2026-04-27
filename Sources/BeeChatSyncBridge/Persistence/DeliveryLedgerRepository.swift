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
                sql: "INSERT INTO delivery_ledger (id, sessionKey, idempotencyKey, content, originalContent, status, runId, createdAt, updatedAt, retryCount) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [entry.id.uuidString, entry.sessionKey, entry.idempotencyKey, entry.content, entry.originalContent, entry.status.rawValue, entry.runId, entry.createdAt, entry.updatedAt, entry.retryCount]
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
    
    static func extractDate(_ row: Row, column: String) throws -> Date {
        if let dateVal: Date = row[column] {
            return dateVal
        }
        if let strVal: String = row[column],
           let parsed = ISO8601DateFormatter().date(from: strVal) {
            return parsed
        }
        throw DeliveryLedgerError.malformedRow("invalid or missing \(column)")
    }
    
    public func fetchPending() throws -> [DeliveryLedgerEntry] {
        try dbManager.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM delivery_ledger WHERE status = 'pending'")
            return try rows.map { try DeliveryLedgerEntry(from: $0) }
        }
    }
    
    public func fetchByIdempotencyKey(_ key: String) throws -> DeliveryLedgerEntry? {
        try dbManager.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM delivery_ledger WHERE idempotencyKey = ?", arguments: [key]) else { return nil }
            return try DeliveryLedgerEntry(from: row)
        }
    }
}

// MARK: - Row Parsing

extension DeliveryLedgerEntry {
    /// Initialise from a GRDB Row (used by DeliveryLedgerRepository).
    /// Centralises the ~30 lines of duplicated parsing logic.
    init(from row: Row) throws {
        let createdAt = try DeliveryLedgerRepository.extractDate(row, column: "createdAt")
        let updatedAt = try DeliveryLedgerRepository.extractDate(row, column: "updatedAt")
        
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
              let status = DeliveryStatus(rawValue: statusRaw) else {
            throw DeliveryLedgerError.malformedRow("invalid status")
        }
        
        self.id = id
        self.sessionKey = sessionKey
        self.idempotencyKey = idempotencyKey
        self.content = content
        self.originalContent = row["originalContent"] as? String
        self.status = status
        self.runId = row["runId"] as? String
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.retryCount = Int(row["retryCount"] as? Int64 ?? 0)
    }
}
