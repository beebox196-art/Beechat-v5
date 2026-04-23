import SwiftUI

struct Theme: Identifiable, Sendable {
    let id: String
    let name: String
    let colors: [ColorToken: Color]
    let typography: [TypographyToken: Font]
    let spacing: [SpacingToken: CGFloat]
    let radius: [RadiusToken: CGFloat]
    let shadow: [ShadowToken: ShadowDefinition]
    let animation: [AnimationToken: AnimationDefinition]

    static let artisanalTech = Theme(
        id: "artisanal-tech",
        name: "Artisanal Tech",
        colors: [
            .bgSurface:      Color(hex: "F8F6F0")!,
            .bgPanel:        Color(hex: "EAE6DF")!,
            .bgElevated:     Color(hex: "FFFFFF")!,
            .textPrimary:    Color(hex: "2D2D2D")!,
            .textSecondary:  Color(hex: "6B6B6B")!,
            .textOnAccent:   Color(hex: "FFFFFF")!,
            .accentPrimary:  Color(hex: "D4A574")!,
            .accentSecondary: Color(hex: "8FA895")!,
            .accentTertiary: Color(hex: "C77D63")!,
            .success:        Color(hex: "4CAF50")!,
            .warning:        Color(hex: "FFC107")!,
            .error:          Color(hex: "F44336")!,
            .info:           Color(hex: "2196F3")!,
            .borderSubtle:   Color(hex: "E0E0E0")!,
            .borderDefault:  Color(hex: "BDBDBD")!,
            .shadowLight:    Color(hex: "000000")!.opacity(0.05),
            .shadowMedium:   Color(hex: "000000")!.opacity(0.1),
            .shadowStrong:   Color(hex: "000000")!.opacity(0.2),
        ],
        typography: [
            .display:    .system(size: 24, weight: .bold),
            .heading:    .system(size: 20, weight: .semibold),
            .subheading: .system(size: 16, weight: .medium),
            .body:       .system(size: 14, weight: .regular),
            .caption:    .system(size: 12, weight: .regular),
            .caption2:   .system(size: 10, weight: .regular),
            .mono:       .system(size: 14, weight: .regular).monospaced(),
        ],
        spacing: [
            .xs:   4,
            .sm:   8,
            .md:   12,
            .lg:   16,
            .xl:   24,
            .xxl:  32,
        ],
        radius: [
            .sm:   4,
            .md:   8,
            .lg:   12,
            .xl:   16,
            .full: 9999,
        ],
        shadow: [
            .sm: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.05),
                blur: 2, offsetX: 0, offsetY: 1
            ),
            .md: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.1),
                blur: 6, offsetX: 0, offsetY: 4
            ),
            .lg: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.1),
                blur: 15, offsetX: 0, offsetY: 10
            ),
            .glow: ShadowDefinition(
                color: Color(hex: "D4A574")!.opacity(0.5),
                blur: 12, offsetX: 0, offsetY: 0
            ),
        ],
        animation: [
            .fast:   AnimationDefinition(duration: 0.15, easing: .easeInOut),
            .normal: AnimationDefinition(duration: 0.30, easing: .easeInOut),
            .slow:   AnimationDefinition(duration: 0.50, easing: .easeInOut),
        ]
    )
    static func theme(for id: String) -> Theme? {
        allThemes.first { $0.id == id }
    }

    static var allThemes: [Theme] {
        [.artisanalTech]
    }
}

// MARK: - Color hex convenience

extension Color {
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}