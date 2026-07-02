import SwiftUI

/// Feature flags for BeeChat. Persisted in UserDefaults so they survive app restarts.
/// Flags default to `false` (disabled) — each new flag must be explicitly enabled.
///
/// Injected via SwiftUI environment so views can be tested and previewed without
/// UserDefaults. Use `@Environment(FeatureFlags.self)` in views; the default
/// value (used in previews/tests) reads from UserDefaults as the backing store.
@Observable
final class FeatureFlags {
    /// When enabled, streaming assistant messages are rendered in a WebView
    /// using MessageTemplate.html for rich formatting (bold, code, links, etc.).
    /// When disabled (default), streaming uses plain Text as before.
    var htmlRenderingEnabled: Bool {
        didSet { UserDefaults.standard.set(htmlRenderingEnabled, forKey: Keys.htmlRendering) }
    }

    private enum Keys {
        static let htmlRendering = "BeeChat.feature.htmlRendering"
    }

    /// Creates a FeatureFlags instance. By default, reads persisted values from
    /// UserDefaults. Pass explicit values in previews/tests to override.
    init(htmlRenderingEnabled: Bool? = nil) {
        self.htmlRenderingEnabled = htmlRenderingEnabled
            ?? UserDefaults.standard.bool(forKey: Keys.htmlRendering)
    }
}

// MARK: - SwiftUI Environment Key

private struct FeatureFlagsKey: EnvironmentKey {
    /// Default value reads from UserDefaults — used when no explicit
    /// environment value is injected (e.g. in AppRootView).
    static let defaultValue = FeatureFlags()
}

extension EnvironmentValues {
    /// Access the current FeatureFlags via the SwiftUI environment.
    /// Views should use `@Environment(FeatureFlags.self)` instead of
    /// `FeatureFlags.shared` so they can be tested with injected flags.
    var featureFlags: FeatureFlags {
        get { self[FeatureFlagsKey.self] }
        set { self[FeatureFlagsKey.self] = newValue }
    }
}