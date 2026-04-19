import XCTest
import GRDB
@testable import BeeChatPersistence

final class BeeChatPersistenceTests: XCTestCase {
    var store: BeeChatPersistenceStore!
    var dbPath: String!
    
    override func setUpWithError() throws {
        dbPath = "/tmp/beechat_test_\(UUID().uuidString).db"
        store = BeeChatPersistenceStore()
        try store.openDatabase(at: dbPath)
    }
    
    override func tearDownWithError() throws {
        store.closeDatabase()
        try? FileManager.default.removeItem(atPath: dbPath)
    }
    
    func testDatabaseOpenAndWal() throws {
        // Verify database opened successfully and WAL mode is active
        let mode = try DatabaseManager.shared.read { db in
            try String.fetchAll(db, sql: "PRAGMA journal_mode").first
        }
        XCTAssertEqual(mode?.lowercased(), "wal")
        
        // Verify basic DB accessibility through the store
        let sessions = try store.fetchSessions(limit: 1, offset: 0)
        XCTAssertEqual(sessions.count, 0) // Empty but accessible
    }
    
    func testSessionCRUD() throws {
        let session = Session(id: "test_session_1", agentId: "main", title: "Test Session")
        
        try store.saveSession(session)
        let fetched = try store.fetchSession(id: "test_session_1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Test Session")
        
        try store.updateUnreadCount(sessionId: "test_session_1", count: 5)
        let updated = try store.fetchSession(id: "test_session_1")
        XCTAssertEqual(updated?.unreadCount, 5)
        
        try store.deleteSession(id: "test_session_1")
        XCTAssertNil(try store.fetchSession(id: "test_session_1"))
    }
    
    func testMessageCRUD() throws {
        let session = Session(id: "s1", agentId: "a1")
        try store.saveSession(session)
        
        let msg = Message(id: "m1", sessionId: "s1", role: "user", content: "Hello", timestamp: Date())
        try store.saveMessage(msg)
        
        let fetched = try store.fetchMessage(id: "m1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.content, "Hello")
        
        let messages = try store.fetchMessages(sessionId: "s1", limit: 10, before: nil)
        XCTAssertEqual(messages.count, 1)
        
        try store.markAsRead(messageIds: ["m1"])
        XCTAssertTrue(try store.fetchMessage(id: "m1")?.isRead == true)
        
        try store.deleteMessage(id: "m1")
        XCTAssertNil(try store.fetchMessage(id: "m1"))
    }
    
    func testAttachmentCRUD() throws {
        let msg = Message(id: "m1", sessionId: "s1", role: "assistant", timestamp: Date())
        try store.saveMessage(msg)
        
        let attach = Attachment(id: "at1", messageId: "m1", type: "image", url: "http://example.com/img.png")
        try store.saveAttachment(attach)
        
        let attachments = try store.fetchAttachments(messageId: "m1")
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.url, "http://example.com/img.png")
    }
    
    func testUpserts() throws {
        let session1 = Session(id: "s1", agentId: "a1", title: "Title 1")
        let session2 = Session(id: "s2", agentId: "a1", title: "Title 2")
        
        try store.upsertSessions([session1, session2])
        XCTAssertEqual(try store.fetchSessions(limit: 10, offset: 0).count, 2)
        
        // Update session 1
        var updatedS1 = session1
        updatedS1.title = "Updated Title 1"
        try store.upsertSessions([updatedS1])
        
        XCTAssertEqual(try store.fetchSessions(limit: 10, offset: 0).count, 2)
        XCTAssertEqual(try store.fetchSession(id: "s1")?.title, "Updated Title 1")
    }
    
    // MARK: - FAIL-1 fix: createdAt preserved on upsert
    
    func testCreatedAtPreservedOnUpsert() throws {
        // Create a session with a known createdAt
        let originalTime = Date().addingTimeInterval(-3600) // 1 hour ago
        let session = Session(id: "s_createdAt", agentId: "a1", title: "Original", createdAt: originalTime)
        try store.saveSession(session)
        
        // Fetch to confirm createdAt
        let fetched = try store.fetchSession(id: "s_createdAt")
        XCTAssertNotNil(fetched)
        let savedCreatedAt = fetched!.createdAt
        
        // Upsert with a different title — createdAt must NOT change
        var updated = session
        updated.title = "Updated Title"
        try store.saveSession(updated)
        
        let afterUpdate = try store.fetchSession(id: "s_createdAt")
        XCTAssertNotNil(afterUpdate)
        XCTAssertEqual(afterUpdate?.title, "Updated Title")
        // createdAt must be preserved (within 1 second tolerance)
        XCTAssertEqual(afterUpdate!.createdAt.timeIntervalSince1970, savedCreatedAt.timeIntervalSince1970, accuracy: 1.0,
                       "createdAt was overwritten on upsert — FAIL-1 regression")
    }
    
    // MARK: - FAIL-3 fix: cascade delete
    
    // MARK: - Legacy schema cascade delete (messages.topicId instead of sessionId)
    
    func testCascadeDeleteLegacySchema() throws {
        // Simulate the legacy database schema where messages uses topicId, not sessionId
        // and there is no attachments table
        try DatabaseManager.shared.write { db in
            // Drop the migration-created messages table and recreate with legacy schema
            try db.execute(sql: "DROP TABLE IF EXISTS messages")
            try db.execute(sql: "DROP TABLE IF EXISTS attachments")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS "messages" (
                    "id" TEXT PRIMARY KEY,
                    "content" TEXT NOT NULL,
                    "senderId" TEXT NOT NULL,
                    "senderName" TEXT NOT NULL,
                    "topicId" TEXT NOT NULL REFERENCES "topics"("id") ON DELETE CASCADE,
                    "timestamp" DATETIME NOT NULL,
                    "isRead" BOOLEAN NOT NULL DEFAULT 0,
                    "messageId" TEXT,
                    "isFromGateway" BOOLEAN NOT NULL DEFAULT 0,
                    "runId" TEXT,
                    "state" TEXT NOT NULL DEFAULT 'final'
                )
                """)
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_messages_topicId_timestamp ON messages(topicId, timestamp)")
            
            // Create topics table (legacy)
            try db.execute(sql: "DROP TABLE IF EXISTS topics")
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS "topics" (
                    "id" TEXT PRIMARY KEY,
                    "name" TEXT NOT NULL,
                    "lastMessagePreview" TEXT,
                    "lastActivityAt" DATETIME,
                    "unreadCount" INTEGER NOT NULL DEFAULT 0,
                    "sessionKey" TEXT,
                    "isArchived" BOOLEAN NOT NULL DEFAULT 0,
                    "createdAt" DATETIME NOT NULL,
                    "updatedAt" DATETIME NOT NULL,
                    "metadataJSON" TEXT
                )
                """)
            
            // Create topic_session_bridge (legacy)
            try db.execute(sql: "DROP TABLE IF EXISTS topic_session_bridge")
            try db.execute(sql: """
                CREATE TABLE topic_session_bridge (
                    topicId TEXT PRIMARY KEY,
                    spaceId TEXT NOT NULL,
                    openclawSessionKey TEXT NOT NULL,
                    bridgeVersion INTEGER DEFAULT 1,
                    status TEXT DEFAULT 'active',
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME NOT NULL,
                    lastSyncAt DATETIME,
                    lastError TEXT,
                    retryCount INTEGER DEFAULT 0
                )
                """)
        }
        
        // Create a session
        let session = Session(id: "agent:main:default:topic:ABC123", agentId: "main", title: "Legacy Test")
        try store.saveSession(session)
        
        // Create a topic and bridge entry
        try DatabaseManager.shared.write { db in
            try db.execute(sql: """
                INSERT INTO topics (id, name, createdAt, updatedAt)
                VALUES ('ABC123', 'Legacy Topic', datetime('now'), datetime('now'))
                """)
            try db.execute(sql: """
                INSERT INTO topic_session_bridge (topicId, spaceId, openclawSessionKey, createdAt, updatedAt)
                VALUES ('ABC123', 'default', 'agent:main:default:topic:ABC123', datetime('now'), datetime('now'))
                """)
            // Insert message with topicId (legacy schema)
            try db.execute(sql: """
                INSERT INTO messages (id, content, senderId, senderName, topicId, timestamp)
                VALUES ('msg_legacy_1', 'Hello from legacy', 'user1', 'User', 'ABC123', datetime('now'))
                """)
        }
        
        // Verify data exists
        XCTAssertNotNil(try store.fetchSession(id: "agent:main:default:topic:ABC123"))
        
        let messagesBefore = try DatabaseManager.shared.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM messages WHERE topicId = ?", arguments: ["ABC123"])
        }
        XCTAssertEqual(messagesBefore.count, 1, "Should have 1 message before delete")
        
        // Cascade delete the session
        try store.deleteSessionCascading(id: "agent:main:default:topic:ABC123")
        
        // Verify session is gone
        XCTAssertNil(try store.fetchSession(id: "agent:main:default:topic:ABC123"), "Session should be deleted")
        
        // Verify messages are gone (deleted via topicId through bridge)
        let messagesAfter = try DatabaseManager.shared.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM messages WHERE topicId = ?", arguments: ["ABC123"])
        }
        XCTAssertEqual(messagesAfter.count, 0, "Messages should be cascade-deleted via topicId")
        
        // Verify topic is gone
        let topicsAfter = try DatabaseManager.shared.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM topics WHERE id = ?", arguments: ["ABC123"])
        }
        XCTAssertEqual(topicsAfter.count, 0, "Topic should be cascade-deleted")
        
        // Verify bridge entry is gone
        let bridgeAfter = try DatabaseManager.shared.read { db in
            try String.fetchAll(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: ["agent:main:default:topic:ABC123"])
        }
        XCTAssertEqual(bridgeAfter.count, 0, "Bridge entry should be cascade-deleted")
    }
    
    func testCascadeDelete() throws {
        // Create session, message, attachment
        let session = Session(id: "s_cascade", agentId: "a1")
        try store.saveSession(session)
        
        let msg = Message(id: "m_cascade", sessionId: "s_cascade", role: "user", content: "test", timestamp: Date())
        try store.saveMessage(msg)
        
        let attach = Attachment(id: "at_cascade", messageId: "m_cascade", type: "image", url: "http://example.com/img.png")
        try store.saveAttachment(attach)
        
        // Verify they exist
        XCTAssertNotNil(try store.fetchSession(id: "s_cascade"))
        XCTAssertNotNil(try store.fetchMessage(id: "m_cascade"))
        XCTAssertEqual(try store.fetchAttachments(messageId: "m_cascade").count, 1)
        
        // Cascade delete the session
        try store.deleteSessionCascading(id: "s_cascade")
        
        // Verify all gone
        XCTAssertNil(try store.fetchSession(id: "s_cascade"), "Session should be deleted")
        XCTAssertNil(try store.fetchMessage(id: "m_cascade"), "Message should be cascade-deleted")
        XCTAssertEqual(try store.fetchAttachments(messageId: "m_cascade").count, 0, "Attachments should be cascade-deleted")
    }
}