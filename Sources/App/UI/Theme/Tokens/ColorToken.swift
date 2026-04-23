import SwiftUI

enum ColorToken: String, CaseIterable {
    case bgSurface
    case bgPanel
    case bgElevated

    case textPrimary
    case textSecondary
    case textOnAccent

    case accentPrimary
    case accentSecondary
    case accentTertiary

    case success
    case warning
    case error
    case info

    case borderSubtle
    case borderDefault

    case shadowLight
    case shadowMedium
    case shadowStrong
}