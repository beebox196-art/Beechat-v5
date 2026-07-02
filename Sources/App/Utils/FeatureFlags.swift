import Foundation

/// Feature flags for BeeChat. Persisted in UserDefaults so they survive app restarts.
/// Flags default to `false` (disabled) — each new flag must be explicitly enabled.
@MainActor
@Observable
final class FeatureFlags {
    static let shared = FeatureFlags()

    /// When enabled, streaming assistant messages are rendered in a WebView
    /// using MessageTemplate.html for rich formatting (bold, code, links, etc.).
    /// When disabled (default), streaming uses plain Text as before.
    var htmlRenderingEnabled: Bool {
        didSet { UserDefaults.standard.set(htmlRenderingEnabled, forKey: Keys.htmlRendering) }
    }

    private enum Keys {
        static let htmlRendering = "BeeChat.feature.htmlRendering"
    }

    private init() {
        self.htmlRenderingEnabled = UserDefaults.standard.bool(forKey: Keys.htmlRendering)
    }
}