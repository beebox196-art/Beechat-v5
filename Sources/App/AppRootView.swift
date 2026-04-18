import SwiftUI
import BeeChatSyncBridge
import BeeChatPersistence
import BeeChatGateway

/// App root view — entry point for the BeeChat window.
/// Sets up the theme environment and wires the main window.
@main
struct BeeChatApp: App {
    @State private var themeManager = ThemeManager()
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(themeManager)
                .environment(appState)
                .onAppear {
                    appState.startup()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Chat") {
                Button("New Topic") { /* TODO: create topic */ }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Next Topic") { /* TODO: cycle right */ }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Topic") { /* TODO: cycle left */ }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
        }
    }
}

/// Application-level state — owns SyncBridge and coordinates startup.
@MainActor
@Observable
final class AppState {
    var syncBridge: SyncBridge?
    var connectionState: ConnectionState = .disconnected
    var isReady = false
    var errorMessage: String?
    var offlineStatus: String?

    func startup() {
        Task {
            do {
                // Open database
                let dbManager = DatabaseManager.shared
                let dbPath = defaultDatabasePath()
                try dbManager.openDatabase(at: dbPath)

                // Create persistence store
                let persistenceStore = BeeChatPersistenceStore(dbManager: dbManager)

                // Try to load gateway config from openclaw.json — surface errors properly
                let configPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".openclaw/openclaw.json")

                if FileManager.default.fileExists(atPath: configPath.path) {
                    // Config file exists — parse it, surface errors if malformed
                    do {
                        let gatewayConfig = try loadGatewayConfig(from: configPath)
                        let tokenStore = KeychainTokenStore()
                        let gatewayClient = GatewayClient(config: gatewayConfig, tokenStore: tokenStore)
                        let config = SyncBridgeConfiguration(
                            gatewayClient: gatewayClient,
                            persistenceStore: persistenceStore
                        )
                        let bridge = SyncBridge(config: config)
                        self.syncBridge = bridge

                        // Mark ready immediately so UI can load local DB
                        self.isReady = true
                        self.connectionState = .disconnected

                        // Try gateway connection (non-blocking)
                        do {
                            try await bridge.start()
                            self.connectionState = .connected
                            print("[AppState] Connected to gateway")
                        } catch {
                            print("[AppState] Gateway unavailable — offline mode: \(error)")
                        }
                    } catch {
                        // Config file exists but is malformed — surface the error
                        self.errorMessage = "Gateway config error: \(error.localizedDescription)"
                        self.isReady = true
                        self.connectionState = .error
                        self.offlineStatus = "Offline — gateway config error"
                        print("[AppState] Malformed gateway config: \(error)")
                    }
                } else {
                    // No config file — run with local DB only (no gateway)
                    print("[AppState] No openclaw.json — local DB mode only")
                    self.isReady = true
                    self.connectionState = .disconnected
                    self.offlineStatus = "Offline — no gateway config found"
                }
            } catch {
                self.errorMessage = error.localizedDescription
                self.connectionState = .error
                print("[AppState] Startup failed: \(error)")
            }
        }
    }

    func shutdown() async {
        if let bridge = syncBridge {
            await bridge.stop()
        }
    }

    // MARK: - Defaults

    private func defaultDatabasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("BeeChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("beechat.sqlite").path
    }

    /// Load gateway configuration from a given config file URL.
    /// Throws descriptive errors if the file is malformed.
    private func loadGatewayConfig(from url: URL) throws -> GatewayClient.Configuration {
        let configData = try Data(contentsOf: url)
        let json: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
                throw AppStateError.malformedConfig("openclaw.json is not a valid JSON object")
            }
            json = parsed
        } catch let error as AppStateError {
            throw error
        } catch {
            throw AppStateError.malformedConfig("openclaw.json is not valid JSON: \(error.localizedDescription)")
        }

        guard let gateway = json["gateway"] as? [String: Any] else {
            throw AppStateError.malformedConfig("Missing 'gateway' key in openclaw.json")
        }

        guard let auth = gateway["auth"] as? [String: Any] else {
            throw AppStateError.malformedConfig("Missing 'gateway.auth' key in openclaw.json")
        }

        guard let token = auth["token"] as? String else {
            throw AppStateError.malformedConfig("Missing 'gateway.auth.token' in openclaw.json")
        }

        // Determine gateway URL — default to localhost:18789 for local development
        let host = gateway["host"] as? String ?? "127.0.0.1"
        let port = gateway["port"] as? Int ?? 18789
        let wsURL = "ws://\(host):\(port)"

        return GatewayClient.Configuration(
            url: wsURL,
            token: token,
            clientMode: "webchat",
            clientInfo: .init(id: "beechat-macos", version: "1.0", platform: "macos", mode: "webchat")
        )
    }
}

enum AppStateError: LocalizedError {
    case missingConfig(String)
    case malformedConfig(String)

    var errorDescription: String? {
        switch self {
        case .missingConfig(let msg): return msg
        case .malformedConfig(let msg): return msg
        }
    }
}