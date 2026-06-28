import XCTest
@testable import BeeChatPersistence

final class SessionFileLocatorTests: XCTestCase {

    // MARK: - agentId(fromSessionKey:)

    func testAgentIdFromSessionKey_main() {
        XCTAssertEqual(SessionFileLocator.agentId(fromSessionKey: "agent:main:telegram:group:-1:topic:2"), "main")
    }

    func testAgentIdFromSessionKey_customAgent() {
        XCTAssertEqual(SessionFileLocator.agentId(fromSessionKey: "agent:q:abc-uuid"), "q")
    }

    func testAgentIdFromSessionKey_noPrefix_returnsNil() {
        XCTAssertNil(SessionFileLocator.agentId(fromSessionKey: "main:telegram:topic:1"))
        XCTAssertNil(SessionFileLocator.agentId(fromSessionKey: ""))
    }

    // MARK: - sessionId(fromSessionKey:)

    func testSessionIdFromSessionKey_uuidWithDashes() {
        let key = "agent:main:491ea8d6-9527-4e71-89b4-d0a06df3f49d"
        XCTAssertEqual(SessionFileLocator.sessionId(fromSessionKey: key), "491ea8d6-9527-4e71-89b4-d0a06df3f49d")
    }

    func testSessionIdFromSessionKey_telegramKey_returnsNil() {
        // Telegram keys have non-UUID suffixes.
        let key = "agent:main:telegram:group:-1003830552971:topic:1"
        XCTAssertNil(SessionFileLocator.sessionId(fromSessionKey: key))
    }

    func testSessionIdFromSessionKey_emptyOrMalformed_returnsNil() {
        XCTAssertNil(SessionFileLocator.sessionId(fromSessionKey: ""))
        XCTAssertNil(SessionFileLocator.sessionId(fromSessionKey: "agent:main"))
        XCTAssertNil(SessionFileLocator.sessionId(fromSessionKey: "agent:main:not-a-uuid"))
    }

    // MARK: - resolve(sessionKey:)

    func testResolve_uuidKey_constructsExpectedPaths() throws {
        let locator = SessionFileLocator()
        let key = "agent:main:491ea8d6-9527-4e71-89b4-d0a06df3f49d"
        guard let location = locator.resolve(sessionKey: key, agentId: "main") else {
            XCTFail("expected location to resolve for UUID key")
            return
        }
        let expectedDir = "\(NSHomeDirectory())/.openclaw/agents/main/sessions"
        XCTAssertEqual(location.trajectoryURL.path, "\(expectedDir)/491ea8d6-9527-4e71-89b4-d0a06df3f49d.trajectory.jsonl")
        XCTAssertEqual(location.lockURL.path, "\(expectedDir)/491ea8d6-9527-4e71-89b4-d0a06df3f49d.jsonl.lock")
        XCTAssertEqual(location.transcriptURL.path, "\(expectedDir)/491ea8d6-9527-4e71-89b4-d0a06df3f49d.jsonl")
    }

    func testResolve_telegramKeyWithoutSessionsJson_returnsNil() throws {
        // Telegram key (no UUID suffix), and no real sessions.json — resolves to nil.
        let locator = SessionFileLocator()
        let key = "agent:nonexistent-agent-for-tests:telegram:group:-1:topic:1"
        let location = locator.resolve(sessionKey: key)
        XCTAssertNil(location, "telegram keys without sessions.json lookup should not resolve")
    }

    func testResolve_defaultAgentIdFallsBackToMain() throws {
        let locator = SessionFileLocator()
        let key = "agent:main:7c24fe58-084f-4fe5-8de2-23e558acbbf1"
        guard let location = locator.resolve(sessionKey: key) else {
            XCTFail("expected location to resolve when agentId derived from key")
            return
        }
        XCTAssertTrue(location.trajectoryURL.path.contains("/.openclaw/agents/main/sessions/"))
    }

    // MARK: - cleanupTrajectoryAndLock

    func testCleanupTrajectoryAndLock_deletesExistingFiles() throws {
        // Set up a sandbox directory under ~/.openclaw/agents so resolve() finds it
        // (the locator uses NSHomeDirectory()/.openclaw/agents).
        // We use a unique agentId so we don't disturb anything real.
        let agentId = "session-file-locator-test-\(UUID().uuidString.prefix(8))"
        let sessionsDir = URL(fileURLWithPath: "\(NSHomeDirectory())/.openclaw/agents/\(agentId)/sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sessionsDir.deletingLastPathComponent())
        }

        // Build a UUID key for this agent
        let sessionId = "11111111-2222-3333-4444-555555555555"
        let key = "agent:\(agentId):\(sessionId)"

        // Create a fake trajectory file
        let trajectoryURL = sessionsDir.appendingPathComponent("\(sessionId).trajectory.jsonl")
        try "fake trajectory data".write(to: trajectoryURL, atomically: true, encoding: .utf8)
        let lockURL = sessionsDir.appendingPathComponent("\(sessionId).jsonl.lock")
        try "lock".write(to: lockURL, atomically: true, encoding: .utf8)

        let locator = SessionFileLocator()
        let deleted = locator.cleanupTrajectoryAndLock(sessionKey: key, agentId: agentId)

        XCTAssertEqual(deleted.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trajectoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testCleanupTrajectoryAndLock_missingFiles_returnsEmpty() throws {
        let locator = SessionFileLocator()
        let key = "agent:definitely-nonexistent-agent-xyz:99999999-9999-9999-9999-999999999999"
        let deleted = locator.cleanupTrajectoryAndLock(sessionKey: key)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testCleanupTrajectoryAndLock_resolvesViaSessionsJson() throws {
        // Simulate a Telegram-style session whose gateway UUID is recorded in
        // sessions.json (since the suffix isn't a UUID).
        let agentId = "session-file-locator-json-test-\(UUID().uuidString.prefix(8))"
        let sessionsDir = URL(fileURLWithPath: "\(NSHomeDirectory())/.openclaw/agents/\(agentId)/sessions")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: sessionsDir.deletingLastPathComponent())
        }

        let sessionKey = "agent:\(agentId):telegram:group:-100:topic:1"
        let sessionUUID = "abcdef01-2345-6789-abcd-ef0123456789"

        // Write sessions.json
        let sessionsJSON = sessionsDir.appendingPathComponent("sessions.json")
        let payload: [String: Any] = [
            sessionKey: ["sessionId": sessionUUID]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: sessionsJSON)

        // Create the trajectory file using the gateway UUID
        let trajectoryURL = sessionsDir.appendingPathComponent("\(sessionUUID).trajectory.jsonl")
        try "trajectory data".write(to: trajectoryURL, atomically: true, encoding: .utf8)

        let locator = SessionFileLocator()
        let deleted = locator.cleanupTrajectoryAndLock(sessionKey: sessionKey)

        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?.path, trajectoryURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trajectoryURL.path))
    }
}
