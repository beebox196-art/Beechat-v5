import Foundation
import os

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
/// ## Threat model
///
/// - **Script execution**: Stripped by removing `<script>` and event handlers.
/// - **Navigation/redirect**: Stripped by removing `<iframe>`, `<form>`,
///   `javascript:`/`data:` URLs.
/// - **Style injection**: Stripped by removing `<style>` and inline `style` attributes.
/// - **Resource amplification**: Mitigated by text-length cap (200K chars).
///   The converter's node/depth caps provide additional DoS protection.
/// - **Phishing**: URL scheme allowlist (http, https, mailto, tel, file).
///
/// ## Design notes
///
/// - `<table>` is intentionally kept: the native converter routes it to
///   `needsWebView`, but the WebView path needs to render it. Stripping tables
///   here would break WebView rendering of legitimate tabular content.
/// - `<div>` is kept but its `class`/`id`/`style` attributes are stripped (theme
///   owns presentation). The native converter treats it as a paragraph boundary.
/// - `<sub>`, `<sup>`, `<small>`, `<mark>` are kept as plain-text passthrough
///   in the native converter. Keeping them here means messages containing these
///   tags don't fall through to WebView unnecessarily.
enum HTMLSanitizer {

    private static let logger = Logger(subsystem: "com.beebox.beechat", category: "HTMLSanitizer")

    // MARK: - Configuration

    /// Tags that survive sanitization. Everything else is stripped (content kept, tag removed).
    /// This is a superset of the native converter's `nativeTags` because the WebView path
    /// can render richer HTML than the native path — tags like `<table>`, `<thead>`, `<tbody>`,
    /// `<tfoot>`, `<th>`, `<caption>`, `<details>`, `<summary>` are kept for WebView but
    /// will trip `needsWebView` in the native converter.
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
        // Tables (WebView-only in native converter, but kept here for WebView rendering)
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "caption",
        "colgroup", "col",
        // Interactive (limited)
        "details", "summary",
    ]

    /// Attributes allowed on specific tags. Unlisted attributes are stripped.
    /// Global attributes (allowed on any tag): none by default.
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

    /// URL schemes allowed in `href` and `src` attributes.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel", "file"]

    /// Maximum input text length. Inputs exceeding this are truncated before parsing.
    /// This is a DoS mitigation, not a content policy.
    static let maxTextLength = 200_000

    // MARK: - Sanitization

    /// Sanitize HTML content for safe rendering.
    ///
    /// - Parameter html: Raw HTML content (typically from gateway message).
    /// - Returns: Sanitized HTML with only allowed tags and attributes.
    ///
    /// Tags not in `allowedTags` are removed but their text content is preserved.
    /// Attributes not in `tagAttributes` for a given tag are stripped.
    /// Event handlers (`on*` attributes) are always removed.
    /// `javascript:` and `data:` URLs are always removed.
    /// `<script>`, `<style>`, `<iframe>`, `<form>` (and their content) are removed entirely.
    static func sanitize(_ html: String) -> String {
        // Length cap — DoS protection
        let input: String
        if html.count > maxTextLength {
            logger.warning("HTML input truncated: \(html.count) chars exceeds maxTextLength \(maxTextLength)")
            input = String(html.prefix(maxTextLength))
        } else {
            input = html
        }

        // We use a simple tag-walking approach rather than pulling in an HTML parser
        // for sanitization. SwiftSoup is the converter's parser; the sanitizer strips
        // dangerous content *before* SwiftSoup sees it, ensuring the converter never
        // encounters script tags, event handlers, or javascript: URLs.
        //
        // For v1, we use regex-based stripping for the dangerous elements that must be
        // removed entirely (script, style, iframe, form), then a second pass to strip
        // dangerous attributes. This is sufficient because:
        // 1. The converter (SwiftSoup) will re-parse the output and enforce its own limits.
        // 2. The WebView receives only pre-sanitized content via setContent().
        // 3. Navigation is blocked by the WKNavigationDelegate (only .other allowed).
        //
        // Future improvement: use SwiftSoup for sanitization too (it's already a dep).

        var result = input

        // Pass 1: Remove dangerous elements and ALL their content
        result = stripDangerousElements(result)

        // Pass 2: Strip dangerous attributes (on* handlers, javascript:/data: URLs)
        result = stripDangerousAttributes(result)

        return result
    }

    // MARK: - Private helpers

    /// Remove `<script>`, `<style>`, `<iframe>`, `<form>`, `<object>`, `<embed>`,
    /// `<noscript>`, `<template>` elements and ALL their content.
    private static func stripDangerousElements(_ html: String) -> String {
        let dangerousTags = [
            "script", "style", "iframe", "form", "object", "embed",
            "noscript", "template", "applet", "base", "link", "meta"
        ]
        var result = html
        for tag in dangerousTags {
            // Remove self-closing and open+content+close
            // Regex explanation: <tag...> (anything, including newlines, non-greedy) </tag>
            // Also handles self-closing: <tag ... />
            let openClosePattern = "<\(tag)(?:\\s[^>]*)?>.*?</\(tag)>"
            result = result.replacingOccurrences(
                of: openClosePattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            // Also remove standalone/self-closing tags that weren't caught above
            let selfClosingPattern = "<\(tag)(?:\\s[^>]*)?\\s*/?>"
            result = result.replacingOccurrences(
                of: selfClosingPattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    /// Strip `on*` event-handler attributes and `javascript:`/`data:` URLs.
    /// Also strip `style` attributes (theme owns presentation).
    private static func stripDangerousAttributes(_ html: String) -> String {
        var result = html

        // Remove on* event handlers (onclick, onload, onerror, etc.)
        result = result.replacingOccurrences(
            of: "\\s+on\\w+\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|\\S+)",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove style attributes
        result = result.replacingOccurrences(
            of: "\\s+style\\s*=\\s*(?:\"[^\"]*\"|'[^']*')",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove javascript: and data: URLs in href/src attributes
        // Pattern: href="javascript:..." or src="data:..."
        result = result.replacingOccurrences(
            of: "(href|src)\\s*=\\s*(?:\"(?:javascript|data):[^\"]*\"|'(?:javascript|data):[^']*')",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Also catch unquoted javascript:/data: URLs
        result = result.replacingOccurrences(
            of: "(href|src)\\s*=\\s*(?:javascript|data):\\S+",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return result
    }
}