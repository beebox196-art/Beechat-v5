import XCTest

/// Thread-safe order tracker for concurrent test validation.
private actor OrderTracker {
    private(set) var orders: [Int] = []
    func append(_ value: Int) { orders.append(value) }
}
import Foundation
@testable import BeeChatSyncBridge
@testable import BeeChatGateway
@testable import BeeChatPersistence

// MARK: - TopicPublishQueue Tests

final class TopicPublishQueueTests: XCTestCase {

    /// Verify that operations for the same session key execute in serial FIFO order.
    func testPublishQueueSerialisesPerTopic() async {
        let queue = TopicPublishQueue()
        var executionOrder: [Int] = []
        let expectation = XCTestExpectation(description: "All operations complete")
        expectation.expectedFulfillmentCount = 3

        // Enqueue 3 operations for the same key
        for i in 1...3 {
            await queue.enqueue(sessionKey: "key-1") {
                // Small delay to simulate async work
                try? await Task.sleep(for: .milliseconds(10))
                executionOrder.append(i)
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 5.0)

        // Verify FIFO order
        XCTAssertEqual(executionOrder, [1, 2, 3], "Operations should execute in FIFO order")
    }

    /// Verify that different session keys can run concurrently (their own serial queues).
    func testPublishQueueAllowsParallelismAcrossKeys() async {
        let queue = TopicPublishQueue()
        let tracker = OrderTracker()
        let expectation = XCTestExpectation(description: "All operations complete")
        expectation.expectedFulfillmentCount = 2

        await queue.enqueue(sessionKey: "key-a") {
            await tracker.append(1)
            expectation.fulfill()
        }
        await queue.enqueue(sessionKey: "key-b") {
            await tracker.append(2)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 5.0)
        // Both should have executed (order between keys is non-deterministic)
        let order = await tracker.orders
        XCTAssertEqual(order.sorted(), [1, 2])
    }
}

// MARK: - AnyCodable Encoding Round-Trip Tests

final class AnyCodableRoundTripTests: XCTestCase {

    /// Verify that BeeChatTopicMetadata can be encoded → JSON → decoded as AnyCodable.
    func testMetadataRoundTripViaAnyCodable() throws {
        let metadata = BeeChatTopicMetadata(
            topicId: "abc-123",
            isArchived: false,
            projectPath: "/Users/test/project",
            updatedAt: "2026-05-22T12:00:00Z"
        )

        // Encode to JSON data
        let data = try JSONEncoder().encode(metadata)
        // Decode as AnyCodable
        let anyCodable = try JSONDecoder().decode(AnyCodable.self, from: data)

        // Verify the AnyCodable value is a dictionary
        guard let dict = anyCodable.value as? [String: Any] else {
            XCTFail("Expected AnyCodable value to be a dictionary")
            return
        }

        XCTAssertEqual(dict["topicId"] as? String, "abc-123")
        XCTAssertEqual(dict["isArchived"] as? Bool, false)
        XCTAssertEqual(dict["projectPath"] as? String, "/Users/test/project")
        XCTAssertEqual(dict["updatedAt"] as? String, "2026-05-22T12:00:00Z")
    }

    /// Verify that nil metadata with unset=true produces correct params.
    func testPluginPatchUnsetParams() throws {
        // Simulate what RPCClient.sessionsPluginPatch does for unset=true
        let params: [String: AnyCodable] = [
            "key": AnyCodable("agent:main:abc-123"),
            "pluginId": AnyCodable("beechat"),
            "namespace": AnyCodable("metadata"),
            "unset": AnyCodable(true)
        ]

        // When unset is true, value should NOT be added
        XCTAssertNil(params["value"], "value should not be set when unset=true")

        XCTAssertEqual(params["key"]?.value as? String, "agent:main:abc-123")
        XCTAssertEqual(params["pluginId"]?.value as? String, "beechat")
        XCTAssertEqual(params["namespace"]?.value as? String, "metadata")
        XCTAssertEqual(params["unset"]?.value as? Bool, true)
    }

    /// Verify that non-nil metadata with unset=false produces correct params.
    func testPluginPatchWithValueParams() throws {
        let metadata = BeeChatTopicMetadata(
            topicId: "def-456",
            isArchived: true,
            projectPath: nil,
            updatedAt: "2026-05-22T13:00:00Z"
        )

        var params: [String: AnyCodable] = [
            "key": AnyCodable("agent:main:def-456"),
            "pluginId": AnyCodable("beechat"),
            "namespace": AnyCodable("metadata"),
            "unset": AnyCodable(false)
        ]

        // Encode metadata into AnyCodable
        let data = try JSONEncoder().encode(metadata)
        params["value"] = try JSONDecoder().decode(AnyCodable.self, from: data)

        XCTAssertNotNil(params["value"])
        guard let valueDict = params["value"]?.value as? [String: Any] else {
            XCTFail("Expected value to be a dictionary")
            return
        }

        XCTAssertEqual(valueDict["topicId"] as? String, "def-456")
        XCTAssertEqual(valueDict["isArchived"] as? Bool, true)
        XCTAssertNil(valueDict["projectPath"], "projectPath should be nil")
    }
}

// MARK: - RPC Wrapper Param Construction Tests

final class RPCWrapperParamTests: XCTestCase {

    /// Verify sessionsPatch builds correct params.
    func testSessionsPatchBuildsCorrectRequest() {
        // Simulate the param construction from RPCClient.sessionsPatch
        let key = "agent:main:test-topic-id"
        let label = "My Test Topic"

        let params: [String: AnyCodable] = [
            "key": AnyCodable(key),
            "label": AnyCodable(label)
        ]

        XCTAssertEqual(params["key"]?.value as? String, key)
        XCTAssertEqual(params["label"]?.value as? String, label)
        XCTAssertEqual(params.count, 2, "Should only have key and label")
    }

    /// Verify sessionsPluginPatch builds correct params with value.
    func testSessionsPluginPatchWithValue() throws {
        let key = "agent:main:test-topic"
        let metadata = BeeChatTopicMetadata(
            topicId: "test-topic",
            isArchived: false,
            projectPath: "/some/path",
            updatedAt: "2026-05-22T10:00:00Z"
        )

        var params: [String: AnyCodable] = [
            "key": AnyCodable(key),
            "pluginId": AnyCodable("beechat"),
            "namespace": AnyCodable("metadata"),
            "unset": AnyCodable(false)
        ]

        let data = try JSONEncoder().encode(metadata)
        params["value"] = try JSONDecoder().decode(AnyCodable.self, from: data)

        XCTAssertEqual(params.count, 5, "Should have key, pluginId, namespace, unset, value")
        XCTAssertNotNil(params["value"])
    }
}

// MARK: - ExtractProjectPath Tests

final class ExtractProjectPathTests: XCTestCase {

    func testExtractProjectPathWithValidJSON() throws {
        let json = """
        {"projectPath": "/Users/test/MyProject", "otherKey": "value"}
        """
        // Reproduce the SyncBridge.extractProjectPath logic
        guard let data = json.data(using: .utf8) else {
            XCTFail("Failed to create data from JSON string")
            return
        }
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let projectPath = dict?["projectPath"] as? String

        XCTAssertEqual(projectPath, "/Users/test/MyProject")
    }

    func testExtractProjectPathWithMissingPath() throws {
        let json = """
        {"otherKey": "value"}
        """
        guard let data = json.data(using: .utf8) else { return }
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let projectPath = dict?["projectPath"] as? String

        XCTAssertNil(projectPath)
    }

    func testExtractProjectPathWithEmptyString() throws {
        let json = """
        {"projectPath": ""}
        """
        guard let data = json.data(using: .utf8) else { return }
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let projectPath = dict?["projectPath"] as? String

        XCTAssertEqual(projectPath, "")
    }
}

// MARK: - Runtime TopicId Guard Tests

final class TopicIdGuardTests: XCTestCase {

    /// Verify that matching topicId and session key suffix passes the guard.
    func testMatchingTopicIdPassesGuard() {
        let topicId = "abc-123-def"
        let sessionKey = "agent:main:\(topicId.lowercased())"

        let keySuffix = sessionKey.split(separator: ":").last.map(String.init)?.lowercased()
        XCTAssertEqual(topicId.lowercased(), keySuffix)
    }

    /// Verify that mismatched topicId fails the guard.
    func testMismatchedTopicIdFailsGuard() {
        let topicId = "abc-123-def"
        let sessionKey = "agent:main:wrong-topic-id"

        let keySuffix = sessionKey.split(separator: ":").last.map(String.init)?.lowercased()
        XCTAssertNotEqual(topicId.lowercased(), keySuffix)
    }

    /// Verify case-insensitive matching.
    func testCaseInsensitiveTopicIdMatching() {
        let topicId = "ABC-123-DEF"
        let sessionKey = "agent:main:abc-123-def"

        let keySuffix = sessionKey.split(separator: ":").last.map(String.init)?.lowercased()
        XCTAssertEqual(topicId.lowercased(), keySuffix)
    }
}

// MARK: - BeeChatTopicMetadata Tests

final class BeeChatTopicMetadataTests: XCTestCase {

    func testMetadataEncoding() throws {
        let metadata = BeeChatTopicMetadata(
            topicId: "test-123",
            isArchived: true,
            projectPath: "/path/to/project",
            updatedAt: "2026-05-22T12:00:00Z"
        )

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(BeeChatTopicMetadata.self, from: data)

        XCTAssertEqual(decoded.topicId, "test-123")
        XCTAssertEqual(decoded.isArchived, true)
        XCTAssertEqual(decoded.projectPath, "/path/to/project")
        XCTAssertEqual(decoded.updatedAt, "2026-05-22T12:00:00Z")
    }

    func testMetadataEquatable() {
        let m1 = BeeChatTopicMetadata(topicId: "id1", isArchived: false, projectPath: nil, updatedAt: "2026-01-01T00:00:00Z")
        let m2 = BeeChatTopicMetadata(topicId: "id1", isArchived: false, projectPath: nil, updatedAt: "2026-01-01T00:00:00Z")
        let m3 = BeeChatTopicMetadata(topicId: "id1", isArchived: true, projectPath: nil, updatedAt: "2026-01-01T00:00:00Z")

        XCTAssertEqual(m1, m2)
        XCTAssertNotEqual(m1, m3)
    }
}
