import SwiftUI

/// Spacing tokens for consistent margins, padding, and gaps.
/// All values in points (pt), shared across macOS and iOS.
enum SpacingToken: String, CaseIterable, Sendable {
    case xs   // 4pt
    case sm   // 8pt
    case md   // 12pt
    case lg   // 16pt
    case xl   // 24pt
    case xxl  // 32pt

    var value: CGFloat {
        switch self {
        case .xs:   return 4
        case .sm:   return 8
        case .md:   return 12
        case .lg:   return 16
        case .xl:   return 24
        case .xxl:  return 32
        }
    }
}
