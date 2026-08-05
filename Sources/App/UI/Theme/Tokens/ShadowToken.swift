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

    /// CSS `box-shadow` value for this shadow. Used by the single-WebView transcript
    /// (route plan §3.2, `--bc-shadow-bubble`) to mirror the native SwiftUI bubble's
    /// shadow exactly. Format: `rgba(r,g,b,a) Xpx Ypx Zpx`.
    ///
    /// Note: the SwiftUI native bubble applies `shadowMedium.opacity(0.1)` (i.e.
    /// 10% opacity on a black shadow) at `radius:4 x:0 y:2`. The themes encode
    /// `shadowMedium` with `opacity: 0.1` already, so this getter emits the raw
    /// definition as-is. If a future theme encodes shadows differently, this
    /// contract needs revisiting — the CSS will diverge from the SwiftUI bubble.
    var cssString: String {
        let hex = color.toHex()  // returns #RRGGBB
        // Convert #RRGGBB → rgba(). SwiftUI Color's hex form is 8-digit (#RRGGBBAA)
        // or 6-digit; normalize by stripping alpha and rebuilding as rgba.
        let r: Double
        let g: Double
        let b: Double
        if hex.hasPrefix("#") && hex.count == 9 {
            // #RRGGBBAA
            let h = hex.dropFirst()
            r = Double(UInt8(h.prefix(2), radix: 16) ?? 0) / 255.0
            g = Double(UInt8(h.dropFirst(2).prefix(2), radix: 16) ?? 0) / 255.0
            b = Double(UInt8(h.dropFirst(4).prefix(2), radix: 16) ?? 0) / 255.0
        } else if hex.hasPrefix("#") && hex.count == 7 {
            let h = hex.dropFirst()
            r = Double(UInt8(h.prefix(2), radix: 16) ?? 0) / 255.0
            g = Double(UInt8(h.dropFirst(2).prefix(2), radix: 16) ?? 0) / 255.0
            b = Double(UInt8(h.dropFirst(4).prefix(2), radix: 16) ?? 0) / 255.0
        } else {
            return "none"
        }
        let alpha = max(0.0, min(1.0, opacity))
        return String(
            format: "rgba(%.0f,%.0f,%.0f,%.2f) %.1fpx %.1fpx %.1fpx",
            r * 255, g * 255, b * 255, alpha,
            Double(offsetX), Double(offsetY), Double(blur)
        )
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
