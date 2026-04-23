import SwiftUI

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

    // MARK: - Theme switching

    func switchTheme(to id: String) {
        guard id != currentTheme.id else { return }
        if let theme = Theme.theme(for: id) {
            currentTheme = theme
            persistTheme(id: id)
        }
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
}