import SwiftUI

/// Shadow definition associated with a shadow token.
struct ShadowDefinition {
    let blur: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
}

/// Semantic shadow tokens.
enum ShadowToken: String, CaseIterable {
    case none
    case sm
    case md
    case lg

    var definition: ShadowDefinition {
        switch self {
        case .none: return ShadowDefinition(blur: 0, offsetX: 0, offsetY: 0)
        case .sm:   return ShadowDefinition(blur: 2, offsetX: 0, offsetY: 1)
        case .md:   return ShadowDefinition(blur: 4, offsetX: 0, offsetY: 2)
        case .lg:   return ShadowDefinition(blur: 8, offsetX: 0, offsetY: 4)
        }
    }
}