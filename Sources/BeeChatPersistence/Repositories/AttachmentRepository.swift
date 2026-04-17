import Foundation
import GRDB

public class AttachmentRepository {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager = .shared) {
        self.dbManager = dbManager
    }
    
    /// Upsert an attachment — preserves createdAt on conflict.
    public func save(_ attachment: Attachment) throws {
        try dbManager.write { db in
            var attachment = attachment
            try attachment.upsertAndFetch(
                db,
                onConflict: ["id"],
                updating: .noColumnUnlessSpecified,
                doUpdate: { excluded in
                    Attachment.upsertColumns.map { column in
                        column.set(to: excluded[column])
                    }
                }
            )
        }
    }
    
    public func fetchByMessage(messageId: String) throws -> [Attachment] {
        try dbManager.reader.read { db in
            try Attachment.filter(Column("messageId") == messageId).fetchAll(db)
        }
    }
}