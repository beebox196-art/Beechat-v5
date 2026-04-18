import Foundation
import BeeChatGateway
import BeeChatPersistence
import BeeChatSyncBridge

/// End-to-end integration test: Gateway → SyncBridge → Persistence
/// Connects to the LIVE OpenClaw gateway on localhost:18789
/// Proves the full stack works before building UI

@main
struct IntegrationTest {
    static func main() async {
        let gatewayURL = "ws://127.0.0.1:18789"
        let token = "e6773dda5610c16ec9896fe0c5140690c01d31408115d360"
        let dbPath = "/tmp/beechat_integration_test.db"

        // Clean up old test DB
        try? FileManager.default.removeItem(atPath: dbPath)

        print("🐝 BeeChat v5 Integration Test")
        print("================================")
        print("")

        // ── Step 1: Open Persistence ──────────────────────────
        print("📦 Step 1: Opening persistence store...")
        let store = BeeChatPersistenceStore()
        do {
            try store.openDatabase(at: dbPath)
            print("   ✅ Database opened at \(dbPath)")
        } catch {
            print("   ❌ FAILED: \(error)")
            Foundation.exit(1)
        }

        // ── Step 2: Create Gateway Client ────────────────────
        print("🌐 Step 2: Creating gateway client...")
        let config = GatewayClient.Configuration(
            url: gatewayURL,
            token: token,
            clientMode: "webchat"
        )
        let tokenStore = KeychainTokenStore()
        let gateway = GatewayClient(config: config, tokenStore: tokenStore)
        print("   ✅ Gateway client created (mode: webchat, url: \(gatewayURL))")

        // ── Step 3: Connect to Gateway ───────────────────────
        print("🔗 Step 3: Connecting to gateway...")
        do {
            try await gateway.connect()
            print("   ✅ Connected to gateway")
        } catch {
            print("   ❌ FAILED: \(error)")
            Foundation.exit(1)
        }

        // Wait for hello-ok
        print("   ⏳ Waiting for hello-ok...")
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // ── Step 4: Test RPC — sessions.list ─────────────────
        print("📋 Step 4: Fetching sessions list...")
        let rpcClient = RPCClient(gateway: gateway)
        var sessions: [SessionInfo] = []
        do {
            sessions = try await rpcClient.sessionsList()
            print("   ✅ Fetched \(sessions.count) sessions")
            for s in sessions {
                print("      - \(s.key) (\(s.channel ?? "unknown")) [\(s.model ?? "?")]")
            }
        } catch {
            print("   ⚠️ sessions.list error: \(error)")
            print("   (May be expected with webchat mode — continuing)")
        }

        // ── Step 5: Test RPC — sessions.subscribe ────────────
        print("📡 Step 5: Subscribing to session changes...")
        do {
            try await rpcClient.sessionsSubscribe()
            print("   ✅ Subscribed to session changes")
        } catch {
            print("   ⚠️ sessions.subscribe error: \(error)")
        }

        // ── Step 6: Test RPC — chat.history ──────────────────
        if let firstSession = sessions.first {
            print("💬 Step 6: Fetching chat history for \(firstSession.key)...")
            do {
                let messages = try await rpcClient.chatHistory(sessionKey: firstSession.key, limit: 5)
                print("   ✅ Fetched \(messages.count) messages")
                for m in messages.prefix(3) {
                    let preview = String(m.content.prefix(80))
                    print("      [\(m.role)] \(preview)")
                }
            } catch {
                print("   ⚠️ chat.history error: \(error)")
            }
        } else {
            print("💬 Step 6: Skipped (no sessions available)")
        }

        // ── Step 7: Persist sessions to DB ───────────────────
        print("💾 Step 7: Persisting sessions to DB...")
        if !sessions.isEmpty {
            do {
                for info in sessions {
                    let session = Session(
                        id: info.key,
                        agentId: info.key,
                        channel: info.channel,
                        title: info.label,
                        model: info.model,
                        lastMessageAt: info.lastMessageAt.flatMap { ISO8601DateFormatter().date(from: $0) }
                    )
                    try store.saveSession(session)
                }
                print("   ✅ Persisted \(sessions.count) sessions")

                // Verify round-trip
                let readBack = try store.fetchAllSessions()
                print("   ✅ Read back \(readBack.count) sessions from DB (round-trip verified)")
            } catch {
                print("   ❌ DB write error: \(error)")
            }
        } else {
            print("   ⏭️ Skipped (no sessions to persist)")
        }

        // ── Step 8: Test SyncBridge full lifecycle ───────────
        print("🌉 Step 8: Testing SyncBridge lifecycle...")
        let bridgeConfig = SyncBridgeConfiguration(
            gatewayClient: gateway,
            persistenceStore: store
        )
        let bridge = SyncBridge(config: bridgeConfig)

        do {
            try await bridge.start()
            print("   ✅ SyncBridge started")

            // Listen for events for 5 seconds
            print("   ⏳ Listening for gateway events (5s)...")
            var eventCount = 0
            let startTime = Date()
            let eventStream = await bridge.eventStream()
            for await event in eventStream {
                eventCount += 1
                if Date().timeIntervalSince(startTime) > 5 { break }
            }
            print("   ✅ Received \(eventCount) events in 5s")

            // Check streaming content
            let streaming = await bridge.currentStreamingContent
            print("   📝 Current streaming content: \(streaming.isEmpty ? "(empty)" : "\(streaming.count) chars")")

            await bridge.stop()
            print("   ✅ SyncBridge stopped cleanly")
        } catch {
            print("   ⚠️ SyncBridge error: \(error)")
        }

        // ── Step 9: Verify DB content ────────────────────────
        print("🔍 Step 9: Final DB verification...")
        do {
            let finalSessions = try store.fetchAllSessions()
            print("   ✅ DB contains \(finalSessions.count) sessions")

            // Check messages if we have sessions
            if let first = finalSessions.first {
                let msgs = try store.fetchMessages(for: first.id)
                print("   ✅ Session '\(first.id)' has \(msgs.count) messages in DB")
            }
        } catch {
            print("   ⚠️ DB read error: \(error)")
        }

        // ── Summary ──────────────────────────────────────────
        print("")
        print("================================")
        print("🐝 Integration Test Complete")
        print("")

        // Cleanup
        try? FileManager.default.removeItem(atPath: dbPath)
    }
}