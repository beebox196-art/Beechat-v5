import Foundation
import GRDB

// MARK: - Generic Upsert Helpers

/// Protocol for records that support upsert with column-specific update behavior.
protocol UpsertableRecord: MutablePersistableRecord & TableRecord & FetchableRecord {
    static var upsertColumns: [Column] { get }
}

extension UpsertableRecord {
    /// Upsert this record, preserving `createdAt` on conflict by only updating
    /// the columns listed in `Self.upsertColumns`.
    mutating func upsertPreservingCreatedAt(_ db: Database) throws {
        try self.upsertAndFetch(
            db,
            onConflict: ["id"],
            updating: .noColumnUnlessSpecified,
            doUpdate: { excluded in
                Self.upsertColumns.map { column in
                    column.set(to: excluded[column])
                }
            }
        )
    }
}

// MARK: - Bulk Upsert Helpers

/// Upsert a batch of records using the shared `upsertPreservingCreatedAt` logic.
/// Deduplicates the for-loop upsert pattern in every repository.
func upsertBatch<T: UpsertableRecord>(
    _ records: [T],
    into db: Database
) throws where T: Sendable {
    for var record in records {
        try record.upsertPreservingCreatedAt(db)
    }
}
