import SwiftUI

/// Shadow definition used by shadow tokens.
struct ShadowDefinition: Sendable {
    let color: Color
    let blur: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let opacity: Double

    init(color: Color, blur: CGFloat, offsetX: CGFloat = 0, offsetY: CGFloat = 0, opacity: Double = 1.0) {
        self.color = color
        self.blur = blur
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.opacity = opacity
    }
}

/// Shadow tokens for elevation and glow effects.
/// Matches DESIGN-SYSTEM.md shadow definitions.
enum ShadowToken: String, CaseIterable, Sendable {
    case sm    // subtle elevation
    case md    // medium elevation
    case lg    // strong elevation
    case glow  // accent glow (active/selected states)

    func definition(accentColor: Color, shadowColor: Color) -> ShadowDefinition {
        switch self {
        case .sm:
            return ShadowDefinition(
                color: shadowColor,
                blur: 2,
                offsetX: 0,
                offsetY: 1,
                opacity: 0.05
            )
        case .md:
            return ShadowDefinition(
                color: shadowColor,
                blur: 6,
                offsetX: 0,
                offsetY: 4,
                opacity: 0.1
            )
        case .lg:
            return ShadowDefinition(
                color: shadowColor,
                blur: 15,
                offsetX: 0,
                offsetY: 10,
                opacity: 0.1
            )
        case .glow:
            return ShadowDefinition(
                color: accentColor,
                blur: 12,
                offsetX: 0,
                offsetY: 0,
                opacity: 0.5
            )
        }
    }
}
