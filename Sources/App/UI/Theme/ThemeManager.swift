import SwiftUI

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    var currentTheme: Theme
    var availableThemes: [ThemeMetadata]

    /// Global text-scale multiplier applied to every typography token.
    /// Range: 0.7 ... 2.0. Default 1.0. Persisted to UserDefaults.
    var fontScale: CGFloat = 1.0

    init() {
        self.currentTheme = .artisanalTech
        self.availableThemes = ThemeMetadata.allThemes
        loadPersistedTheme()
        loadPersistedFontScale()
    }

    // MARK: - Token resolution

    func color(_ token: ColorToken) -> Color {
        currentTheme.colors[token] ?? .black
    }

    func font(_ token: TypographyToken) -> Font {
        guard let spec = currentTheme.typography[token] else { return .body }
        return spec.font(scaledBy: fontScale)
    }

    func spacing(_ token: SpacingToken) -> CGFloat {
        currentTheme.spacing[token] ?? 0
    }

    func radius(_ token: RadiusToken) -> CGFloat {
        currentTheme.radius[token] ?? 0
    }

    func shadow(_ token: ShadowToken) -> ShadowDefinition? {
        currentTheme.shadow[token]
    }

    func animation(_ token: AnimationToken) -> Animation {
        currentTheme.animation[token]?.animation ?? .easeInOut
    }

    // MARK: - Theme switching

    func switchTheme(to id: String) {
        guard id != currentTheme.id else { return }
        if let theme = Theme.theme(for: id) {
            currentTheme = theme
            persistTheme(id: id)
        }
    }

    // MARK: - Font scale

    /// Set the global font scale. Clamped to 0.7...2.0 and persisted to
    /// UserDefaults (rounded to 1 decimal to avoid float artefacts).
    ///
    /// Callers can pass raw values — clamping is internal. This includes
    /// the ⌘+ / ⌘− keyboard shortcuts, the slider, and quick-select buttons.
    func setFontScale(_ value: CGFloat) {
        let clamped = min(max(value, 0.7), 2.0)
        // Round to 1 decimal to avoid float representation artefacts
        // (e.g. 1.0000000001) leaking into UserDefaults.
        let rounded = (clamped * 10).rounded() / 10
        guard rounded != fontScale else { return }
        fontScale = rounded
        persistFontScale(rounded)
    }

    // MARK: - Persistence

    private func loadPersistedTheme() {
        if let id = UserDefaults.standard.string(forKey: "BeeChat.selectedTheme") {
            switchTheme(to: id)
        }
    }

    private func persistTheme(id: String) {
        UserDefaults.standard.set(id, forKey: "BeeChat.selectedTheme")
    }

    private func loadPersistedFontScale() {
        // UserDefaults stores Double; convert to CGFloat and apply via
        // setFontScale so we get the same clamping/rounding on the way in.
        let stored = UserDefaults.standard.double(forKey: "BeeChat.fontScale")
        guard stored > 0 else { return } // default if missing
        setFontScale(CGFloat(stored))
    }

    private func persistFontScale(_ value: CGFloat) {
        UserDefaults.standard.set(Double(value), forKey: "BeeChat.fontScale")
    }
}
