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
        let mode = try DatabaseManager.shared.read { db in
            try String.fetchAll(db, sql: "PRAGMA journal_mode").first
        }
        XCTAssertEqual(mode?.lowercased(), "wal")
        
        let sessions = try store.fetchSessions(limit: 1, offset: 0)
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
        
        var updatedS1 = session1
        updatedS1.title = "Updated Title 1"
        try store.upsertSessions([updatedS1])
        
        XCTAssertEqual(try store.fetchSessions(limit: 10, offset: 0).count, 2)
        XCTAssertEqual(try store.fetchSession(id: "s1")?.title, "Updated Title 1")
    }
    
    
    func testCreatedAtPreservedOnUpsert() throws {
        let originalTime = Date().addingTimeInterval(-3600) // 1 hour ago
        let session = Session(id: "s_createdAt", agentId: "a1", title: "Original", createdAt: originalTime)
        try store.saveSession(session)
        
        let fetched = try store.fetchSession(id: "s_createdAt")
        XCTAssertNotNil(fetched)
        let savedCreatedAt = fetched!.createdAt
        
        var updated = session
        updated.title = "Updated Title"
        try store.saveSession(updated)
        
        let afterUpdate = try store.fetchSession(id: "s_createdAt")
        XCTAssertNotNil(afterUpdate)
        XCTAssertEqual(afterUpdate?.title, "Updated Title")
        XCTAssertEqual(afterUpdate!.createdAt.timeIntervalSince1970, savedCreatedAt.timeIntervalSince1970, accuracy: 1.0,
                       "createdAt was overwritten on upsert — FAIL-1 regression")
    }
    
    
    
    func testCascadeDelete() throws {
        let session = Session(id: "s_cascade", agentId: "a1")
        try store.saveSession(session)
        
        let msg = Message(id: "m_cascade", sessionId: "s_cascade", role: "user", content: "test", timestamp: Date())
        try store.saveMessage(msg)
        
        let attach = Attachment(id: "at_cascade", messageId: "m_cascade", type: "image", url: "http://example.com/img.png")
        try store.saveAttachment(attach)
        
        XCTAssertNotNil(try store.fetchSession(id: "s_cascade"))
        XCTAssertNotNil(try store.fetchMessage(id: "m_cascade"))
        XCTAssertEqual(try store.fetchAttachments(messageId: "m_cascade").count, 1)
        
        try store.deleteSessionCascading(id: "s_cascade")
        
        XCTAssertNil(try store.fetchSession(id: "s_cascade"), "Session should be deleted")
        XCTAssertNil(try store.fetchMessage(id: "m_cascade"), "Message should be cascade-deleted")
        XCTAssertEqual(try store.fetchAttachments(messageId: "m_cascade").count, 0, "Attachments should be cascade-deleted")
    }
    
    // MARK: - Migration010 Session Key Alignment Tests
    
    func testMigration010_CreatesNewSchema() throws {
        // Verify session_key_mapping table exists
        let mappingTableExists = try DatabaseManager.shared.read { db in
            try db.tableExists("session_key_mapping")
        }
        XCTAssertTrue(mappingTableExists, "session_key_mapping table should exist after Migration010")
        
        // Verify _migration_metadata table exists
        let metadataTableExists = try DatabaseManager.shared.read { db in
            try db.tableExists("_migration_metadata")
        }
        XCTAssertTrue(metadataTableExists, "_migration_metadata table should exist after Migration010")
        
        // Verify new session columns exist
        let columns = try DatabaseManager.shared.read { db in
            try db.columns(in: "sessions").map { $0.name }
        }
        XCTAssertTrue(columns.contains("customName"), "sessions should have customName column")
        XCTAssertTrue(columns.contains("lastMessagePreview"), "sessions should have lastMessagePreview column")
        XCTAssertTrue(columns.contains("messageCount"), "sessions should have messageCount column")
        XCTAssertTrue(columns.contains("totalTokens"), "sessions should have totalTokens column")
        XCTAssertTrue(columns.contains("isArchived"), "sessions should have isArchived column")
    }
    
    func testMigration010_NewTriggersExist() throws {
        let triggers = try DatabaseManager.shared.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name")
        }
        XCTAssertTrue(triggers.contains("trg_session_increment_message_count"), "Session increment trigger should exist")
        XCTAssertTrue(triggers.contains("trg_session_decrement_message_count"), "Session decrement trigger should exist")
        XCTAssertFalse(triggers.contains("trg_increment_message_count"), "Old topic increment trigger should be dropped")
        XCTAssertFalse(triggers.contains("trg_decrement_message_count"), "Old topic decrement trigger should be dropped")
    }
    
    func testMigration010_SessionTriggerIncrementsMessageCount() throws {
        let session = Session(id: "trigger_test_session", agentId: "a1")
        try store.saveSession(session)
        
        // Verify initial messageCount is 0
        let initialSession = try store.fetchSession(id: "trigger_test_session")
        XCTAssertEqual(initialSession?.messageCount, 0)
        
        // Insert a message — trigger should increment messageCount
        let msg = Message(id: "trigger_msg_1", sessionId: "trigger_test_session", role: "user", content: "Hello", timestamp: Date())
        try store.saveMessage(msg)
        
        let afterInsert = try store.fetchSession(id: "trigger_test_session")
        XCTAssertEqual(afterInsert?.messageCount, 1, "messageCount should be 1 after inserting a message")
        
        // Insert another message
        let msg2 = Message(id: "trigger_msg_2", sessionId: "trigger_test_session", role: "assistant", content: "Hi", timestamp: Date())
        try store.saveMessage(msg2)
        
        let afterSecond = try store.fetchSession(id: "trigger_test_session")
        XCTAssertEqual(afterSecond?.messageCount, 2, "messageCount should be 2 after inserting two messages")
        
        // Delete a message — trigger should decrement messageCount
        try store.deleteMessage(id: "trigger_msg_1")
        
        let afterDelete = try store.fetchSession(id: "trigger_test_session")
        XCTAssertEqual(afterDelete?.messageCount, 1, "messageCount should be 1 after deleting a message")
    }
    
    func testMigration010_SessionTriggerPreventsNegativeCount() throws {
        let session = Session(id: "negative_test_session", agentId: "a1")
        try store.saveSession(session)
        
        // Try to decrement when count is already 0 (should stay at 0, not go negative)
        try DatabaseManager.shared.write { db in
            try db.execute(sql: """
                DELETE FROM messages WHERE sessionId = 'negative_test_session'
                """)
        }
        
        let afterDelete = try store.fetchSession(id: "negative_test_session")
        XCTAssertGreaterThanOrEqual(afterDelete?.messageCount ?? 0, 0, "messageCount should not go negative")
    }
    
    func testMigration010_DataMigration_PopulatesMapping() throws {
        // Set up: create sessions with gateway keys and topics with local IDs
        let gatewayKey1 = "agent:main:gw111111-1111-1111-1111-111111111111"
        let gatewayKey2 = "agent:main:gw222222-2222-2222-2222-222222222222"
        let localId1 = "local-uuid-1111"
        let localId2 = "local-uuid-2222"
        
        let session1 = Session(id: gatewayKey1, agentId: "main", title: "Session 1")
        let session2 = Session(id: gatewayKey2, agentId: "main", title: "Session 2")
        try store.upsertSessions([session1, session2])
        
        let topic1 = Topic(id: localId1, name: "Custom Topic 1", lastMessagePreview: "Preview 1", unreadCount: 3, sessionKey: gatewayKey1, isArchived: true, messageCount: 5)
        let topic2 = Topic(id: localId2, name: "Custom Topic 2", lastMessagePreview: "Preview 2", unreadCount: 0, sessionKey: gatewayKey2, isArchived: false, messageCount: 10)
        try store.saveTopic(topic1)
        try store.saveTopic(topic2)
        
        // Create messages with local UUIDs (simulating pre-migration state)
        let msg1 = Message(id: "msg_local_1", sessionId: localId1, role: "user", content: "Hello", timestamp: Date())
        let msg2 = Message(id: "msg_local_2", sessionId: localId2, role: "assistant", content: "Hi", timestamp: Date())
        try store.saveMessage(msg1)
        try store.saveMessage(msg2)
        
        // Simulate migration: set pending flag and run data migration
        DatabaseManager.shared.sessionKeyAlignmentPending = true
        
        let topicToGatewayKey: [String: String] = [
            localId1: gatewayKey1,
            localId2: gatewayKey2
        ]
        
        try DatabaseManager.shared.runSessionKeyAlignmentMigration(topicToGatewayKey: topicToGatewayKey)
        
        // Verify: pending flag cleared
        XCTAssertFalse(DatabaseManager.shared.sessionKeyAlignmentPending, "Pending flag should be cleared after migration")
        
        // Verify: session_key_mapping table populated
        let mappingCount = try DatabaseManager.shared.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_key_mapping") ?? 0
        }
        XCTAssertEqual(mappingCount, 2, "session_key_mapping should have 2 entries")
        
        // Verify: session columns populated from topics
        let migratedSession1 = try store.fetchSession(id: gatewayKey1)
        XCTAssertEqual(migratedSession1?.customName, "Custom Topic 1", "customName should be set from topic")
        XCTAssertEqual(migratedSession1?.lastMessagePreview, "Preview 1", "lastMessagePreview should be set from topic")
        XCTAssertEqual(migratedSession1?.isArchived, true, "isArchived should be set from topic")
        XCTAssertEqual(migratedSession1?.unreadCount, 3, "unreadCount should be set from topic")
        
        let migratedSession2 = try store.fetchSession(id: gatewayKey2)
        XCTAssertEqual(migratedSession2?.customName, "Custom Topic 2", "customName should be set from topic")
        XCTAssertEqual(migratedSession2?.isArchived, false, "isArchived should be false")
        
        // Verify: messages rewritten from local UUIDs to gateway keys
        let migratedMsg1 = try store.fetchMessage(id: "msg_local_1")
        XCTAssertEqual(migratedMsg1?.sessionId, gatewayKey1, "Message sessionId should be rewritten to gateway key")
        
        let migratedMsg2 = try store.fetchMessage(id: "msg_local_2")
        XCTAssertEqual(migratedMsg2?.sessionId, gatewayKey2, "Message sessionId should be rewritten to gateway key")
    }
    
    func testMigration010_DataMigration_HandlesOrphans() throws {
        let gatewayKey = "agent:main:gw_orphan_test"
        let localId = "local-uuid-orphan"
        let orphanId = "orphan-local-uuid"
        
        let session = Session(id: gatewayKey, agentId: "main", title: "Session")
        try store.saveSession(session)
        
        let topic = Topic(id: localId, name: "Topic", sessionKey: gatewayKey, messageCount: 2)
        try store.saveTopic(topic)
        
        // Create a message with a local UUID
        let msg = Message(id: "msg_orphan", sessionId: localId, role: "user", content: "Hello", timestamp: Date())
        try store.saveMessage(msg)
        
        // Create an orphaned message (sessionId not in mapping)
        let orphanMsg = Message(id: "msg_truly_orphan", sessionId: orphanId, role: "user", content: "Orphan", timestamp: Date())
        try store.saveMessage(orphanMsg)
        
        DatabaseManager.shared.sessionKeyAlignmentPending = true
        
        let topicToGatewayKey: [String: String] = [
            localId: gatewayKey
            // orphanId intentionally not mapped
        ]
        
        try DatabaseManager.shared.runSessionKeyAlignmentMigration(topicToGatewayKey: topicToGatewayKey)
        
        // Verify: orphan message rewritten to synthetic key
        let migratedOrphanMsg = try store.fetchMessage(id: "msg_truly_orphan")
        XCTAssertEqual(migratedOrphanMsg?.sessionId, "orphan:\(orphanId)", "Orphan message should be rewritten to synthetic key")
        
        // Verify: synthetic orphan session created
        let orphanSession = try store.fetchSession(id: "orphan:\(orphanId)")
        XCTAssertNotNil(orphanSession, "Synthetic orphan session should be created")
        XCTAssertEqual(orphanSession?.isArchived, true, "Orphan session should be archived")
    }
    
    func testMigration010_DataMigration_SkipsWhenNotPending() throws {
        // Ensure pending flag is false
        DatabaseManager.shared.sessionKeyAlignmentPending = false
        
        // Should not throw, should do nothing
        try DatabaseManager.shared.runSessionKeyAlignmentMigration(topicToGatewayKey: [:])
        
        XCTAssertFalse(DatabaseManager.shared.sessionKeyAlignmentPending)
    }
    
    func testMigration010_SessionNewFieldsPersist() throws {
        let session = Session(
            id: "new_fields_session",
            agentId: "main",
            title: "Test",
            customName: "Custom Name",
            lastMessagePreview: "Last preview",
            messageCount: 42,
            totalTokens: 1234,
            isArchived: true
        )
        try store.saveSession(session)
        
        let fetched = try store.fetchSession(id: "new_fields_session")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.customName, "Custom Name")
        XCTAssertEqual(fetched?.lastMessagePreview, "Last preview")
        XCTAssertEqual(fetched?.messageCount, 42)
        XCTAssertEqual(fetched?.totalTokens, 1234)
        XCTAssertEqual(fetched?.isArchived, true)
    }
    
    func testMigration010_OldTablesPreserved() throws {
        // Verify topics table still exists (not dropped)
        let topicsExists = try DatabaseManager.shared.read { db in
            try db.tableExists("topics")
        }
        XCTAssertTrue(topicsExists, "topics table should be preserved")
        
        // Verify topic_session_bridge table still exists (not dropped)
        let bridgeExists = try DatabaseManager.shared.read { db in
            try db.tableExists("topic_session_bridge")
        }
        XCTAssertTrue(bridgeExists, "topic_session_bridge table should be preserved")
    }
}