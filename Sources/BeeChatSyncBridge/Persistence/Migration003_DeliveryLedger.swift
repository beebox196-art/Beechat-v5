import Foundation
import GRDB

public struct Migration003_DeliveryLedger {
    public static func apply(db: Database) throws {
        if try db.tableExists("delivery_ledger") { return }
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
