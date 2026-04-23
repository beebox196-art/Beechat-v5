import SwiftUI
import BeeChatSyncBridge
import BeeChatPersistence
import BeeChatGateway
import os

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
            CommandGroup(after: .pasteboard) {
                Button("Delete Topic") {
                    NotificationCenter.default.post(name: .deleteSelectedTopic, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
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

@MainActor
@Observable
final class AppState {
    var syncBridge: SyncBridge?
    var connectionState: ConnectionState = .disconnected
    var isReady = false
    var errorMessage: String?
    var offlineStatus: String?

    private var hasStarted = false

    init() {}

    func startup() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            do {
                let dbManager = DatabaseManager.shared
                let dbPath = defaultDatabasePath()
                try dbManager.openDatabase(at: dbPath)

                let persistenceStore = BeeChatPersistenceStore(dbManager: dbManager)

                let configPath = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".openclaw/openclaw.json")


                if FileManager.default.fileExists(atPath: configPath.path) {
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

                        self.isReady = true
                        self.connectionState = .disconnected

                        do {
                            try await bridge.start()
                            self.connectionState = .connected

                            Task {
                                let stream = await bridge.connectionStateStream()
                                for await state in stream {
                                    self.connectionState = state
                                }
                            }
                        } catch {
                            self.connectionState = .error
                            self.offlineStatus = "Offline — \(error.localizedDescription)"
                        }
                    } catch {
                        self.errorMessage = "Gateway config error: \(error.localizedDescription)"
                        self.isReady = true
                        self.connectionState = .error
                        self.offlineStatus = "Offline — gateway config error"
                        print("[AppState] Malformed gateway config: \(error)")
                    }
                } else {
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
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            fatalError("Failed to create app support directory: \(error)")
        }
        return dir.appendingPathComponent("beechat.sqlite").path
    }

    private func loadGatewayConfig(from url: URL) throws -> GatewayClient.Configuration {
        let configData = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let openClawConfig = try decoder.decode(OpenClawConfig.self, from: configData)
        
        let gatewayConfig = openClawConfig.gateway
        let token = gatewayConfig.auth.token

        let mode = gatewayConfig.mode ?? "local"
        let host: String
        let port: Int

        if mode == "local" {
            host = "127.0.0.1"
            port = 18789
        } else {
            host = gatewayConfig.host ?? "127.0.0.1"
            port = gatewayConfig.port ?? 18789
        }
        let wsURL = "ws://\(host):\(port)"

        return GatewayClient.Configuration(
            url: wsURL,
            token: token,
            clientMode: "webchat",
            clientInfo: .init(id: "openclaw-control-ui", version: "1.0", platform: "macos", mode: "webchat")
        )
    }
}

/// Typed configuration for openclaw.json gateway section.
struct OpenClawConfig: Codable {
    let gateway: GatewayConfig
}

struct GatewayConfig: Codable {
    let mode: String?
    let host: String?
    let port: Int?
    let auth: AuthConfig
    
    struct AuthConfig: Codable {
        let token: String
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