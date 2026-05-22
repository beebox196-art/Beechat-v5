import XCTest
@testable import BeeChatSyncBridge
@testable import BeeChatGateway

final class SessionInfoPluginExtensionsTests: XCTestCase {

    // MARK: - SessionInfo.pluginExtensions decoding

    func testSessionInfoWithoutPluginExtensions() throws {
        // Gateway response that does NOT include pluginExtensions — must decode with nil
        let json = """
        {
            "key": "agent:main:abc123",
            "label": "My Topic",
            "channel": "webchat",
            "model": "gpt-4",
            "totalTokens": 500,
            "lastMessageAt": "2026-05-22T10:00:00Z",
            "agentId": "main",
            "spawnedBy": null
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertEqual(session.key, "agent:main:abc123")
        XCTAssertEqual(session.label, "My Topic")
        XCTAssertNil(session.pluginExtensions)
        XCTAssertNil(session.beechatMetadata)
    }

    func testSessionInfoWithEmptyPluginExtensions() throws {
        let json = """
        {
            "key": "agent:main:abc123",
            "label": "Test",
            "pluginExtensions": {}
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertNotNil(session.pluginExtensions)
        XCTAssertTrue(session.pluginExtensions!.isEmpty)
        XCTAssertNil(session.beechatMetadata)
    }

    func testSessionInfoWithPluginExtensionsButNoBeechat() throws {
        let json = """
        {
            "key": "agent:main:abc123",
            "label": "Test",
            "pluginExtensions": {
                "otherplugin": {
                    "somedata": "hello"
                }
            }
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertNotNil(session.pluginExtensions)
        XCTAssertNil(session.pluginExtensions?["beechat"])
        XCTAssertNil(session.beechatMetadata)
    }

    func testSessionInfoWithBeechatPluginExtensions() throws {
        let json = """
        {
            "key": "agent:main:abc123",
            "label": "My Topic",
            "pluginExtensions": {
                "beechat": {
                    "metadata": {
                        "topicId": "abc123",
                        "isArchived": false,
                        "projectPath": "/Users/test/project",
                        "updatedAt": "2026-05-22T10:00:00Z"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertNotNil(session.pluginExtensions)
        XCTAssertNotNil(session.pluginExtensions?["beechat"])
        XCTAssertNotNil(session.pluginExtensions?["beechat"]?["metadata"])

        // Test beechatMetadata computed property
        let meta = session.beechatMetadata
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.topicId, "abc123")
        XCTAssertEqual(meta?.isArchived, false)
        XCTAssertEqual(meta?.projectPath, "/Users/test/project")
        XCTAssertEqual(meta?.updatedAt, "2026-05-22T10:00:00Z")
    }

    func testSessionInfoWithArchivedTopic() throws {
        let json = """
        {
            "key": "agent:main:def456",
            "label": "Archived Topic",
            "pluginExtensions": {
                "beechat": {
                    "metadata": {
                        "topicId": "def456",
                        "isArchived": true,
                        "projectPath": null,
                        "updatedAt": "2026-05-22T11:00:00Z"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(SessionInfo.self, from: json)
        let meta = session.beechatMetadata
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.topicId, "def456")
        XCTAssertEqual(meta?.isArchived, true)
        XCTAssertNil(meta?.projectPath)
        XCTAssertEqual(meta?.updatedAt, "2026-05-22T11:00:00Z")
    }

    func testSessionInfoWithBeechatButNoMetadata() throws {
        let json = """
        {
            "key": "agent:main:abc123",
            "label": "Test",
            "pluginExtensions": {
                "beechat": {
                    "otherData": "not metadata"
                }
            }
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertNotNil(session.pluginExtensions)
        XCTAssertNotNil(session.pluginExtensions?["beechat"])
        XCTAssertNil(session.pluginExtensions?["beechat"]?["metadata"])
        XCTAssertNil(session.beechatMetadata)
    }

    // MARK: - Backwards compatibility: existing fields still decode

    func testExistingFieldsStillDecodeWithPluginExtensions() throws {
        let json = """
        {
            "key": "agent:main:abc123",
            "label": "Test Topic",
            "channel": "webchat",
            "model": "gpt-4",
            "totalTokens": 12345,
            "lastMessageAt": "2026-05-22T10:00:00Z",
            "agentId": "main",
            "spawnedBy": "user",
            "pluginExtensions": {
                "beechat": {
                    "metadata": {
                        "topicId": "abc123",
                        "isArchived": false,
                        "updatedAt": "2026-05-22T10:00:00Z"
                    }
                }
            }
        }
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(SessionInfo.self, from: json)
        XCTAssertEqual(session.key, "agent:main:abc123")
        XCTAssertEqual(session.label, "Test Topic")
        XCTAssertEqual(session.channel, "webchat")
        XCTAssertEqual(session.model, "gpt-4")
        XCTAssertEqual(session.totalTokens, 12345)
        XCTAssertEqual(session.lastMessageAt, "2026-05-22T10:00:00Z")
        XCTAssertEqual(session.agentId, "main")
        XCTAssertEqual(session.spawnedBy, "user")
        XCTAssertNotNil(session.pluginExtensions)
        XCTAssertNotNil(session.beechatMetadata)
    }

    // MARK: - BeeChatTopicMetadata direct Codable

    func testBeeChatTopicMetadataDecoding() throws {
        let json = """
        {
            "topicId": "abc-123-def",
            "isArchived": true,
            "projectPath": "/some/path",
            "updatedAt": "2026-05-22T10:00:00Z"
        }
        """.data(using: .utf8)!

        let meta = try JSONDecoder().decode(BeeChatTopicMetadata.self, from: json)
        XCTAssertEqual(meta.topicId, "abc-123-def")
        XCTAssertEqual(meta.isArchived, true)
        XCTAssertEqual(meta.projectPath, "/some/path")
        XCTAssertEqual(meta.updatedAt, "2026-05-22T10:00:00Z")
    }

    func testBeeChatTopicMetadataWithoutProjectPath() throws {
        let json = """
        {
            "topicId": "abc-123-def",
            "isArchived": false,
            "projectPath": null,
            "updatedAt": "2026-05-22T10:00:00Z"
        }
        """.data(using: .utf8)!

        let meta = try JSONDecoder().decode(BeeChatTopicMetadata.self, from: json)
        XCTAssertNil(meta.projectPath)
    }

    func testBeeChatTopicMetadataEncoding() throws {
        let meta = BeeChatTopicMetadata(
            topicId: "abc123",
            isArchived: false,
            projectPath: "/test/path",
            updatedAt: "2026-05-22T10:00:00Z"
        )

        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(BeeChatTopicMetadata.self, from: data)
        XCTAssertEqual(decoded.topicId, "abc123")
        XCTAssertEqual(decoded.isArchived, false)
        XCTAssertEqual(decoded.projectPath, "/test/path")
        XCTAssertEqual(decoded.updatedAt, "2026-05-22T10:00:00Z")
    }

    func testBeeChatTopicMetadataEquality() throws {
        let meta1 = BeeChatTopicMetadata(topicId: "abc", isArchived: false, updatedAt: "2026-01-01T00:00:00Z")
        let meta2 = BeeChatTopicMetadata(topicId: "abc", isArchived: false, updatedAt: "2026-01-01T00:00:00Z")
        let meta3 = BeeChatTopicMetadata(topicId: "def", isArchived: true, updatedAt: "2026-01-01T00:00:00Z")

        XCTAssertEqual(meta1, meta2)
        XCTAssertNotEqual(meta1, meta3)
    }

    // MARK: - sessions.list response with pluginExtensions

    func testSessionsListResponseWithPluginExtensions() throws {
        let json = """
        {
            "sessions": [
                {
                    "key": "agent:main:topic1",
                    "label": "Topic One",
                    "pluginExtensions": {
                        "beechat": {
                            "metadata": {
                                "topicId": "topic1",
                                "isArchived": false,
                                "updatedAt": "2026-05-22T10:00:00Z"
                            }
                        }
                    }
                },
                {
                    "key": "agent:main:topic2",
                    "label": "Topic Two"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(SessionsListResponse.self, from: json)
        XCTAssertEqual(response.sessions.count, 2)

        // First session has pluginExtensions
        let session1 = response.sessions[0]
        XCTAssertNotNil(session1.pluginExtensions)
        XCTAssertNotNil(session1.beechatMetadata)
        XCTAssertEqual(session1.beechatMetadata?.topicId, "topic1")

        // Second session has no pluginExtensions
        let session2 = response.sessions[1]
        XCTAssertNil(session2.pluginExtensions)
        XCTAssertNil(session2.beechatMetadata)
    }
}