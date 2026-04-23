import SwiftUI

/// Corner radius tokens for consistent border rounding.
/// All values in points (pt), shared across macOS and iOS.
enum RadiusToken: String, CaseIterable, Sendable {
    case sm    // 4pt
    case md    // 8pt
    case lg    // 12pt
    case xl    // 16pt
    case full  // 9999pt (fully rounded / pill shape)

    var value: CGFloat {
        switch self {
        case .sm:   return 4
        case .md:   return 8
        case .lg:   return 12
        case .xl:   return 16
        case .full: return 9999
        }
    }
}
