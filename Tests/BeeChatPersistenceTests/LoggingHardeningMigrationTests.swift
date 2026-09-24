import Foundation
import GRDB
import XCTest
@testable import BeeChatPersistence

final class LoggingHardeningMigrationTests: XCTestCase {
    private let seededPath = "/Users/openclaw/Desktop/Claude Oversight Reports"

    func testMigration016DeletesPristineSeed() throws {
        let fixture = try makeDatabaseThroughMigration013()
        defer { fixture.cleanup() }
        try insertSeed(in: fixture.queue)

        try DatabaseManager().makeMigrator().migrate(fixture.queue)

        XCTAssertEqual(try bookmarkCount(in: fixture.queue), 0)
    }

    func testMigration016RetainsModifiedRows() throws {
        for mutation in ModifiedSeed.allCases {
            let fixture = try makeDatabaseThroughMigration013()
            defer { fixture.cleanup() }
            try insertSeed(in: fixture.queue, mutation: mutation)

            try DatabaseManager().makeMigrator().migrate(fixture.queue)

            XCTAssertEqual(try bookmarkCount(in: fixture.queue), 1, "lost user data after \(mutation)")
        }
    }

    func testFreshDatabaseHasNoSeedAndBookmarkReaderAcceptsEmptyResult() throws {
        let fixture = temporaryDatabasePath(label: "fresh")
        defer { try? FileManager.default.removeItem(atPath: fixture) }
        let manager = DatabaseManager()
        try manager.openDatabase(at: fixture)
        defer { manager.closeDatabase() }

        XCTAssertEqual(try manager.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bookmarks") }, 0)
        // FolderPicker's actual reader is BookmarkRepository.fetchAll(); an empty
        // result is a normal array, with no force unwrap or sortOrder==4 assumption.
        XCTAssertTrue(try BookmarkRepository(dbManager: manager).fetchAll().isEmpty)
    }

    func testMigration016AgainstRealDatabaseCopyWhenProvided() throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["BEECHAT_REAL_DB_PATH"] else {
            throw XCTSkip("Set BEECHAT_REAL_DB_PATH to verify a non-mutating backup of Adam's database")
        }
        let destinationPath = temporaryDatabasePath(label: "real-copy")
        defer { try? FileManager.default.removeItem(atPath: destinationPath) }
        let source = try DatabaseQueue(path: sourcePath)
        let destination = try DatabaseQueue(path: destinationPath)
        try source.backup(to: destination)
        let pristineBefore = try pristineSeedCount(in: destination)

        let manager = DatabaseManager()
        try manager.openDatabase(at: destinationPath)
        defer { manager.closeDatabase() }

        let pristineAfter = try manager.read { db in
            try Int.fetchOne(db, sql: Self.pristineSeedCountSQL) ?? -1
        }
        XCTAssertEqual(pristineAfter, 0)
        if pristineBefore == 0 {
            XCTAssertGreaterThanOrEqual(try BookmarkRepository(dbManager: manager).fetchAll().count, 0)
        }
    }

    private func makeDatabaseThroughMigration013() throws -> DatabaseFixture {
        let path = temporaryDatabasePath(label: "migration013")
        let queue = try DatabaseQueue(path: path)
        try DatabaseManager().makeMigrator().migrate(queue, upTo: "Migration013_AddTopicOrigin")
        return DatabaseFixture(path: path, queue: queue)
    }

    private func insertSeed(in queue: DatabaseQueue, mutation: ModifiedSeed? = nil) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO bookmarks
                        (id, name, path, securityBookmark, iconName, sortOrder, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    mutation == .renamed ? "My Reports" : "Claude Oversight Reports",
                    seededPath,
                    mutation == .bookmarked ? Data([0x01, 0x02]) : nil,
                    mutation == .reiconed ? "folder.fill" : "folder.badge.checkmark",
                    4,
                    Date(),
                ]
            )
        }
    }

    private func bookmarkCount(in queue: DatabaseQueue) throws -> Int {
        try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM bookmarks") ?? -1 }
    }

    private func pristineSeedCount(in queue: DatabaseQueue) throws -> Int {
        try queue.read { db in
            guard try db.tableExists("bookmarks") else { return 0 }
            return try Int.fetchOne(db, sql: Self.pristineSeedCountSQL) ?? -1
        }
    }

    private static let pristineSeedCountSQL = """
        SELECT COUNT(*) FROM bookmarks
        WHERE path = '/Users/openclaw/Desktop/Claude Oversight Reports'
          AND name = 'Claude Oversight Reports'
          AND iconName = 'folder.badge.checkmark'
          AND securityBookmark IS NULL
        """

    private func temporaryDatabasePath(label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("beechat-\(label)-\(UUID().uuidString).sqlite")
            .path
    }
}

private enum ModifiedSeed: CaseIterable {
    case renamed
    case reiconed
    case bookmarked
}

private struct DatabaseFixture {
    let path: String
    let queue: DatabaseQueue
    func cleanup() { try? FileManager.default.removeItem(atPath: path) }
}
