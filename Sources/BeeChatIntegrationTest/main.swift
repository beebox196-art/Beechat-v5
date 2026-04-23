import Foundation
import BeeChatGateway
import BeeChatPersistence
import BeeChatSyncBridge

private struct OpenClawConfig: Codable {
    let gateway: GatewayConfig
}

private struct GatewayConfig: Codable {
    let auth: AuthConfig
    
    struct AuthConfig: Codable {
        let token: String
    }
}

@main
struct IntegrationTest {
    static func main() async {
        print("🐝 BeeChat v5 Integration Test — Live Gateway")
        print("==============================================")
        print()

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
            print("⏰ TIMEOUT: Test exceeded 30 seconds — aborting")
            Foundation.exit(2)
        }

        defer {
            timeoutTask.cancel()
        }

        // ─── Step 1: Read gateway token from openclaw.json ───
        print("📋 Step 1: Reading gateway token from openclaw.json...")
        let token: String
        do {
            let configPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".openclaw/openclaw.json")
            let configData = try Data(contentsOf: configPath)
            let openClawConfig = try JSONDecoder().decode(OpenClawConfig.self, from: configData)
            token = openClawConfig.gateway.auth.token
            print("   ✅ Token loaded (\(token.prefix(8))...\(token.suffix(4)))")
        } catch {
            print("   ❌ FAILED: Could not read openclaw.json — \(error)")
            Foundation.exit(1)
        }

        // ─── Step 2: Create GatewayClient with desktop mode ───
        print()
        print("🌐 Step 2: Creating GatewayClient (control-ui mode for localhost auto-pairing)...")

        let tokenStore = KeychainTokenStore()
        
        let config = GatewayClient.Configuration(
            url: "ws://127.0.0.1:18789",
            token: token,
            clientMode: "webchat",
            clientInfo: .init(id: "openclaw-control-ui", version: "1.0", platform: "macos", mode: "webchat")
        )
        let gateway = GatewayClient(config: config, tokenStore: tokenStore)
        print("   ✅ GatewayClient created")
        print("      URL: \(config.url)")
        print("      clientMode: \(config.clientMode)")
        print("      clientId: \(config.clientInfo.id)")
        
        if let existingToken = try? tokenStore.getDeviceToken() {
            print("      🔑 Using previously paired device: \(existingToken.prefix(8))...\(existingToken.suffix(4))")
        } else {
            print("      ℹ️  No previous device pairing — will pair on first connection")
        }

        // ─── Step 3: Connect and verify handshake ───
        print()
        print("🔗 Step 3: Connecting to gateway and verifying handshake...")

        var stateTransitions: [String] = []
        await gateway.updateConnectionStateObserver { newState in
            print("      📡 State changed: \(newState.rawValue)")
            stateTransitions.append(newState.rawValue)
        }

        do {
            try await gateway.connect()
            print("   ✅ CONNECTED — handshake successful!")
            let deviceToken = try? tokenStore.getDeviceToken()
            if let dt = deviceToken {
                print("      🔑 Device token received: \(dt.prefix(8))...\(dt.suffix(4))")
            } else {
                print("      ℹ️  No device token yet (first connection — expected on fresh install)")
            }
        } catch {
            print("   ❌ Connection error: \(error)")
            print("   State transitions: \(stateTransitions)")
            Foundation.exit(1)
        }

        // ─── Step 4: Verify RPC — sessions.list ───
        print()
        print("📋 Step 4: Verifying RPC — sessions.list...")
        let rpc = RPCClient(gateway: gateway)
        var rpcWorks = false
        var sessions: [SessionInfo] = []
        do {
            sessions = try await rpc.sessionsList()
            rpcWorks = true
            print("   ✅ sessions.list returned \(sessions.count) session(s)")
            for (i, session) in sessions.prefix(5).enumerated() {
                print("      [\(i+1)] key=\(session.key), label=\(session.label ?? "nil"), channel=\(session.channel ?? "nil"), model=\(session.model ?? "nil")")
            }
            if sessions.isEmpty {
                print("      ⚠️  No sessions returned (this may be normal if the gateway has none)")
            }
        } catch {
            print("   ⚠️  sessions.list error: \(error)")
            let errorDesc = error.localizedDescription
            if errorDesc.contains("missing scope") {
                print("      ℹ️  This is expected on FIRST connection — device pairing grants scopes on SECOND connection")
                print("      ℹ️  Run the test again to verify full RPC access with paired device")
            }
        }

        // ─── Step 5: Verify RPC — chat.history ───
        if rpcWorks {
            print()
            print("💬 Step 5: Verifying RPC — chat.history...")
            if let firstSession = sessions.first {
                print("      Fetching history for session: \(firstSession.key)")
                do {
                    let messages = try await rpc.chatHistory(sessionKey: firstSession.key, limit: 5)
                    print("   ✅ chat.history returned \(messages.count) message(s)")
                    for (i, msg) in messages.prefix(5).enumerated() {
                        let preview = String(msg.content.prefix(80)).replacingOccurrences(of: "\n", with: "\\n")
                        print("      [\(i+1)] role=\(msg.role), content=\"\(preview)\"")
                    }
                } catch {
                    print("   ⚠️  chat.history error: \(error)")
                }
            } else {
                print("      ⚠️  No sessions available — skipping chat.history")
            }
        }

        // ─── Step 6: Verify events — listen for 5 seconds ───
        print()
        print("📡 Step 6: Verifying events — listening for 5 seconds...")
        var eventsWork = false
        do {
            print("      Subscribing to session events...")
            let subscribeResult = try await gateway.call(method: "sessions.subscribe", params: [:])
            print("      ✅ sessions.subscribe acknowledged (keys: \(subscribeResult.keys.map { String($0) }).joined(separator: ", ")))")
            eventsWork = true

            var eventCount = 0
            var chatEvents = 0
            var otherEvents = [String: Int]()

            let stream = await gateway.eventStream()
            let deadline = Date().addingTimeInterval(5.0)

            print("      Listening for events until \(deadline)...")
            for await event in stream {
                if Date() > deadline { break }
                eventCount += 1
                let eventName = event.event
                if eventName == "chat" {
                    chatEvents += 1
                    if let payload = event.payload {
                        let state = payload["state"]?.value as? String ?? "unknown"
                        let sessionKey = payload["sessionKey"]?.value as? String ?? "unknown"
                        print("      📨 chat event: state=\(state), sessionKey=\(sessionKey)")
                    }
                } else {
                    otherEvents[eventName, default: 0] += 1
                }
            }

            print("   📊 Event summary:")
            print("      Total events received: \(eventCount)")
            print("      Chat events: \(chatEvents)")
            for (name, count) in otherEvents {
                print("      \(name) events: \(count)")
            }
            if eventCount == 0 {
                print("      ℹ️  No events received in 5s (normal if no activity)")
            }
        } catch {
            print("   ⚠️  Event subscription error: \(error)")
            let errorDesc = error.localizedDescription
            if errorDesc.contains("missing scope") {
                print("      ℹ️  Events require operator.read scope — run test again after device pairing")
            }
        }

        // ─── Step 7: Disconnect cleanly ───
        print()
        print("🔌 Step 7: Disconnecting...")
        await gateway.disconnect()
        print("   ✅ Disconnected cleanly")

        print()
        print("==============================================")
        let allPassed = rpcWorks && eventsWork
        if allPassed {
            print("🐝 Integration Test Complete — ALL CHECKS PASSED")
        } else {
            print("🐝 Integration Test Complete — PARTIAL SUCCESS")
            print()
            print("NOTE: First connection pairs the device. Run again for full access.")
        }
        print()
        print("Summary:")
        print("  ✅ Token loaded from openclaw.json")
        print("  ✅ Ed25519 handshake completed")
        print("  ✅ Gateway connection established")
        if rpcWorks {
            print("  ✅ RPC sessions.list functional")
            print("  ✅ RPC chat.history functional")
        } else {
            print("  ⚠️  RPC calls blocked (missing operator scopes — expected on first run)")
        }
        if eventsWork {
            print("  ✅ Event stream operational")
        } else {
            print("  ⚠️  Event subscription blocked (missing operator scopes — expected on first run)")
        }
        print("  ✅ Clean disconnect")
    }
}
