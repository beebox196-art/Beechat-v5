import Foundation
@testable import BeeChatGateway

/// In-memory `TokenStore` used by tests so they exercise the `TokenStore`
/// contract (round-trip, update, delete) **without touching the real macOS
/// keychain**. Hitting the real keychain in routine `swift test` runs fires a
/// cascade of macOS keychain-access dialogs (one per distinct `SecItem` call,
/// per fresh test process) — see KeychainTokenStoreTests for the gate that
/// keeps the real-keychain path opt-in.
///
/// Thread-safety: a simple lock guards the backing dictionary so the mock is
/// safe to share across the async test surface.
final class InMemoryTokenStore: TokenStore {
    private var tokens: [String: String] = [:]
    private let lock = NSLock()

    func getGatewayToken() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens["gatewayToken"]
    }

    func setGatewayToken(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        tokens["gatewayToken"] = token
    }

    func getDeviceToken() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens["deviceToken"]
    }

    func setDeviceToken(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        tokens["deviceToken"] = token
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        tokens.removeAll()
    }
}
