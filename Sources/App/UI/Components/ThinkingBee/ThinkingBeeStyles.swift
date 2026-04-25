import SwiftUI

// MARK: - Sizing

enum ThinkingBeeSize {
    case canvas    // Larger, for message area (32×32pt)
    case sidebar   // Smaller, for session row (16×16pt)

    var bodySize: CGSize {
        switch self {
        case .canvas:  CGSize(width: 32, height: 32)
        case .sidebar: CGSize(width: 16, height: 16)
        }
    }

    var capsuleSize: CGSize {
        switch self {
        case .canvas:  CGSize(width: 8, height: 12)
        case .sidebar: CGSize(width: 4, height: 6)
        }
    }

    var wingSize: CGSize {
        switch self {
        case .canvas:  CGSize(width: 10, height: 6)
        case .sidebar: CGSize(width: 5, height: 3)
        }
    }

    var zzzFontSize: CGFloat {
        switch self {
        case .canvas:  8
        case .sidebar: 6
        }
    }
}

// MARK: - Colour Helpers (all from ThemeManager tokens)

@MainActor
extension ThinkingBeeSize {
    /// Body colour — uses accent primary for thinking, text secondary for dormant.
    func bodyColor(theme: ThemeManager, isThinking: Bool) -> Color {
        isThinking ? theme.color(.accentPrimary) : theme.color(.textSecondary)
    }

    /// Wing colour — slightly lighter than body.
    @MainActor
    func wingColor(theme: ThemeManager, isThinking: Bool) -> Color {
        isThinking
            ? theme.color(.accentPrimary).opacity(0.6)
            : theme.color(.textSecondary).opacity(0.4)
    }
}