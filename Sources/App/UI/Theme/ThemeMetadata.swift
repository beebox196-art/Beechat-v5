import SwiftUI

struct ThemeMetadata: Identifiable, Sendable {
    let id: String
    let name: String
    let previewColors: [Color]
}

extension ThemeMetadata {
    static let allThemes: [ThemeMetadata] = [
        ThemeMetadata(id: "artisanal-tech", name: "Artisanal Tech",
                      previewColors: [Color(hex: "D4A574")!, Color(hex: "8FA895")!, Color(hex: "F8F6F0")!]),
        ThemeMetadata(id: "dark", name: "Dark",
                      previewColors: [Color(hex: "64B5F6")!, Color(hex: "81C784")!, Color(hex: "121212")!]),
        ThemeMetadata(id: "light", name: "Light",
                      previewColors: [Color(hex: "1976D2")!, Color(hex: "388E3C")!, Color(hex: "FAFAFA")!]),
        ThemeMetadata(id: "starfleet-lcars", name: "Starfleet LCARS",
                      previewColors: [Color(hex: "FF6600")!, Color(hex: "9999CC")!, Color(hex: "00002E")!]),
        ThemeMetadata(id: "minimal", name: "Minimal",
                      previewColors: [Color(hex: "111111")!, Color(hex: "666666")!, Color(hex: "FFFFFF")!]),
        ThemeMetadata(id: "holographic-imperial", name: "Holographic Imperial",
                      previewColors: [Color(hex: "00FFFF")!, Color(hex: "9966FF")!, Color(hex: "0A0A1A")!]),
        ThemeMetadata(id: "water-fluid-ui", name: "Water Fluid UI",
                      previewColors: [Color(hex: "0077B6")!, Color(hex: "00B4D8")!, Color(hex: "E8F4FD")!]),
        ThemeMetadata(id: "living-crystal", name: "Living Crystal",
                      previewColors: [Color(hex: "8B5CF6")!, Color(hex: "EC4899")!, Color(hex: "F5F0FA")!]),
    ]
}
