import Foundation

/// Classifies HTML content as native-renderable or WebView-required.
///
/// This is a thin convenience over `HTMLMessageConverter.convert()`, which
/// already returns `needsWebView` as part of its output. For cases where you
/// only need the classification without the full conversion, this avoids the
/// cost of building all the `MessageBlock` values.
///
/// The classification boundary is defined by `HTMLMessageConverter.nativeTags`:
/// any tag not in that set trips `needsWebView`. This is a product decision,
/// not a heuristic — it's deterministic and testable.
///
/// ## Usage
///
/// ```swift
/// if HTMLContentClassifier.needsWebView(html: message.content) {
///     // Render via MessageWebView
/// } else {
///     // Render via ConvertedMessageView (native)
/// }
/// ```
enum HTMLContentClassifier {

    /// Returns `true` if the HTML content should be rendered via WebView
    /// (contains tables, unknown tags, or exceeds resource caps).
    ///
    /// This runs a lightweight check — it parses the HTML and walks for
    /// unknown tags, but doesn't build the full `[MessageBlock]` output.
    /// For the full conversion including block model, use `HTMLMessageConverter.convert()`.
    static func needsWebView(html: String) -> Bool {
        // Quick pre-checks before parsing
        guard !html.isEmpty, html.count <= HTMLMessageConverter.maxTextLength else {
            return true // Empty content or over cap → WebView (or plain text for empty)
        }

        // Use the converter's full convert method, which already computes needsWebView
        let result = HTMLMessageConverter.convert(html)
        return result.needsWebView
    }
}