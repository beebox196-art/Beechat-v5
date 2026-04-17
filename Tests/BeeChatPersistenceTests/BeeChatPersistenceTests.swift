import XCTest
import GRDB
@testable import BeeChatPersistence

final class BeeChatPersistenceTests: XCTestCase {
    var store: BeeChatPersistenceStore!
    var dbPath: String!
    
    override func setUp() {
        super.setUp()
        dbPath = "/tmp/beechat_test_\(UUID().uuidString).db"
        store = BeeChatPersistenceStore()
        try! store.openDatabase(at: dbPath)
    }
    
    override func tearDown() {
        store.closeDatabase()
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }
    
    func testDatabaseOpenAndWal() throws {
        // Verify database opened successfully and WAL mode is active
        let mode = try DatabaseManager.shared.read { db in
            try String.fetchAll(db, sql: "PRAGMA journal_mode").first
        }
        XCTAssertEqual(mode?.lowercased(), "wal")
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
}