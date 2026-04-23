import XCTest
import Foundation
import GRDB
@testable import BeeChatSyncBridge
@testable import BeeChatGateway
@testable import BeeChatPersistence


final class MockRPCClient: RPCClientProtocol {
    var sessionsListHandler: (() -> [SessionInfo])?
    var chatHistoryHandler: ((String) -> [ChatMessagePayload])?
    
    func sessionsList() async throws -> [SessionInfo] {
        return try sessionsListHandler?() ?? []
    }
    
    func sessionsSubscribe() async throws { }
    
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
            id: UUID(), sessionKey: "s1", idempotencyKey: "same", content: "c1",
            status: .pending, runId: nil, createdAt: Date(), updatedAt: Date(), retryCount: 0
        )
        let entry2 = DeliveryLedgerEntry(
            id: UUID(), sessionKey: "s1", idempotencyKey: "same", content: "c2",
            status: .pending, runId: nil, createdAt: Date(), updatedAt: Date(), retryCount: 0
        )
        
        try ledgerRepo.save(entry1)
        XCTAssertThrowsError(try ledgerRepo.save(entry2)) { error in
        }
    }
    
    func testDeliveryLedgerFetchPending() throws {
        let e1 = DeliveryLedgerEntry(id: UUID(), sessionKey: "s1", idempotencyKey: "i1", content: "c1", status: .pending, runId: nil, createdAt: Date(), updatedAt: Date(), retryCount: 0)
        let e2 = DeliveryLedgerEntry(id: UUID(), sessionKey: "s2", idempotencyKey: "i2", content: "c2", status: .sent, runId: "r1", createdAt: Date(), updatedAt: Date(), retryCount: 0)
        
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
    
    
    func testReconcilerDeliversPending() async throws {
        let mockRPC = MockRPCClient()
        let reconciler = Reconciler(rpcClient: mockRPC, persistenceStore: store, ledgerRepo: ledgerRepo)
        
        let entry = DeliveryLedgerEntry(
            id: UUID(), sessionKey: "session-1", idempotencyKey: "idem-1", content: "hello",
            status: .pending, runId: "run-1", createdAt: Date(), updatedAt: Date(), retryCount: 0
        )
        try ledgerRepo.save(entry)
        
        mockRPC.sessionsListHandler = { [] }
        mockRPC.chatHistoryHandler = { key in
            [ChatMessagePayload(id: "idem-1", sessionKey: key, role: "user", content: "hello", timestamp: Date(), runId: "run-1")]
        }
        
        try await reconciler.reconcile(activeSessionKey: "session-1")
        
        let updated = try ledgerRepo.fetchByIdempotencyKey("idem-1")
        XCTAssertEqual(updated?.status, .delivered)
    }
    
    func testReconcilerFailsAfterRetries() async throws {
        let mockRPC = MockRPCClient()
        let reconciler = Reconciler(rpcClient: mockRPC, persistenceStore: store, ledgerRepo: ledgerRepo)
        
        let entry = DeliveryLedgerEntry(
            id: UUID(), sessionKey: "session-1", idempotencyKey: "idem-1", content: "hello",
            status: .pending, runId: "run-1", createdAt: Date(), updatedAt: Date(), retryCount: 3
        )
        try ledgerRepo.save(entry)
        
        mockRPC.sessionsListHandler = { [] }
        mockRPC.chatHistoryHandler = { _ in [] }
        
        try await reconciler.reconcile(activeSessionKey: "session-1")
        
        let updated = try ledgerRepo.fetchByIdempotencyKey("idem-1")
        XCTAssertEqual(updated?.status, .failed)
    }
}
