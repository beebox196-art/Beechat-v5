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
    ]
}
