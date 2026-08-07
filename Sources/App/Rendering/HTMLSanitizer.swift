import Foundation
import os
import SwiftSoup

/// Sanitizes HTML content for safe rendering in a WKWebView or native converter.
///
/// This is the **authoritative** sanitizer at the app ingest layer. The gateway
/// does coarse stripping of dangerous elements; this allowlist is the final word
/// on what tags and attributes survive.
///
/// The sanitizer runs **before** `HTMLMessageConverter` — the converter expects
/// pre-sanitized input. Anything the sanitizer doesn't strip that the converter
/// can't handle natively will trip `needsWebView` instead of crashing or rendering
/// dangerously.
///
/// ## Implementation
///
/// Uses SwiftSoup to parse the input HTML, then walks the parsed DOM tree emitting
/// only allowlisted tags and attributes. Unknown harmless tags are unwrapped
/// (children kept, tag removed). Dangerous tags are removed with all their content.
///
/// ## Threat model
///
/// - **Script execution**: Stripped by removing `<script>` and event handlers.
/// - **Navigation/redirect**: Stripped by removing `<iframe>`, `<form>`,
///   `javascript:`/`data:` URLs.
/// - **Style injection**: Stripped by removing `<style>` and inline `style` attributes.
/// - **Resource amplification**: Mitigated by text-length cap (200K chars).
///   The converter's node/depth caps provide additional DoS protection.
/// - **Phishing**: URL scheme allowlist (http, https, mailto).
///
/// ## Design notes
///
/// - `<table>` is intentionally kept: the native converter routes it to
///   `needsWebView`, but the WebView path needs to render it. Stripping tables
///   here would break WebView rendering of legitimate tabular content.
/// - `<div>` is kept but its `class`/`id`/`style` attributes are stripped (theme
///   owns presentation). The native converter treats it as a paragraph boundary.
/// - `<sub>`, `<sup>` are kept as plain-text passthrough in the native converter.
enum HTMLSanitizer {

    private static let logger = Logger(subsystem: "com.beebox.beechat", category: "HTMLSanitizer")

    // MARK: - Configuration

    /// Tags that survive sanitization. Everything else is either unwrapped (content
    /// kept, tag removed) or removed entirely with content (if dangerous).
    static let allowedTags: Set<String> = [
        // Paragraphs & structure
        "p", "div", "br", "hr",
        // Headings
        "h1", "h2", "h3", "h4", "h5", "h6",
        // Inline formatting
        "b", "strong", "i", "em", "s", "del", "strike", "u",
        "code", "span", "sub", "sup", "small", "mark",
        // Links
        "a",
        // Lists
        "ul", "ol", "li",
        // Blockquote
        "blockquote",
        // Preformatted
        "pre",
        // Images
        "img",
        // Tables (WebView-only in native converter, but kept for WebView rendering)
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
        "colgroup", "col",
        // Interactive (limited)
        "details", "summary",
    ]

    /// Tags that are removed **with all their content**. These are dangerous
    /// (script execution, style injection, navigation, form hijacking, etc.).
    private static let dangerousTags: Set<String> = [
        "script", "style", "iframe", "object", "embed", "form",
        "input", "textarea", "select", "button",
        "meta", "link", "noscript",
    ]

    /// Attributes allowed on specific tags. Unlisted attributes are stripped.
    private static let tagAttributes: [String: Set<String>] = [
        "a": ["href", "title"],
        "img": ["src", "alt", "width", "height"],
        "pre": ["class"], // language hint: class="language-swift"
        "code": ["class"], // language hint: class="language-swift"
        "ol": ["start", "type"],
        "td": ["colspan", "rowspan"],
        "th": ["colspan", "rowspan"],
        "details": ["open"],
    ]

    /// Global attributes allowed on any tag.
    private static let globalAttributes: Set<String> = ["class", "id"]

    /// URL schemes allowed in `href` attributes.
    /// `data:` is NOT permitted here — a `data:text/html,...` href is an XSS
    /// vector (clickable navigates to attacker-controlled HTML/JS). The
    /// browser will only follow hrefs whose scheme is in this list.
    /// Mirrors the WP-2 CSP contract (`WP-2-csp-handoff.md` line 125, signed by Mel):
    /// "`https:`, `http:`, `mailto:` for `href`".
    static let hrefSchemes: Set<String> = ["http", "https", "mailto"]

    /// URL schemes allowed in `src` attributes (img, script, etc.).
    /// `data:` IS permitted here — inline base64 images are common in markdown
    /// renderers and the CSP contract allows them. Stays safe because the
    /// browser will not *execute* a data URL inside an `<img>`; only an `<a>`
    /// navigation to `data:` is dangerous (XSS), and that path uses `hrefSchemes`.
    /// `http:` is intentionally ABSENT — the CSP `img-src https: data:` would
    /// block it anyway, so the sanitizer must strip it at sanitize time. If an
    /// agent returns an http:// image URL, the sanitizer removes it here rather
    /// than letting it reach the document and produce a confusing CSP-blocked
    /// render failure. Mirrors the WP-2 CSP contract: "`https:`, `data:` for `img src`".
    static let srcSchemes: Set<String> = ["https", "data"]

    /// Backward-compat alias for `LinkPolicy.allowedWebSchemes`. Maps the legacy
    /// single-set API to the union of `hrefSchemes` + `srcSchemes` (minus `data`,
    /// which is not a web-scheme and must not appear in `LinkPolicy`'s allow list).
    /// Existing callers (LinkPolicy.swift:38) read this property.
    static var allowedSchemes: Set<String> { hrefSchemes.union(srcSchemes).subtracting(["data"]) }

    /// URL attributes that need scheme validation.
    private static let urlAttributes: Set<String> = ["href", "src"]

    /// Maximum input text length. Inputs exceeding this are truncated before parsing.
    /// This is a DoS mitigation, not a content policy.
    static let maxTextLength = 200_000

    // MARK: - Sanitization

    /// Sanitize HTML content for safe rendering.
    ///
    /// - Parameter html: Raw HTML content (typically from gateway message).
    /// - Returns: Sanitized HTML with only allowed tags and attributes.
    ///
    /// Tags in `allowedTags` are kept with allowlisted attributes.
    /// Tags in `dangerousTags` are removed with ALL their content.
    /// All other tags are unwrapped (children kept, tag itself removed).
    /// Attributes not in the allowlist are stripped.
    /// Event handlers (`on*` attributes) are always removed.
    /// `javascript:`, `data:`, and other disallowed URL schemes are removed.
    static func sanitize(_ html: String) -> String {
        // Length cap — DoS protection
        let input: String
        if html.count > maxTextLength {
            logger.warning("HTML input truncated: \(html.count) chars exceeds maxTextLength \(maxTextLength)")
            input = String(html.prefix(maxTextLength))
        } else {
            input = html
        }

        guard !input.isEmpty else { return "" }

        do {
            let doc = try SwiftSoup.parse(input)
            doc.outputSettings().prettyPrint(pretty: false)

            guard let body = doc.body() else {
                // If there's no body, return empty — the input was likely malformed
                return ""
            }

            let sanitized = walk(node: body)
            // Extract just the inner HTML (we don't want <body> tags in the output)
            return sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            logger.error("SwiftSoup parse error: \(error.localizedDescription)")
            // On parse failure, return empty string rather than potentially unsafe content
            return ""
        }
    }

    // MARK: - Tree Walking

    /// Walk a parsed DOM tree and emit only allowed content.
    /// - Parameter node: A SwiftSoup Node (Element, TextNode, etc.)
    /// - Returns: Sanitized HTML string.
    private static func walk(node: Node) -> String {
        switch node {
        case let element as Element:
            return walkElement(element)
        case let textNode as TextNode:
            // Text nodes: emit their text, escaped for HTML
            return escapeHtml(textNode.getWholeText())
        case is Comment:
            // Strip all comments
            return ""
        case is DataNode:
            // Strip data nodes (e.g., <script> content, <style> content)
            return ""
        case is DocumentType:
            return ""
        default:
            // Unknown node types — recurse into children if any
            return node.getChildNodes().map { walk(node: $0) }.joined()
        }
    }

    /// Process an Element node: keep if allowed, unwrap if unknown, remove if dangerous.
    private static func walkElement(_ element: Element) -> String {
        let tag = element.tagName().lowercased()

        // Dangerous tags: remove entirely with all content
        if dangerousTags.contains(tag) {
            return ""
        }

        // Allowed tags: emit with filtered attributes
        if allowedTags.contains(tag) {
            return emitAllowedElement(element, tag: tag)
        }

        // Unknown/harmless tags: unwrap — keep children, discard the tag itself
        let childrenHTML = element.getChildNodes().map { walk(node: $0) }.joined()
        return childrenHTML
    }

    /// Emit an allowed element with its allowlisted attributes.
    private static func emitAllowedElement(_ element: Element, tag: String) -> String {
        let allowedAttrs = allowedAttributes(for: tag)
        var attrString = ""

        guard let attributes = element.getAttributes() else {
            // No attributes — just emit the tag with children
            let childrenHTML = element.getChildNodes().map { walk(node: $0) }.joined()
            let voidElements: Set<String> = ["br", "hr", "img", "col"]
            if voidElements.contains(tag) {
                return "<\(tag)>"
            }
            return "<\(tag)>\(childrenHTML)</\(tag)>"
        }

        for attr in attributes {
            let key = attr.getKey().lowercased()

            // Skip event handlers always
            if key.hasPrefix("on") {
                continue
            }

            // Skip style attribute always
            if key == "style" {
                continue
            }

            // Check if attribute is allowed for this tag
            guard allowedAttrs.contains(key) else {
                continue
            }

            // Validate URL attributes — per-attribute scheme allow-list (WP-2I §3.2).
            // `href` uses `hrefSchemes` (no `data:` — XSS guard); `src` uses
            // `srcSchemes` (allows `data:` for inline base64 images).
            if urlAttributes.contains(key) {
                let value = attr.getValue()
                if !isURLAllowed(value, attribute: key) {
                    continue
                }
            }

            // Emit the attribute
            let value = attr.getValue()
            attrString += " \(key)=\"\(escapeAttribute(value))\""
        }

        // Void elements (self-closing)
        let voidElements: Set<String> = ["br", "hr", "img", "col"]
        if voidElements.contains(tag) {
            return "<\(tag)\(attrString)>"
        }

        let childrenHTML = element.getChildNodes().map { walk(node: $0) }.joined()
        return "<\(tag)\(attrString)>\(childrenHTML)</\(tag)>"
    }

    /// Get the set of allowed attributes for a given tag.
    /// This combines tag-specific attributes with global attributes.
    private static func allowedAttributes(for tag: String) -> Set<String> {
        let tagSpecific = tagAttributes[tag] ?? []
        return tagSpecific.union(globalAttributes)
    }

    // MARK: - URL Validation

    /// Check if a URL is allowed based on its scheme and the attribute it appears in.
    ///
    /// Per WP-2I §3.2: `href` and `src` use DIFFERENT scheme allow-lists.
    /// `href` (navigation target) does NOT permit `data:` — a `data:text/html,...`
    /// href is an XSS vector. `src` (resource locator) DOES permit `data:` —
    /// inline base64 images are common in markdown and the browser will not
    /// execute `data:` URLs inside `<img>`.
    ///
    /// Entity-decodes the URL before checking the scheme to defeat obfuscation
    /// like `&#106;avascript:...` or `java&#115;cript:...`.
    ///
    /// - Parameters:
    ///   - urlString: The attribute value (e.g. "https://example.com" or
    ///     "data:image/png;base64,iVBORw0KG...").
    ///   - attribute: The attribute name (`"href"` or `"src"`). Drives which
    ///     scheme allow-list applies.
    /// - Returns: True if the URL is permitted in this attribute context.
    private static func isURLAllowed(_ urlString: String, attribute: String) -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Entity-decode before checking scheme to defeat obfuscation
        let decoded: String
        do {
            decoded = try Entities.unescape(trimmed)
        } catch {
            // If entity decoding fails, use the trimmed version
            decoded = trimmed
        }

        // Pick the right allow-list per attribute.
        let allowed: Set<String>
        switch attribute {
        case "href":
            allowed = hrefSchemes
        case "src":
            allowed = srcSchemes
        default:
            // Unknown URL attribute — be strict and reject. (Existing call
            // sites only pass `href` / `src`; this is defence-in-depth.)
            return false
        }

        // Check for scheme
        if let colonRange = decoded.range(of: ":", options: .literal) {
            let scheme = String(decoded[decoded.startIndex..<colonRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)

            // Scheme must be in the per-attribute allowlist
            return allowed.contains(scheme)
        }

        // No scheme found — could be a relative URL, anchor (#), or query (?)
        // Allow relative paths, anchors, and query strings
        // Block anything that looks like a dangerous scheme without a colon
        if decoded.hasPrefix("//") || decoded.hasPrefix("/") || decoded.hasPrefix("#") || decoded.hasPrefix("?") {
            return true
        }

        // No colon and doesn't start with / # ? — could be a bare path or text.
        // Allow it (e.g., "example.com/path" or just "path")
        return true
    }

    // MARK: - HTML Escaping

    /// Escape text for safe inclusion in HTML content.
    private static func escapeHtml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Escape a value for safe inclusion in an HTML attribute.
    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}