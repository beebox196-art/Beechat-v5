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
            .xxs:  5,
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
            .micro:  AnimationDefinition(duration: 0.20, easing: .easeInOut),
            .normal: AnimationDefinition(duration: 0.30, easing: .easeInOut),
            .slow:   AnimationDefinition(duration: 0.50, easing: .easeInOut),
            .slower: AnimationDefinition(duration: 0.60, easing: .easeInOut),
        ]
    )
    // MARK: - Dark

    static let dark = Theme(
        id: "dark",
        name: "Dark",
        colors: [
            .bgSurface:      Color(hex: "121212")!,
            .bgPanel:        Color(hex: "1E1E1E")!,
            .bgElevated:     Color(hex: "2A2A2A")!,
            .textPrimary:    Color(hex: "E0E0E0")!,
            .textSecondary:  Color(hex: "9E9E9E")!,
            .textOnAccent:   Color(hex: "FFFFFF")!,
            .accentPrimary:  Color(hex: "64B5F6")!,
            .accentSecondary: Color(hex: "81C784")!,
            .accentTertiary: Color(hex: "E57373")!,
            .success:        Color(hex: "4CAF50")!,
            .warning:        Color(hex: "FFC107")!,
            .error:          Color(hex: "F44336")!,
            .info:           Color(hex: "2196F3")!,
            .borderSubtle:   Color(hex: "333333")!,
            .borderDefault:  Color(hex: "444444")!,
            .shadowLight:    Color(hex: "000000")!.opacity(0.2),
            .shadowMedium:   Color(hex: "000000")!.opacity(0.4),
            .shadowStrong:   Color(hex: "000000")!.opacity(0.6),
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
            .xxs:  5,
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
                color: Color(hex: "000000")!.opacity(0.2),
                blur: 2, offsetX: 0, offsetY: 1
            ),
            .md: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.4),
                blur: 6, offsetX: 0, offsetY: 4
            ),
            .lg: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.6),
                blur: 15, offsetX: 0, offsetY: 10
            ),
            .glow: ShadowDefinition(
                color: Color(hex: "64B5F6")!.opacity(0.5),
                blur: 12, offsetX: 0, offsetY: 0
            ),
        ],
        animation: [
            .fast:   AnimationDefinition(duration: 0.15, easing: .easeInOut),
            .micro:  AnimationDefinition(duration: 0.20, easing: .easeInOut),
            .normal: AnimationDefinition(duration: 0.30, easing: .easeInOut),
            .slow:   AnimationDefinition(duration: 0.50, easing: .easeInOut),
            .slower: AnimationDefinition(duration: 0.60, easing: .easeInOut),
        ]
    )

    // MARK: - Light

    static let light = Theme(
        id: "light",
        name: "Light",
        colors: [
            .bgSurface:      Color(hex: "FAFAFA")!,
            .bgPanel:        Color(hex: "F5F5F5")!,
            .bgElevated:     Color(hex: "FFFFFF")!,
            .textPrimary:    Color(hex: "212121")!,
            .textSecondary:  Color(hex: "757575")!,
            .textOnAccent:   Color(hex: "FFFFFF")!,
            .accentPrimary:  Color(hex: "1976D2")!,
            .accentSecondary: Color(hex: "388E3C")!,
            .accentTertiary: Color(hex: "F57C00")!,
            .success:        Color(hex: "4CAF50")!,
            .warning:        Color(hex: "FFC107")!,
            .error:          Color(hex: "F44336")!,
            .info:           Color(hex: "2196F3")!,
            .borderSubtle:   Color(hex: "E0E0E0")!,
            .borderDefault:  Color(hex: "BDBDBD")!,
            .shadowLight:    Color(hex: "000000")!.opacity(0.04),
            .shadowMedium:   Color(hex: "000000")!.opacity(0.08),
            .shadowStrong:   Color(hex: "000000")!.opacity(0.15),
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
            .xxs:  5,
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
                color: Color(hex: "000000")!.opacity(0.04),
                blur: 2, offsetX: 0, offsetY: 1
            ),
            .md: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.08),
                blur: 6, offsetX: 0, offsetY: 4
            ),
            .lg: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.15),
                blur: 15, offsetX: 0, offsetY: 10
            ),
            .glow: ShadowDefinition(
                color: Color(hex: "1976D2")!.opacity(0.5),
                blur: 12, offsetX: 0, offsetY: 0
            ),
        ],
        animation: [
            .fast:   AnimationDefinition(duration: 0.15, easing: .easeInOut),
            .micro:  AnimationDefinition(duration: 0.20, easing: .easeInOut),
            .normal: AnimationDefinition(duration: 0.30, easing: .easeInOut),
            .slow:   AnimationDefinition(duration: 0.50, easing: .easeInOut),
            .slower: AnimationDefinition(duration: 0.60, easing: .easeInOut),
        ]
    )

    // MARK: - Starfleet LCARS

    static let starfleetLCARS = Theme(
        id: "starfleet-lcars",
        name: "Starfleet LCARS",
        colors: [
            .bgSurface:      Color(hex: "00002E")!,
            .bgPanel:        Color(hex: "000042")!,
            .bgElevated:     Color(hex: "1A1A5E")!,
            .textPrimary:    Color(hex: "FFCC99")!,
            .textSecondary:  Color(hex: "9999CC")!,
            .textOnAccent:   Color(hex: "00002E")!,
            .accentPrimary:  Color(hex: "FF6600")!,
            .accentSecondary: Color(hex: "9999CC")!,
            .accentTertiary: Color(hex: "00BFFF")!,
            .success:        Color(hex: "00FF66")!,
            .warning:        Color(hex: "FFCC00")!,
            .error:          Color(hex: "FF3333")!,
            .info:           Color(hex: "00BFFF")!,
            .borderSubtle:   Color(hex: "333366")!,
            .borderDefault:  Color(hex: "666699")!,
            .shadowLight:    Color(hex: "FF6600")!.opacity(0.15),
            .shadowMedium:   Color(hex: "FF6600")!.opacity(0.3),
            .shadowStrong:   Color(hex: "FF6600")!.opacity(0.5),
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
            .xxs:  5,
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
                color: Color(hex: "FF6600")!.opacity(0.15),
                blur: 2, offsetX: 0, offsetY: 1
            ),
            .md: ShadowDefinition(
                color: Color(hex: "FF6600")!.opacity(0.3),
                blur: 6, offsetX: 0, offsetY: 4
            ),
            .lg: ShadowDefinition(
                color: Color(hex: "FF6600")!.opacity(0.5),
                blur: 15, offsetX: 0, offsetY: 10
            ),
            .glow: ShadowDefinition(
                color: Color(hex: "FF6600")!.opacity(0.6),
                blur: 12, offsetX: 0, offsetY: 0
            ),
        ],
        animation: [
            .fast:   AnimationDefinition(duration: 0.15, easing: .easeInOut),
            .micro:  AnimationDefinition(duration: 0.20, easing: .easeInOut),
            .normal: AnimationDefinition(duration: 0.30, easing: .easeInOut),
            .slow:   AnimationDefinition(duration: 0.50, easing: .easeInOut),
            .slower: AnimationDefinition(duration: 0.60, easing: .easeInOut),
        ]
    )

    // MARK: - Minimal

    static let minimal = Theme(
        id: "minimal",
        name: "Minimal",
        colors: [
            .bgSurface:      Color(hex: "FFFFFF")!,
            .bgPanel:        Color(hex: "F7F7F7")!,
            .bgElevated:     Color(hex: "FFFFFF")!,
            .textPrimary:    Color(hex: "111111")!,
            .textSecondary:  Color(hex: "888888")!,
            .textOnAccent:   Color(hex: "FFFFFF")!,
            .accentPrimary:  Color(hex: "111111")!,
            .accentSecondary: Color(hex: "666666")!,
            .accentTertiary: Color(hex: "AAAAAA")!,
            .success:        Color(hex: "4CAF50")!,
            .warning:        Color(hex: "FFC107")!,
            .error:          Color(hex: "F44336")!,
            .info:           Color(hex: "2196F3")!,
            .borderSubtle:   Color(hex: "EEEEEE")!,
            .borderDefault:  Color(hex: "DDDDDD")!,
            .shadowLight:    Color(hex: "000000")!.opacity(0.03),
            .shadowMedium:   Color(hex: "000000")!.opacity(0.06),
            .shadowStrong:   Color(hex: "000000")!.opacity(0.1),
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
            .xxs:  5,
            .xs:   4,
            .sm:   8,
            .md:   12,
            .lg:   16,
            .xl:   24,
            .xxl:  32,
        ],
        radius: [
            .sm:   2,
            .md:   4,
            .lg:   6,
            .xl:   8,
            .full: 9999,
        ],
        shadow: [
            .sm: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.03),
                blur: 1, offsetX: 0, offsetY: 1
            ),
            .md: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.06),
                blur: 3, offsetX: 0, offsetY: 2
            ),
            .lg: ShadowDefinition(
                color: Color(hex: "000000")!.opacity(0.1),
                blur: 8, offsetX: 0, offsetY: 4
            ),
            .glow: ShadowDefinition(
                color: Color(hex: "111111")!.opacity(0.15),
                blur: 8, offsetX: 0, offsetY: 0
            ),
        ],
        animation: [
            .fast:   AnimationDefinition(duration: 0.15, easing: .easeInOut),
            .micro:  AnimationDefinition(duration: 0.20, easing: .easeInOut),
            .normal: AnimationDefinition(duration: 0.30, easing: .easeInOut),
            .slow:   AnimationDefinition(duration: 0.50, easing: .easeInOut),
            .slower: AnimationDefinition(duration: 0.60, easing: .easeInOut),
        ]
    )

    // MARK: - Holographic Imperial

    static let holographicImperial = Theme(
        id: "holographic-imperial",
        name: "Holographic Imperial",
        colors: [
            .bgSurface:      Color(hex: "0A0A1A")!,
            .bgPanel:        Color(hex: "12122A")!,
            .bgElevated:     Color(hex: "1A1A3A")!,
            .textPrimary:    Color(hex: "E8E8FF")!,
            .textSecondary:  Color(hex: "9999CC")!,
            .textOnAccent:   Color(hex: "FFFFFF")!,
            .accentPrimary:  Color(hex: "00FFFF")!,
            .accentSecondary: Color(hex: "9966FF")!,
            .accentTertiary: Color(hex: "FF3399")!,
            .success:        Color(hex: "00FF88")!,
            .warning:        Color(hex: "FFCC00")!,
            .error:          Color(hex: "FF3366")!,
            .info:           Color(hex: "00CCFF")!,
            .borderSubtle:   Color(hex: "2A2A4A")!,
            .borderDefault:  Color(hex: "4A4A6A")!,
            .shadowLight:    Color(hex: "00FFFF")!.opacity(0.1),
            .shadowMedium:   Color(hex: "9966FF")!.opacity(0.2),
            .shadowStrong:   Color(hex: "FF3399")!.opacity(0.3),
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
            .xxs:  5,
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
                color: Color(hex: "00FFFF")!.opacity(0.1),
                blur: 4, offsetX: 0, offsetY: 1
            ),
            .md: ShadowDefinition(
                color: Color(hex: "9966FF")!.opacity(0.2),
                blur: 8, offsetX: 0, offsetY: 4
            ),
            .lg: ShadowDefinition(
                color: Color(hex: "FF3399")!.opacity(0.3),
                blur: 15, offsetX: 0, offsetY: 10
            ),
            .glow: ShadowDefinition(
                color: Color(hex: "00FFFF")!.opacity(0.6),
                blur: 16, offsetX: 0, offsetY: 0
            ),
        ],
        animation: [
            .fast:   AnimationDefinition(duration: 0.15, easing: .easeInOut),
            .micro:  AnimationDefinition(duration: 0.20, easing: .easeInOut),
            .normal: AnimationDefinition(duration: 0.30, easing: .easeInOut),
            .slow:   AnimationDefinition(duration: 0.50, easing: .easeInOut),
            .slower: AnimationDefinition(duration: 0.60, easing: .easeInOut),
        ]
    )

    // MARK: - Water Fluid UI

    static let waterFluidUI = Theme(
        id: "water-fluid-ui",
        name: "Water Fluid UI",
        colors: [
            .bgSurface:      Color(hex: "E8F4FD")!,
            .bgPanel:        Color(hex: "FFFFFF")!,
            .bgElevated:     Color(hex: "F0F8FF")!,
            .textPrimary:    Color(hex: "1A3A5C")!,
            .textSecondary:  Color(hex: "5A7A9A")!,
            .textOnAccent:   Color(hex: "FFFFFF")!,
            .accentPrimary:  Color(hex: "0077B6")!,
            .accentSecondary: Color(hex: "00B4D8")!,
            .accentTertiary: Color(hex: "48CAE4")!,
            .success:        Color(hex: "2ECC71")!,
            .warning:        Color(hex: "F39C12")!,
            .error:          Color(hex: "E74C3C")!,
            .info:           Color(hex: "3498DB")!,
            .borderSubtle:   Color(hex: "D0E8F5")!,
            .borderDefault:  Color(hex: "A8D0E6")!,
            .shadowLight:    Color(hex: "0077B6")!.opacity(0.06),
            .shadowMedium:   Color(hex: "0077B6")!.opacity(0.12),
            .shadowStrong:   Color(hex: "0077B6")!.opacity(0.2),
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
            .xxs:  5,
            .xs:   4,
            .sm:   8,
            .md:   12,
            .lg:   16,
            .xl:   24,
            .xxl:  32,
        ],
        radius: [
            .sm:   8,
            .md:   12,
            .lg:   16,
            .xl:   24,
            .full: 9999,
        ],
        shadow: [
            .sm: ShadowDefinition(
                color: Color(hex: "0077B6")!.opacity(0.06),
                blur: 4, offsetX: 0, offsetY: 2
            ),
            .md: ShadowDefinition(
                color: Color(hex: "0077B6")!.opacity(0.12),
                blur: 8, offsetX: 0, offsetY: 4
            ),
            .lg: ShadowDefinition(
                color: Color(hex: "0077B6")!.opacity(0.2),
                blur: 16, offsetX: 0, offsetY: 8
            ),
            .glow: ShadowDefinition(
                color: Color(hex: "00B4D8")!.opacity(0.4),
                blur: 14, offsetX: 0, offsetY: 0
            ),
        ],
        animation: [
            .fast:   AnimationDefinition(duration: 0.15, easing: .easeInOut),
            .micro:  AnimationDefinition(duration: 0.20, easing: .easeInOut),
            .normal: AnimationDefinition(duration: 0.30, easing: .spring),
            .slow:   AnimationDefinition(duration: 0.50, easing: .spring),
            .slower: AnimationDefinition(duration: 0.60, easing: .spring),
        ]
    )

    // MARK: - Living Crystal

    static let livingCrystal = Theme(
        id: "living-crystal",
        name: "Living Crystal",
        colors: [
            .bgSurface:      Color(hex: "F5F0FA")!,
            .bgPanel:        Color(hex: "FFFFFF")!,
            .bgElevated:     Color(hex: "FAF5FF")!,
            .textPrimary:    Color(hex: "2D1B4E")!,
            .textSecondary:  Color(hex: "7B6B9A")!,
            .textOnAccent:   Color(hex: "FFFFFF")!,
            .accentPrimary:  Color(hex: "8B5CF6")!,
            .accentSecondary: Color(hex: "EC4899")!,
            .accentTertiary: Color(hex: "06B6D4")!,
            .success:        Color(hex: "10B981")!,
            .warning:        Color(hex: "F59E0B")!,
            .error:          Color(hex: "EF4444")!,
            .info:           Color(hex: "3B82F6")!,
            .borderSubtle:   Color(hex: "EDE5F7")!,
            .borderDefault:  Color(hex: "D4C4E8")!,
            .shadowLight:    Color(hex: "8B5CF6")!.opacity(0.08),
            .shadowMedium:   Color(hex: "8B5CF6")!.opacity(0.15),
            .shadowStrong:   Color(hex: "8B5CF6")!.opacity(0.25),
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
            .xxs:  5,
            .xs:   4,
            .sm:   8,
            .md:   12,
            .lg:   16,
            .xl:   24,
            .xxl:  32,
        ],
        radius: [
            .sm:   6,
            .md:   10,
            .lg:   14,
            .xl:   20,
            .full: 9999,
        ],
        shadow: [
            .sm: ShadowDefinition(
                color: Color(hex: "8B5CF6")!.opacity(0.08),
                blur: 4, offsetX: -1, offsetY: -1
            ),
            .md: ShadowDefinition(
                color: Color(hex: "8B5CF6")!.opacity(0.15),
                blur: 8, offsetX: 0, offsetY: 4
            ),
            .lg: ShadowDefinition(
                color: Color(hex: "8B5CF6")!.opacity(0.25),
                blur: 16, offsetX: 0, offsetY: 8
            ),
            .glow: ShadowDefinition(
                color: Color(hex: "EC4899")!.opacity(0.4),
                blur: 14, offsetX: 0, offsetY: 0
            ),
        ],
        animation: [
            .fast:   AnimationDefinition(duration: 0.15, easing: .easeInOut),
            .micro:  AnimationDefinition(duration: 0.20, easing: .easeInOut),
            .normal: AnimationDefinition(duration: 0.30, easing: .spring),
            .slow:   AnimationDefinition(duration: 0.50, easing: .spring),
            .slower: AnimationDefinition(duration: 0.60, easing: .spring),
        ]
    )

    // MARK: - Registry

    static func theme(for id: String) -> Theme? {
        allThemes.first { $0.id == id }
    }

    static var allThemes: [Theme] {
        [
            .artisanalTech,
            .dark,
            .light,
            .starfleetLCARS,
            .minimal,
            .holographicImperial,
            .waterFluidUI,
            .livingCrystal,
        ]
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