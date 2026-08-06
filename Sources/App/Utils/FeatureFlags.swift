import SwiftUI

/// Feature flags for BeeChat. Persisted in UserDefaults so they survive app restarts.
/// Flags default to `false` (disabled) — each new flag must be explicitly enabled.
///
/// Injected via SwiftUI environment so views can be tested and previewed without
/// UserDefaults. Use `@Environment(FeatureFlags.self)` in views; the default
/// value (used in previews/tests) reads from UserDefaults as the backing store.
@Observable
final class FeatureFlags {
    /// Backing store for both reads and writes. Held as a property so the
    /// `didSet` observers below persist to the SAME defaults store that
    /// `init` reads from — without this, scoped-defaults test injection
    /// (WP-1 §4.3) would write to `.standard` and silently fail round-trips.
    private let defaults: UserDefaults

    /// When enabled, streaming assistant messages are rendered in a WebView
    /// using MessageTemplate.html for rich formatting (bold, code, links, etc.).
    /// When disabled (default), streaming uses plain Text as before.
    var htmlRenderingEnabled: Bool {
        didSet { defaults.set(htmlRenderingEnabled, forKey: Keys.htmlRendering) }
    }

    /// WP-1 (Transcript Boundary Refactor): selects which transcript rendering
    /// engine is active.
    ///
    /// - `.native` (default): the existing SwiftUI/MessageCanvas stack.
    /// - `.web`: stub for now (EmptyView); WP-3 ships the WKWebView-backed
    ///   renderer. Flipping the flag should NOT crash — the web stub renders
    ///   nothing in the transcript area.
    ///
    /// Persisted as a `String` raw value in UserDefaults. Default on first
    /// launch is `.native`. Kieran flag: this MUST use `object(forKey:)` +
    /// nil-coalesce, NOT `bool(forKey:)` (which returns false for missing
    /// keys and would silently default an enum value to its "false" raw value).
    var transcriptEngine: TranscriptEngine {
        didSet {
            defaults.set(transcriptEngine.rawValue, forKey: Keys.transcriptEngine)
        }
    }

    private enum Keys {
        static let htmlRendering = "BeeChat.feature.htmlRendering"
        static let transcriptEngine = "BeeChat.feature.transcriptEngine"
    }

    /// Creates a FeatureFlags instance. By default, reads persisted values from
    /// UserDefaults. Pass explicit values in previews/tests to override.
    ///
    /// Kieran note (WP-1 §4.3): tests must not be order-dependent on
    /// persisted values. The transcript-engine read uses `object(forKey:)`
    /// + nil-coalesce so a fresh defaults store reads `.native` (the
    /// documented default), not a false-positive zero value.
    init(
        htmlRenderingEnabled: Bool? = nil,
        transcriptEngine: TranscriptEngine? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
        self.htmlRenderingEnabled = htmlRenderingEnabled
            ?? defaults.bool(forKey: Keys.htmlRendering)

        if let explicit = transcriptEngine {
            self.transcriptEngine = explicit
        } else if let raw = defaults.string(forKey: Keys.transcriptEngine),
                  let parsed = TranscriptEngine(rawValue: raw) {
            self.transcriptEngine = parsed
        } else {
            self.transcriptEngine = .native
        }
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