import SwiftUI

/// Semantic typography tokens.
enum TypographyToken: String, CaseIterable {
    case display    // 24pt bold
    case heading    // 20pt semibold
    case subheading // 16pt medium
    case body       // 14pt regular
    case caption    // 12pt regular
    case caption2   // 10pt regular
    case mono       // 14pt monospaced
}