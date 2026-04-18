import SwiftUI

/// Semantic colour tokens used throughout BeeChat UI.
/// Each token maps to a concrete colour defined by the active theme.
enum ColorToken: String, CaseIterable {
    // Backgrounds
    case bgSurface
    case bgPanel
    case bgElevated

    // Text
    case textPrimary
    case textSecondary
    case textOnAccent

    // Accents
    case accentPrimary
    case accentSecondary
    case accentTertiary

    // Semantic
    case success
    case warning
    case error
    case info

    // Borders
    case borderSubtle
    case borderDefault

    // Shadows
    case shadowLight
    case shadowMedium
    case shadowStrong
}