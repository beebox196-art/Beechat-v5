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

    func startup() {
        Task {
            do {
                // Open database
                let dbManager = DatabaseManager.shared
                let dbPath = defaultDatabasePath()
                try dbManager.openDatabase(at: dbPath)

                // Create persistence store
                let persistenceStore = BeeChatPersistenceStore(dbManager: dbManager)

                // Load gateway config from openclaw.json
                let gatewayConfig = try loadGatewayConfig()
                let tokenStore = KeychainTokenStore()
                let gatewayClient = GatewayClient(config: gatewayConfig, tokenStore: tokenStore)

                // Create SyncBridge
                let config = SyncBridgeConfiguration(
                    gatewayClient: gatewayClient,
                    persistenceStore: persistenceStore
                )
                let bridge = SyncBridge(config: config)

                self.syncBridge = bridge

                // Start SyncBridge (connects to gateway, fetches sessions, starts event loop)
                try await bridge.start()
                self.isReady = true
                self.connectionState = .connected

                print("[AppState] BeeChat started successfully")
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

    /// Load gateway configuration from ~/.openclaw/openclaw.json
    /// Falls back to localhost:18789 with token from keychain if config is missing
    private func loadGatewayConfig() throws -> GatewayClient.Configuration {
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
        
        let configData = try Data(contentsOf: configPath)
        guard let json = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String else {
            throw AppStateError.missingConfig("Could not extract gateway.auth.token from openclaw.json")
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
    
    var errorDescription: String? {
        switch self {
        case .missingConfig(let msg): return msg
        }
    }
}