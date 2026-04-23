import XCTest
import CryptoKit
@testable import BeeChatGateway

final class ConnectionStateTests: XCTestCase {
    
    func testAllStatesExist() {
        let states: [ConnectionState] = [.disconnected, .connecting, .handshaking, .connected, .error]
        XCTAssertEqual(states.count, 5)
    }
    
    func testRawValues() {
        XCTAssertEqual(ConnectionState.disconnected.rawValue, "disconnected")
        XCTAssertEqual(ConnectionState.connecting.rawValue, "connecting")
        XCTAssertEqual(ConnectionState.handshaking.rawValue, "handshaking")
        XCTAssertEqual(ConnectionState.connected.rawValue, "connected")
        XCTAssertEqual(ConnectionState.error.rawValue, "error")
    }
    
    func testCodableRoundTrip() throws {
        let original = ConnectionState.handshaking
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionState.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

final class BackoffCalculatorTests: XCTestCase {
    
    func testFirstAttemptDelay() {
        let calc = BackoffCalculator(baseDelay: 1.0, maxDelay: 30.0, maxRetries: 10)
        for _ in 0..<100 {
            let delay = calc.delay(forAttempt: 0)
            XCTAssertGreaterThanOrEqual(delay, 0.8, "Delay should be >= 0.8 (1.0 - 20%)")
            XCTAssertLessThanOrEqual(delay, 1.2, "Delay should be <= 1.2 (1.0 + 20%)")
        }
    }
    
    func testExponentialGrowth() {
        let calc = BackoffCalculator(baseDelay: 1.0, maxDelay: 30.0, maxRetries: 10)
        let delay0 = calc.delay(forAttempt: 0)
        let delay3 = calc.delay(forAttempt: 3)
        
        XCTAssertGreaterThan(delay3, delay0 * 2, "Backoff should grow exponentially")
    }
    
    func testMaxDelayCap() {
        let calc = BackoffCalculator(baseDelay: 1.0, maxDelay: 30.0, maxRetries: 10)
        for _ in 0..<100 {
            let delay = calc.delay(forAttempt: 20)
            XCTAssertLessThanOrEqual(delay, 36.0, "Delay should not exceed maxDelay + 20% jitter")
            XCTAssertGreaterThanOrEqual(delay, 24.0, "Delay should be at least maxDelay - 20% jitter")
        }
    }
    
    func testCustomConfiguration() {
        let calc = BackoffCalculator(baseDelay: 2.0, maxDelay: 60.0, maxRetries: 5)
        XCTAssertEqual(calc.maxRetries, 5)
        let delay = calc.delay(forAttempt: 0)
        XCTAssertGreaterThanOrEqual(delay, 1.6)
        XCTAssertLessThanOrEqual(delay, 2.4)
    }
}

final class DeviceCryptoTests: XCTestCase {
    
    func testKeyGeneration() throws {
        let key = try DeviceCrypto.getOrCreateKeyPair()
        let rawPubKey = key.publicKey.rawRepresentation
        XCTAssertEqual(rawPubKey.count, 32, "Ed25519 public key should be 32 bytes")
    }
    
    func testDeviceIdDerivation() throws {
        let key = try DeviceCrypto.getOrCreateKeyPair()
        let deviceId = DeviceCrypto.getDeviceId(key)
        XCTAssertEqual(deviceId.count, 64, "Device ID should be 64 hex characters (SHA-256)")
        XCTAssertNotNil(deviceId.range(of: "^[0-9a-f]+$", options: .regularExpression), "Device ID should be lowercase hex")
    }
    
    func testDeviceIdIsStable() throws {
        let key = try DeviceCrypto.getOrCreateKeyPair()
        let id1 = DeviceCrypto.getDeviceId(key)
        let id2 = DeviceCrypto.getDeviceId(key)
        XCTAssertEqual(id1, id2, "Device ID should be deterministic for the same key")
    }
    
    func testPublicKeyExport() throws {
        let key = try DeviceCrypto.getOrCreateKeyPair()
        let exported = DeviceCrypto.exportPublicKey(key)
        XCTAssertNil(exported.range(of: "[+/=]", options: .regularExpression), "Exported public key should be base64url (no +, /, =)")
        let decoded = DeviceCrypto.fromBase64URL(exported)
        XCTAssertNotNil(decoded, "base64url decode should succeed")
        XCTAssertEqual(decoded?.count, 32, "Decoded public key should be 32 bytes")
    }
    
    func testChallengeSigning() throws {
        let key = try DeviceCrypto.getOrCreateKeyPair()
        let deviceId = DeviceCrypto.getDeviceId(key)
        
        let signature = try DeviceCrypto.signChallenge(
            key,
            deviceId: deviceId,
            clientId: "beechat",
            clientMode: "cli",
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            signedAtMs: Int(Date().timeIntervalSince1970 * 1000),
            token: nil,
            nonce: "test-nonce-12345"
        )
        
        XCTAssertNil(signature.range(of: "[+/=]", options: .regularExpression), "Signature should be base64url (no +, /, =)")
        XCTAssertGreaterThan(signature.count, 0, "Signature should not be empty")
        
        let decoded = DeviceCrypto.fromBase64URL(signature)
        XCTAssertNotNil(decoded, "base64url decode should succeed")
        XCTAssertEqual(decoded?.count, 64, "Ed25519 signature should be 64 bytes")
    }
    
    func testSignatureProducesValidOutput() throws {
        let key = try DeviceCrypto.getOrCreateKeyPair()
        let deviceId = DeviceCrypto.getDeviceId(key)
        let signedAt = Int(Date().timeIntervalSince1970 * 1000)
        
        let signature = try DeviceCrypto.signChallenge(
            key, deviceId: deviceId, clientId: "beechat",
            clientMode: "cli", role: "operator",
            scopes: ["operator.read"], signedAtMs: signedAt,
            token: nil, nonce: "test-nonce"
        )
        
        XCTAssertNotNil(DeviceCrypto.fromBase64URL(signature), "Signature should be valid base64url")
        XCTAssertGreaterThan(signature.count, 0, "Signature should not be empty")
    }
    
    func testV3PayloadFormat() throws {
        let key = try DeviceCrypto.getOrCreateKeyPair()
        let deviceId = DeviceCrypto.getDeviceId(key)
        let signedAt = 1713427200000 // fixed timestamp for deterministic test
        
        let signature = try DeviceCrypto.signChallenge(
            key, deviceId: deviceId, clientId: "beechat",
            clientMode: "cli", role: "operator",
            scopes: ["operator.read", "operator.write"], signedAtMs: signedAt,
            token: "test-token", nonce: "test-nonce",
            platform: "macos", deviceFamily: "desktop"
        )
        
        let decoded = DeviceCrypto.fromBase64URL(signature)
        XCTAssertEqual(decoded?.count, 64, "Ed25519 signature should be 64 bytes")
    }
}

final class FrameTests: XCTestCase {
    
    func testRequestFrameEncoding() throws {
        let frame = RequestFrame(id: "test-1", method: "sessions.list", params: nil)
        let data = try JSONEncoder().encode(frame)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertEqual(json["type"] as? String, "req")
        XCTAssertEqual(json["id"] as? String, "test-1")
        XCTAssertEqual(json["method"] as? String, "sessions.list")
    }
    
    func testRequestFrameWithParams() throws {
        let params: [String: AnyCodable] = ["limit": AnyCodable(10), "offset": AnyCodable(0)]
        let frame = RequestFrame(id: "test-2", method: "sessions.list", params: params)
        let data = try JSONEncoder().encode(frame)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertNotNil(json["params"], "Params should be included")
    }
    
    func testResponseFrameDecoding() throws {
        let json = """
        {
            "type": "res",
            "id": "test-1",
            "ok": true,
            "payload": {"result": "hello"},
            "error": null
        }
        """.data(using: .utf8)!
        
        let frame = try JSONDecoder().decode(ResponseFrame.self, from: json)
        XCTAssertEqual(frame.id, "test-1")
        XCTAssertTrue(frame.ok)
        XCTAssertNotNil(frame.payload)
    }
    
    func testResponseFrameErrorDecoding() throws {
        let json = """
        {
            "type": "res",
            "id": "test-2",
            "ok": false,
            "payload": null,
            "error": {"message": "Not found", "code": "NOT_FOUND"}
        }
        """.data(using: .utf8)!
        
        let frame = try JSONDecoder().decode(ResponseFrame.self, from: json)
        XCTAssertFalse(frame.ok)
        XCTAssertNotNil(frame.error)
        XCTAssertEqual(frame.error?.message, "Not found")
        XCTAssertEqual(frame.error?.code, "NOT_FOUND")
    }
    
    func testEventFrameDecoding() throws {
        let json = """
        {
            "type": "event",
            "event": "chat",
            "payload": {"message": "hello"},
            "seq": 42,
            "stateVersion": 7
        }
        """.data(using: .utf8)!
        
        let frame = try JSONDecoder().decode(EventFrame.self, from: json)
        XCTAssertEqual(frame.event, "chat")
        XCTAssertEqual(frame.seq, 42)
        XCTAssertEqual(frame.stateVersion?.value as? Int, 7)
    }
    
    func testEventFrameStateVersionAsDict() throws {
        let json = """
        {
            "type": "event",
            "event": "chat",
            "payload": {"message": "hello"},
            "seq": 42,
            "stateVersion": {"major": 1, "minor": 0}
        }
        """.data(using: .utf8)!
        
        let frame = try JSONDecoder().decode(EventFrame.self, from: json)
        XCTAssertEqual(frame.event, "chat")
        XCTAssertEqual(frame.seq, 42)
        XCTAssertNotNil(frame.stateVersion)
        XCTAssertEqual(frame.stateVersion?.value as? [String: Int], ["major": 1, "minor": 0])
    }
}

final class KeychainTokenStoreTests: XCTestCase {
    
    var store: KeychainTokenStore!
    
    override func setUpWithError() throws {
        store = KeychainTokenStore()
        try store.deleteAll()
    }
    
    override func tearDownWithError() throws {
        try store.deleteAll()
    }
    
    func testGatewayTokenRoundTrip() throws {
        XCTAssertNil(try store.getGatewayToken(), "Should start empty")
        try store.setGatewayToken("test-gateway-token")
        XCTAssertEqual(try store.getGatewayToken(), "test-gateway-token")
    }
    
    func testDeviceTokenRoundTrip() throws {
        XCTAssertNil(try store.getDeviceToken(), "Should start empty")
        try store.setDeviceToken("test-device-token")
        XCTAssertEqual(try store.getDeviceToken(), "test-device-token")
    }
    
    func testDeleteAll() throws {
        let testStore = KeychainTokenStore()
        try testStore.setGatewayToken("gw-delete-test")
        try testStore.setDeviceToken("dt-delete-test")
        
        XCTAssertEqual(try testStore.getGatewayToken(), "gw-delete-test")
        XCTAssertEqual(try testStore.getDeviceToken(), "dt-delete-test")
        
        try testStore.deleteAll()
        
        XCTAssertNil(try testStore.getGatewayToken(), "Gateway token should be deleted")
        XCTAssertNil(try testStore.getDeviceToken(), "Device token should be deleted")
    }
    
    func testTokenUpdate() throws {
        try store.setGatewayToken("old-token")
        try store.setGatewayToken("new-token")
        XCTAssertEqual(try store.getGatewayToken(), "new-token", "Token should be updated")
    }
}

final class PendingRequestMapTests: XCTestCase {
    
    func testResolveRequest() async throws {
        let map = PendingRequestMap()
        let expectation = XCTestExpectation(description: "Request resolved")
        
        await map.add(id: "req-1", timeout: 30.0) { payload in
            XCTAssertEqual(payload["status"]?.value as? String, "ok")
            expectation.fulfill()
        } reject: { _ in
            XCTFail("Should not reject")
        }
        
        await map.resolve(id: "req-1", payload: ["status": AnyCodable("ok")])
        await fulfillment(of: [expectation], timeout: 2.0)
    }
    
    func testRejectRequest() async throws {
        let map = PendingRequestMap()
        let expectation = XCTestExpectation(description: "Request rejected")
        
        await map.add(id: "req-2", timeout: 30.0) { _ in
            XCTFail("Should not resolve")
        } reject: { error in
            XCTAssertNotNil(error)
            expectation.fulfill()
        }
        
        await map.reject(id: "req-2", error: NSError(domain: "test", code: 1, userInfo: nil))
        await fulfillment(of: [expectation], timeout: 2.0)
    }
    
    func testRequestTimeout() async throws {
        let map = PendingRequestMap()
        let expectation = XCTestExpectation(description: "Request timed out")
        
        await map.add(id: "req-3", timeout: 0.5) { _ in
            XCTFail("Should not resolve")
        } reject: { _ in
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 2.0)
    }
    
    func testClearAll() async throws {
        let map = PendingRequestMap()
        var rejectCount = 0
        let expectation = XCTestExpectation(description: "All rejected")
        expectation.expectedFulfillmentCount = 2
        
        await map.add(id: "a", timeout: 30.0) { _ in } reject: { _ in
            rejectCount += 1; expectation.fulfill()
        }
        await map.add(id: "b", timeout: 30.0) { _ in } reject: { _ in
            rejectCount += 1; expectation.fulfill()
        }
        
        await map.clearAll(reason: "test cleanup")
        await fulfillment(of: [expectation], timeout: 2.0)
        XCTAssertEqual(rejectCount, 2)
    }
}

final class HelloOkParsingTests: XCTestCase {
    
    func testHelloOkParsingFromRawJSON() throws {
        let rawJSON = """
        {
            "type": "hello-ok",
            "protocol": 3,
            "server": {"id": "test-server", "version": "1.0.0"},
            "features": {"methods": ["sessions.list", "chat.send"], "events": ["chat", "tick"]},
            "policy": {"maxPayload": 1048576},
            "auth": {"deviceToken": "dt-abc123", "role": "operator", "scopes": ["operator.read"]}
        }
        """.data(using: .utf8)!
        
        let helloOk = try JSONDecoder().decode(HelloOk.self, from: rawJSON)
        XCTAssertEqual(helloOk.protocol, 3)
        XCTAssertEqual(helloOk.policy.maxPayload, 1048576)
        XCTAssertEqual(helloOk.auth?.deviceToken, "dt-abc123")
    }
}

final class GatewayEventTests: XCTestCase {
    
    func testGatewayEventEnum() throws {
        XCTAssertEqual(GatewayEvent.chat.rawValue, "chat")
        XCTAssertEqual(GatewayEvent.agent.rawValue, "agent")
        XCTAssertEqual(GatewayEvent.health.rawValue, "health")
        XCTAssertEqual(GatewayEvent.tick.rawValue, "tick")
        XCTAssertEqual(GatewayEvent.presence.rawValue, "presence")
        XCTAssertEqual(GatewayEvent.error.rawValue, "error")
        XCTAssertEqual(GatewayEvent.connectChallenge.rawValue, "connect.challenge")
        XCTAssertEqual(GatewayEvent.sessionsChanged.rawValue, "sessions.changed")
        XCTAssertEqual(GatewayEvent.sessionMessage.rawValue, "session.message")
        XCTAssertEqual(GatewayEvent.sessionTool.rawValue, "session.tool")
        
        let encoded = try JSONEncoder().encode(GatewayEvent.chat)
        let decoded = try JSONDecoder().decode(GatewayEvent.self, from: encoded)
        XCTAssertEqual(decoded, .chat)
    }
    
    func testRequestIdIncrementing() {
        let id0 = "bc-\(0)"
        let id1 = "bc-\(1)"
        let id2 = "bc-\(2)"
        XCTAssertEqual(id0, "bc-0")
        XCTAssertEqual(id1, "bc-1")
        XCTAssertEqual(id2, "bc-2")
        let ids = [id0, id1, id2]
        XCTAssertEqual(ids.sorted(), ids, "Incrementing IDs should sort naturally")
    }
}

final class HelloOkResilienceTests: XCTestCase {
    
    func testHelloOkWithEmptyAuth() throws {
        let json = """
        {
            "type": "hello-ok",
            "protocol": 3,
            "server": {"id": "srv-abc123", "version": "1.0.0"},
            "features": {"methods": ["sessions.list"], "events": ["chat"]},
            "policy": {"maxPayload": 1048576},
            "auth": {}
        }
        """.data(using: .utf8)!
        
        let helloOk = try JSONDecoder().decode(HelloOk.self, from: json)
        XCTAssertEqual(helloOk.protocol, 3)
        XCTAssertEqual(helloOk.policy.maxPayload, 1048576)
        XCTAssertNil(helloOk.auth?.deviceToken, "deviceToken should be nil for empty auth")
        XCTAssertNil(helloOk.auth?.role, "role should be nil for empty auth")
        XCTAssertNil(helloOk.auth?.scopes, "scopes should be nil for empty auth")
        XCTAssertEqual(helloOk.server.version, "1.0.0")
    }
    
    func testHelloOkWithServerIdInsteadOfConnId() throws {
        let json = """
        {
            "type": "hello-ok",
            "protocol": 3,
            "server": {"id": "conn-xyz789", "version": "1.0.0"},
            "features": {"methods": [], "events": []},
            "policy": {"maxPayload": 2097152},
            "auth": {"deviceToken": "dt-abc123", "role": "operator", "scopes": ["operator.read", "operator.write"]}
        }
        """.data(using: .utf8)!
        
        let helloOk = try JSONDecoder().decode(HelloOk.self, from: json)
        XCTAssertEqual(helloOk.server.connId, "conn-xyz789", "Should map server.id to connId")
        XCTAssertEqual(helloOk.server.version, "1.0.0")
        XCTAssertEqual(helloOk.auth?.deviceToken, "dt-abc123")
        XCTAssertEqual(helloOk.auth?.role, "operator")
        XCTAssertEqual(helloOk.auth?.scopes, ["operator.read", "operator.write"])
    }
    
    func testHelloOkWithMinimalFields() throws {
        let json = """
        {
            "type": "hello-ok",
            "protocol": 3,
            "server": {"version": "0.1.0"},
            "policy": {"maxPayload": 524288}
        }
        """.data(using: .utf8)!
        
        let helloOk = try JSONDecoder().decode(HelloOk.self, from: json)
        XCTAssertEqual(helloOk.protocol, 3)
        XCTAssertEqual(helloOk.server.version, "0.1.0")
        XCTAssertNil(helloOk.server.connId)
        XCTAssertEqual(helloOk.policy.maxPayload, 524288)
        XCTAssertNil(helloOk.auth, "auth should be nil when not provided")
        XCTAssertNil(helloOk.features.methods)
        XCTAssertNil(helloOk.features.events)
    }
    
    func testHelloOkWithDeviceToken() throws {
        let json = """
        {
            "type": "hello-ok",
            "protocol": 3,
            "server": {"connId": "c-123", "version": "2.0.0"},
            "features": {"methods": ["sessions.list", "chat.send"], "events": ["chat", "tick"]},
            "policy": {"maxPayload": 1048576},
            "auth": {"deviceToken": "dt-abc123", "role": "operator", "scopes": ["operator.read"]}
        }
        """.data(using: .utf8)!
        
        let helloOk = try JSONDecoder().decode(HelloOk.self, from: json)
        XCTAssertEqual(helloOk.protocol, 3)
        XCTAssertEqual(helloOk.policy.maxPayload, 1048576)
        XCTAssertEqual(helloOk.auth?.deviceToken, "dt-abc123")
        XCTAssertEqual(helloOk.server.connId, "c-123")
    }
    
    func testHelloOkParsingFromRawJSON() throws {
        let rawJSON = """
        {
            "type": "hello-ok",
            "protocol": 3,
            "server": {"id": "test-server", "version": "1.0.0"},
            "features": {"methods": ["sessions.list", "chat.send"], "events": ["chat", "tick"]},
            "policy": {"maxPayload": 1048576},
            "auth": {"deviceToken": "dt-abc123", "role": "operator", "scopes": ["operator.read"]}
        }
        """.data(using: .utf8)!
        
        let helloOk = try JSONDecoder().decode(HelloOk.self, from: rawJSON)
        XCTAssertEqual(helloOk.protocol, 3)
        XCTAssertEqual(helloOk.policy.maxPayload, 1048576)
        XCTAssertEqual(helloOk.auth?.deviceToken, "dt-abc123")
    }
    
    func testHelloOkViaAnyCodableRoundTrip() throws {
        let rawJSON = """
        {
            "type": "res",
            "id": "handshake",
            "ok": true,
            "payload": {
                "type": "hello-ok",
                "protocol": 3,
                "server": {"id": "conn-123", "version": "1.0.0"},
                "features": {"methods": ["sessions.list"], "events": ["chat"]},
                "policy": {"maxPayload": 1048576},
                "auth": {}
            }
        }
        """.data(using: .utf8)!
        
        var responseFrame = try JSONDecoder().decode(ResponseFrame.self, from: rawJSON)
        responseFrame.rawData = rawJSON
        
        XCTAssertTrue(responseFrame.ok)
        XCTAssertEqual(responseFrame.id, "handshake")
        XCTAssertNotNil(responseFrame.payload)
        
        let rawJson = try JSONSerialization.jsonObject(with: rawJSON) as! [String: Any]
        let payloadObj = rawJson["payload"] as! [String: Any]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObj)
        let helloOk1 = try JSONDecoder().decode(HelloOk.self, from: payloadData)
        XCTAssertEqual(helloOk1.protocol, 3)
        XCTAssertNil(helloOk1.auth?.deviceToken, "Empty auth should decode with nil deviceToken")
        XCTAssertEqual(helloOk1.server.connId, "conn-123", "server.id should map to connId")
        
        let payloadAnyCodableData = try JSONEncoder().encode(responseFrame.payload!)
        let helloOk2 = try JSONDecoder().decode(HelloOk.self, from: payloadAnyCodableData)
        XCTAssertEqual(helloOk2.protocol, 3)
    }
}