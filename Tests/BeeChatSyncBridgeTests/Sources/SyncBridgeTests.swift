import XCTest
import Foundation
import GRDB
@testable import BeeChatSyncBridge
@testable import BeeChatGateway
@testable import BeeChatPersistence


final class MockRPCClient: RPCClientProtocol {
    var sessionsListHandler: (() -> [SessionInfo])?
    var chatHistoryHandler: ((String) -> [ChatMessagePayload])?
    var sessionsUsageHandler: ((String) -> Double)?
    var sessionsResetHandler: ((String, String) -> Bool)?
    
    func sessionsList() async throws -> [SessionInfo] {
        return try sessionsListHandler?() ?? []
    }
    
    func sessionsSubscribe() async throws { }
    
    func sessionsUsage(sessionKey: String) async throws -> Double {
        return sessionsUsageHandler?(sessionKey) ?? 0.0
    }
    
    func sessionsReset(sessionKey: String, reason: String) async throws -> Bool {
        return sessionsResetHandler?(sessionKey, reason) ?? false
    }
    
    func chatHistory(sessionKey: String, limit: Int? = 200) async throws -> [ChatMessagePayload] {
        return try chatHistoryHandler?(sessionKey) ?? []
    }
    
    func chatSend(sessionKey: String, message: String, idempotencyKey: String, thinking: String? = nil, attachments: [ChatAttachment]? = nil) async throws -> String { return "run-id" }
    func chatAbort(sessionKey: String) async throws -> Bool { return true }
}


final class SyncBridgeTests: XCTestCase {
    var store: BeeChatPersistenceStore!
    var dbPath: String!
    var ledgerRepo: DeliveryLedgerRepository!
    
    override func setUpWithError() throws {
        dbPath = "/tmp/beechat_sync_test_\(UUID().uuidString).db"
        store = BeeChatPersistenceStore()
        try store.openDatabase(at: dbPath)
        
        ledgerRepo = DeliveryLedgerRepository(dbManager: DatabaseManager.shared)
    }
    
    override func tearDownWithError() throws {
        store.closeDatabase()
        try? FileManager.default.removeItem(atPath: dbPath)
        
        store = nil
        ledgerRepo = nil
    }
    
    
    func testAgentEventParsing() throws {
        let json = """
        {
            "runId": "2cd1e889-81d0-4bb8-b356-d49a7b38ea3a",
            "stream": "item",
            "data": {
                "itemId": "tool:ollama_call_123",
                "phase": "update",
                "kind": "tool",
                "title": "Executing tool",
                "status": "running",
                "name": "exec",
                "meta": "some meta",
                "toolCallId": "call_123"
            },
            "sessionKey": "agent:main:telegram:123",
            "seq": 566,
            "ts": 1776440726273
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let event = try decoder.decode(AgentEventPayload.self, from: json)
        
        XCTAssertEqual(event.runId, "2cd1e889-81d0-4bb8-b356-d49a7b38ea3a")
        XCTAssertEqual(event.stream, "item")
        XCTAssertEqual(event.sessionKey, "agent:main:telegram:123")
        XCTAssertEqual(event.seq, 566)
        XCTAssertEqual(event.ts, 1776440726273)
        XCTAssertEqual(event.data.itemId, "tool:ollama_call_123")
        XCTAssertEqual(event.data.phase, "update")
        XCTAssertEqual(event.data.kind, "tool")
        XCTAssertEqual(event.data.title, "Executing tool")
        XCTAssertEqual(event.data.status, "running")
        XCTAssertEqual(event.data.name, "exec")
        XCTAssertEqual(event.data.meta, "some meta")
        XCTAssertEqual(event.data.toolCallId, "call_123")
    }
    
    func testAgentEventParsingMissingOptionals() throws {
        let json = """
        {
            "runId": "run-1",
            "stream": "text",
            "data": {
                "text": "Hello world"
            },
            "sessionKey": "session-1",
            "ts": 12345
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let event = try decoder.decode(AgentEventPayload.self, from: json)
        
        XCTAssertEqual(event.runId, "run-1")
        XCTAssertNil(event.seq)
        XCTAssertNil(event.data.itemId)
        XCTAssertEqual(event.data.text, "Hello world")
    }
    
    
    func testEventRouterRouting() async {
        let config = SyncBridgeConfiguration(
            gatewayClient: GatewayClient(config: .init(url: "http://localhost", token: "test")),
            persistenceStore: store
        )
        let bridge = SyncBridge(config: config)
        let router = EventRouter(syncBridge: bridge)
        
        let payload: [String: AnyCodable] = [
            "runId": AnyCodable("run-1"),
            "stream": AnyCodable("item"),
            "sessionKey": AnyCodable("session-1"),
            "data": AnyCodable([
                "itemId": "item-1",
                "phase": "delta"
            ] as [String: Any])
        ]
        
        try? await router.route(event: "agent", payload: payload)
        try? await router.route(event: "sessions.changed", payload: nil)
        try? await router.route(event: "tick", payload: nil)
        try? await router.route(event: "unknown", payload: nil)
    }
    
    
    func testDeliveryLedgerCRUD() throws {
        let entry = DeliveryLedgerEntry(
            id: UUID(),
            sessionKey: "session-1",
            idempotencyKey: "idem-1",
            content: "hello",
            originalContent: nil,
            status: .pending,
            runId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            retryCount: 0
        )
        
        try ledgerRepo.save(entry)
        
        let fetched = try ledgerRepo.fetchByIdempotencyKey("idem-1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.content, "hello")
        XCTAssertEqual(fetched?.status, .pending)
        
        try ledgerRepo.updateStatus(idempotencyKey: "idem-1", status: .sent, runId: "run-1")
        let updated = try ledgerRepo.fetchByIdempotencyKey("idem-1")
        XCTAssertEqual(updated?.status, .sent)
        XCTAssertEqual(updated?.runId, "run-1")
        
        try ledgerRepo.updateStatus(idempotencyKey: "idem-1", status: .delivered)
        let delivered = try ledgerRepo.fetchByIdempotencyKey("idem-1")
        XCTAssertEqual(delivered?.status, .delivered)
    }
    
    func testDeliveryLedgerUniqueIdempotencyKey() throws {
        let entry1 = DeliveryLedgerEntry(
            id: UUID(), sessionKey: "s1", idempotencyKey: "same", content: "c1", originalContent: nil,
            status: .pending, runId: nil, createdAt: Date(), updatedAt: Date(), retryCount: 0
        )
        let entry2 = DeliveryLedgerEntry(
            id: UUID(), sessionKey: "s1", idempotencyKey: "same", content: "c2", originalContent: nil,
            status: .pending, runId: nil, createdAt: Date(), updatedAt: Date(), retryCount: 0
        )
        
        try ledgerRepo.save(entry1)
        XCTAssertThrowsError(try ledgerRepo.save(entry2)) { error in
        }
    }
    
    func testDeliveryLedgerFetchPending() throws {
        let e1 = DeliveryLedgerEntry(id: UUID(), sessionKey: "s1", idempotencyKey: "i1", content: "c1", originalContent: nil, status: .pending, runId: nil, createdAt: Date(), updatedAt: Date(), retryCount: 0)
        let e2 = DeliveryLedgerEntry(id: UUID(), sessionKey: "s2", idempotencyKey: "i2", content: "c2", originalContent: nil, status: .sent, runId: "r1", createdAt: Date(), updatedAt: Date(), retryCount: 0)
        
        try ledgerRepo.save(e1)
        try ledgerRepo.save(e2)
        
        let pending = try ledgerRepo.fetchPending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.idempotencyKey, "i1")
    }
    
    
    func testSessionInfoParsing() throws {
        let json = """
        {
            "key": "session-1",
            "label": "Test Session",
            "channel": "telegram",
            "model": "gpt-4",
            "totalTokens": 100,
            "lastMessageAt": "2026-04-17T12:00:00Z"
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        let info = try decoder.decode(SessionInfo.self, from: json)
        XCTAssertEqual(info.key, "session-1")
        XCTAssertEqual(info.label, "Test Session")
    }
    
    func testChatMessageParsing() throws {
        let json = """
        {
            "id": "msg-1",
            "sessionKey": "session-1",
            "role": "user",
            "content": "Hello",
            "timestamp": "2026-04-17T12:00:00Z",
            "runId": "run-1"
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let msg = try decoder.decode(ChatMessagePayload.self, from: json)
        XCTAssertEqual(msg.id, "msg-1")
        XCTAssertEqual(msg.content, "Hello")
    }

    func testSessionMessageParsesAgentId() throws {
        let json = """
        {
            "sessionKey": "agent:q:main:subagent:abc123",
            "data": {
                "id": "msg-1",
                "role": "assistant",
                "content": "Done",
                "agentId": "q"
            },
            "ts": 1776440726273
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(SessionMessagePayload.self, from: json)
        XCTAssertEqual(payload.data.agentId, "q")
    }

    func testAgentIdFallbackFromSessionKey() throws {
        XCTAssertEqual(SyncBridge.agentId(fromSessionKey: "agent:q:main:subagent:abc123"), "q")
        XCTAssertEqual(SyncBridge.agentId(fromSessionKey: "agent:main:telegram:group:-1003830552971:topic:1185"), "main")
        XCTAssertNil(SyncBridge.agentId(fromSessionKey: "session-1"))
    }
    
    
    func testReconcilerDeliversPending() async throws {
        let mockRPC = MockRPCClient()
        let reconciler = Reconciler(rpcClient: mockRPC, persistenceStore: store, ledgerRepo: ledgerRepo)
        
        let entry = DeliveryLedgerEntry(
            id: UUID(), sessionKey: "session-1", idempotencyKey: "idem-1", content: "hello", originalContent: nil,
            status: .pending, runId: "run-1", createdAt: Date(), updatedAt: Date(), retryCount: 0
        )
        try ledgerRepo.save(entry)
        
        mockRPC.sessionsListHandler = { [] }
        mockRPC.chatHistoryHandler = { key in
            [ChatMessagePayload(id: "idem-1", sessionKey: key, role: "user", content: "hello", timestamp: Date(), runId: "run-1")]
        }
        
        try await reconciler.reconcile(activeSessionKeys: ["session-1"])
        
        let updated = try ledgerRepo.fetchByIdempotencyKey("idem-1")
        XCTAssertEqual(updated?.status, .delivered)
    }
    
    func testReconcilerFailsAfterRetries() async throws {
        let mockRPC = MockRPCClient()
        let reconciler = Reconciler(rpcClient: mockRPC, persistenceStore: store, ledgerRepo: ledgerRepo)
        
        let entry = DeliveryLedgerEntry(
            id: UUID(), sessionKey: "session-1", idempotencyKey: "idem-1", content: "hello", originalContent: nil,
            status: .pending, runId: "run-1", createdAt: Date(), updatedAt: Date(), retryCount: 3
        )
        try ledgerRepo.save(entry)
        
        mockRPC.sessionsListHandler = { [] }
        mockRPC.chatHistoryHandler = { _ in [] }
        
        try await reconciler.reconcile(activeSessionKeys: ["session-1"])
        
        let updated = try ledgerRepo.fetchByIdempotencyKey("idem-1")
        XCTAssertEqual(updated?.status, .failed)
    }
    
    // MARK: - Topic Context Injection Tests

    func testBuildContextHeaderReturnsCorrectFormat() async {
        let topic = Topic(id: "test-id", name: "Topcon-Eval", sessionKey: "agent:main:test")
        let header = await bridge().buildContextHeader(topic: topic)
        XCTAssertEqual(header, "[TOPIC-CONTEXT]\nTopic: Topcon-Eval")
    }

    func testBuildContextHeaderWithSpecialCharacters() async {
        let topic = Topic(id: "test-id", name: "AI & Crypto", sessionKey: "agent:main:test")
        let header = await bridge().buildContextHeader(topic: topic)
        XCTAssertEqual(header, "[TOPIC-CONTEXT]\nTopic: AI & Crypto")
    }

    func testFetchLocalHistoryFiltersTopicContext() async throws {
        // Insert messages with different prefixes
        let sessionKey = "session-filter-test-\(UUID().uuidString)"
        let m1 = Message(id: UUID().uuidString, sessionId: sessionKey, role: "user", content: "[TOPIC-CONTEXT]\nTopic: Test", timestamp: Date())
        let m2 = Message(id: UUID().uuidString, sessionId: sessionKey, role: "user", content: "[SESSION-CONTEXT] Continuing", timestamp: Date())
        let m3 = Message(id: UUID().uuidString, sessionId: sessionKey, role: "user", content: "[SESSION-RESET] Reset", timestamp: Date())
        let m4 = Message(id: UUID().uuidString, sessionId: sessionKey, role: "user", content: "Hello world", timestamp: Date())
        try DatabaseManager.shared.write { db in
            var msg = m1; try msg.insert(db)
            msg = m2; try msg.insert(db)
            msg = m3; try msg.insert(db)
            msg = m4; try msg.insert(db)
        }

        let bridgeInstance = bridge()
        let result = try await bridgeInstance.fetchLocalHistory(sessionKey: sessionKey, limit: 30)

        // Only the plain message should survive filtering
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.content, "Hello world")

        // Cleanup
        try DatabaseManager.shared.write { db in
            try Message.filter(Column("sessionId") == sessionKey).deleteAll(db)
        }
    }

    // MARK: - Project Context Reader Tests (Kieran M1)

    // Test 1: validatePath — rejects paths outside allowed prefix, accepts valid paths, rejects symlink-escape
    func testValidatePathRejectsOutsideAllowedPrefix() {
        // Paths outside /Users/openclaw/Projects/ must be rejected
        XCTAssertFalse(ProjectContextReader.validatePath("/etc/passwd"))
        XCTAssertFalse(ProjectContextReader.validatePath("/tmp"))
        XCTAssertFalse(ProjectContextReader.validatePath("/Users/openclaw/.openclaw"))
        XCTAssertFalse(ProjectContextReader.validatePath("/Users/openclaw/Projects")) // missing trailing slash
    }

    func testValidatePathAcceptsRealProjectDirectory() {
        // Use canonical path (capital P) — symlink resolves to this
        let realPath = "/Users/openclaw/Projects/BeeChat-v5"
        XCTAssertTrue(FileManager.default.fileExists(atPath: realPath))
        XCTAssertTrue(ProjectContextReader.validatePath(realPath))
    }

    func testValidatePathRejectsNonExistentDirectory() {
        XCTAssertFalse(ProjectContextReader.validatePath("/Users/openclaw/Projects/nonexistent-project"))
    }

    func testValidatePathRejectsSymlinkEscape() {
        // Create a symlink outside the allowed prefix pointing to a directory inside it
        let targetDir = "/Users/openclaw/Projects/BeeChat-v5"
        let symlinkPath = "/tmp/beechat_symlink_escape_\(UUID().uuidString)"

        do {
            try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: targetDir)
            // resolveSymlinksInPath follows the symlink → canonical path → still inside prefix → passes
            // But the key test: a symlink whose TARGET is outside the prefix should fail
            let outsideTarget = "/tmp/outside_projects_\(UUID().uuidString)"
            let symlinkOutside = "/Users/openclaw/Projects/.fake_symlink_\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: outsideTarget, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: symlinkOutside, withDestinationPath: outsideTarget)

            // This should be rejected because the resolved target is /tmp/... (outside prefix)
            XCTAssertFalse(ProjectContextReader.validatePath(symlinkOutside))

            // Cleanup
            try? FileManager.default.removeItem(atPath: symlinkOutside)
        } catch {
            XCTFail("Failed to set up symlink test: \(error)")
        }

        // Cleanup symlink in /tmp
        try? FileManager.default.removeItem(atPath: symlinkPath)
    }

    // Test 2: byte truncation with multi-byte characters
    func testReadByteTruncationWithMultiByteCharacters() {
        // Create a temp directory inside allowed prefix with a test STATUS.md containing emoji and CJK
        let tempDir = "/Users/openclaw/Projects/.beechat_test_pcr_\(UUID().uuidString)"
        let statusPath = "\(tempDir)/STATUS.md"

        do {
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
            // Each emoji is 4 bytes; CJK chars are 3 bytes each
            let emojiContent = String(repeating: "🐝", count: 100) // 400 bytes
            let cjkContent = String(repeating: "测试", count: 100) // 600 bytes
            let content = "\(emojiContent)\n\(cjkContent)"
            try content.write(toFile: statusPath, atomically: true, encoding: .utf8)

            // Validate path is accepted
            XCTAssertTrue(ProjectContextReader.validatePath(tempDir), "Temp project dir should validate")

            // Read with a tight byte budget — should truncate cleanly, not crash
            let result = ProjectContextReader.read(projectPath: tempDir, maxTotalBytes: 200)
            XCTAssertFalse(result.isEmpty, "Should have read some content within budget")
            XCTAssertTrue(result.utf8.count <= 500, "Result should not exceed budget + overhead")
        } catch {
            XCTFail("Failed to set up test: \(error)")
        }

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    // Test 3: Topic Hashable — identity-only equality (tested in BeeChatAppTests via TopicViewModel)
    // This validates the persistence layer Topic.setProjectPath round-trips correctly.
    func testTopicSetProjectPathRoundTrips() {
        // Use canonical path (capital P) — matches Topic.setProjectPath allowedPrefix
        let realPath = "/Users/openclaw/Projects/BeeChat-v5"
        var topic = Topic(id: "same-id", name: "Test Project", sessionKey: "agent:main:test")
        XCTAssertNil(topic.projectPath)

        XCTAssertNoThrow(try topic.setProjectPath(realPath))
        XCTAssertEqual(topic.projectPath, realPath)

        // Clear
        XCTAssertNoThrow(try topic.setProjectPath(nil))
        XCTAssertNil(topic.projectPath)
    }

    // Test 4: buildContextHeader — with projectPath includes file content, without returns topic-only
    func testBuildContextHeaderWithProjectPathIncludesContent() async {
        // Create a temp project directory inside allowed prefix with STATUS.md
        let tempDir = "/Users/openclaw/Projects/.beechat_test_bch_\(UUID().uuidString)"
        let statusPath = "\(tempDir)/STATUS.md"

        do {
            try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
            try "Status: Active\nCurrent: Testing".write(toFile: statusPath, atomically: true, encoding: .utf8)

            var topic = Topic(id: "test-id", name: "TestProject", sessionKey: "agent:main:test")
            try topic.setProjectPath(tempDir)

            let header = await bridge().buildContextHeader(topic: topic)

            // Should contain the topic name AND the project content
            XCTAssertTrue(header.contains("[TOPIC-CONTEXT]"), "Header should contain topic context marker")
            XCTAssertTrue(header.contains("Topic: TestProject"), "Header should contain topic name")
            XCTAssertTrue(header.contains("[PROJECT-CONTEXT]"), "Header should contain project context marker")
            XCTAssertTrue(header.contains("STATUS.md"), "Header should reference STATUS.md")
        } catch {
            XCTFail("Failed to set up test: \(error)")
        }

        // Cleanup
        try? FileManager.default.removeItem(atPath: tempDir)
    }

    func testBuildContextHeaderWithoutProjectPathReturnsTopicOnly() async {
        let topic = Topic(id: "test-id", name: "NoProject", sessionKey: "agent:main:test")
        let header = await bridge().buildContextHeader(topic: topic)

        // Should only contain topic context, no project section
        XCTAssertTrue(header.contains("[TOPIC-CONTEXT]"))
        XCTAssertTrue(header.contains("Topic: NoProject"))
        XCTAssertFalse(header.contains("[PROJECT-CONTEXT]"))
    }

    // MARK: - Helper

    private func bridge() -> SyncBridge {
        let config = SyncBridgeConfiguration(
            gatewayClient: GatewayClient(config: .init(url: "http://localhost", token: "test")),
            persistenceStore: store!
        )
        return SyncBridge(config: config)
    }
}
