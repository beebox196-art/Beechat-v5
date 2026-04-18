import SwiftUI

/// Centralised theme state. Inject as @Environment(ThemeManager.self).
/// Views call `themeManager.color(.bgSurface)` etc.
@MainActor
@Observable
final class ThemeManager {
    var currentTheme: Theme
    var availableThemes: [ThemeMetadata]

    init() {
        self.currentTheme = .artisanalTech
        self.availableThemes = ThemeMetadata.allThemes
        loadPersistedTheme()
    }

    // MARK: - Token resolution

    func color(_ token: ColorToken) -> Color {
        currentTheme.colors[token] ?? .black
    }

    func font(_ token: TypographyToken) -> Font {
        currentTheme.typography[token] ?? .body
    }

    func spacing(_ token: SpacingToken) -> CGFloat {
        token.rawValue
    }

    func radius(_ token: RadiusToken) -> CGFloat {
        token.rawValue
    }

    func shadow(_ token: ShadowToken) -> ShadowDefinition {
        token.definition
    }

    func animationDuration(_ token: AnimationToken) -> Double {
        token.rawValue
    }

    // MARK: - Theme switching

    func switchTheme(to id: String) {
        // Currently only artisanal-tech exists; more themes added in Phase 4B
        guard id == currentTheme.id else { return }
        persistTheme(id: id)
    }

    // MARK: - Persistence

    private func loadPersistedTheme() {
        if let id = UserDefaults.standard.string(forKey: "BeeChat.selectedTheme") {
            // For now only artisanal-tech is available; keep currentTheme as-is
            _ = id
        }
    }

    private func persistTheme(id: String) {
        UserDefaults.standard.set(id, forKey: "BeeChat.selectedTheme")
    }
}