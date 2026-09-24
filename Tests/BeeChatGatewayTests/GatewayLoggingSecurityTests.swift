import Foundation
import XCTest
import BeeChatLogging
@testable import BeeChatGateway

final class GatewayLoggingSecurityTests: XCTestCase {
    func testG4ChallengeHandshakeAndReconnectNeverExposeCredentials() async throws {
        let token = "SENTINEL-GATEWAY-TOKEN-7E943A"
        let deviceToken = "SENTINEL-DEVICE-TOKEN-C182BD"
        let transport = ReconnectingFakeTransport()
        let capture = LockedStrings()
        let printCapture = LockedStrings()
        let osLogCapture = LockedStrings()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("beechat-g4-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fileLog = BoundedFileLog(
            configuration: .init(isEnabled: true, homeDirectory: home),
            defaultFilename: "gateway-security.log"
        )
        // Create the fixture file before reconnecting receive loops can emit diagnostics.
        try fileLog.write(Data())
        let sinks = GatewayDiagnosticSinks(
            file: { data in
                capture.append(String(decoding: data, as: UTF8.self))
                try? fileLog.write(data)
            },
            print: { printCapture.append($0) },
            unifiedLog: { osLogCapture.append($0) }
        )
        let client = GatewayClient(
            config: .init(
                url: "ws://127.0.0.1:18789",
                token: token,
                deviceToken: deviceToken,
                requestTimeout: 5,
                maxRetries: 2,
                baseRetryDelay: 0,
                maxRetryDelay: 0
            ),
            tokenStore: InMemoryTokenStore(deviceToken: deviceToken),
            transport: transport,
            diagnosticSinks: sinks
        )

        try await client.connect()
        for _ in 0..<500 where transport.sentMessages.count < 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await client.disconnect()

        XCTAssertGreaterThanOrEqual(transport.connectionCount, 2, "fixture did not force reconnect")
        XCTAssertGreaterThanOrEqual(transport.sentMessages.count, 2, "fixture did not handshake after reconnect")
        let credentialFrames = transport.sentMessages.filter {
            $0.contains(token) && $0.contains(deviceToken)
        }
        XCTAssertGreaterThanOrEqual(credentialFrames.count, 2,
                                    "fixture did not exercise credential-bearing handshakes around reconnect")
        let prefixesExerciseLeakWindow = credentialFrames.allSatisfy { frame in
            let loggedPrefix = String(frame.prefix(500))
            return loggedPrefix.contains(token) && loggedPrefix.contains(deviceToken)
        }
        guard prefixesExerciseLeakWindow else {
            XCTFail("fixture credentials must be inside the exact prefix(500) handshake leak window")
            return
        }

        let fileCapture = capture.values.joined()
        let diskCapture = (try? String(contentsOf: fileLog.url, encoding: .utf8)) ?? ""
        for output in [fileCapture, diskCapture, printCapture.values.joined(), osLogCapture.values.joined()] {
            XCTAssertFalse(output.contains(token), "gateway token escaped a diagnostic sink")
            XCTAssertFalse(output.contains(deviceToken), "device token escaped a diagnostic sink")
        }
    }
}

private final class ReconnectingFakeTransport: GatewayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveIndex = 0
    private var _connectionCount = 0
    private var _sentMessages: [String] = []
    var onClose: ((Int, String?) -> Void)?

    var connectionCount: Int { lock.withLock { _connectionCount } }
    var sentMessages: [String] { lock.withLock { _sentMessages } }

    func connect(url: URL, origin: String?) {
        lock.withLock { _connectionCount += 1 }
    }

    func send(_ message: String) async throws {
        lock.withLock { _sentMessages.append(message) }
    }

    func close(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let index = lock.withLock { () -> Int in
            defer { receiveIndex += 1 }
            return receiveIndex
        }
        switch index {
        case 0, 3:
            return .string(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"test-nonce"}}"#)
        case 1, 4:
            return .string(#"{"type":"res","id":"handshake","ok":true,"payload":{"type":"hello-ok","protocol":4,"server":{"version":"test"},"features":{},"policy":{"maxPayload":1048576},"auth":{}}}"#)
        case 2:
            throw NSError(domain: "ReconnectingFakeTransport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "forced close"])
        default:
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw CancellationError()
        }
    }

    func disconnect() {}
}

private final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private var deviceToken: String?
    init(deviceToken: String?) { self.deviceToken = deviceToken }
    func getGatewayToken() throws -> String? { nil }
    func setGatewayToken(_ token: String) throws {}
    func getDeviceToken() throws -> String? { deviceToken }
    func setDeviceToken(_ token: String) throws { deviceToken = token }
    func deleteAll() throws { deviceToken = nil }
}

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}
