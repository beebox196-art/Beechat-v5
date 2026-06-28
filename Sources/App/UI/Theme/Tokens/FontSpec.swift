import SwiftUI

/// Value type describing a theme font entry: size, weight, and monospace flag.
///
/// Wrapping in `FontSpec` (rather than storing `Font` directly) lets us
/// preserve monospaced-ness across scaling. `.system(size:weight:).monospaced()`
/// applied once at theme-definition time would bake the base size into the
/// font; we want to scale the underlying size before applying `.monospaced()`.
///
/// `font(scaledBy:)` produces a `Font` on demand. The factor parameter is
/// `CGFloat` for consistency with `Font.system(size:)` and `View.frame`.
struct FontSpec: Sendable {
    let size: CGFloat
    let weight: Font.Weight
    var isMono: Bool = false

    func font(scaledBy factor: CGFloat = 1.0) -> Font {
        let scaledSize = size * factor
        let base = Font.system(size: scaledSize, weight: weight)
        return isMono ? base.monospaced() : base
    }

    /// Returns the size that `font(scaledBy: factor)` will use internally.
    /// Exposed for unit testing — SwiftUI's `Font` is opaque and does not
    /// expose its point size publicly, so this is the only way to verify
    /// the scale factor reaches the rendered Font.
    func scaledSize(for factor: CGFloat) -> CGFloat {
        size * factor
    }
}
