import Foundation
import os
import cmark_gfm
import cmark_gfm_extensions

/// Converts CommonMark + GFM markdown to HTML using cmark-gfm.
///
/// This is the **first step** in the rendering pipeline, before sanitization:
///
///     raw content → MarkdownToHTML.convert() → HTMLSanitizer.sanitize() → render
///
/// ## Why cmark-gfm?
///
/// Agents emit markdown. The rendering pipeline was originally built for HTML,
/// so without this step, markdown symbols (like `**bold**`, `# heading`) show
/// as raw text. cmark-gfm is the GitHub-flavored markdown engine — it's what
/// GitHub uses, it handles tables, strikethrough, autolinks, and task lists,
/// and it's maintained by Apple as part of the Swift project.
///
/// ## Security model
///
/// `CMARK_OPT_UNSAFE` is ON. This means raw HTML embedded in markdown passes
/// through cmark untouched. Safety is enforced **downstream** by
/// `HTMLSanitizer` (SwiftSoup-based allowlist). This split is deliberate:
/// cmark is responsible for *format conversion*, the sanitizer is responsible
/// for *security*. The old regex sanitizer could not be trusted with this; the
/// new SwiftSoup sanitizer can.
///
/// ## GFM extensions
///
/// Enabled: table, strikethrough, autolink, tasklist. These match what
/// GitHub-flavored markdown supports and are non-negotiable for agent output.
///
/// ## Smart punctuation
///
/// OFF. Agents and code produce ASCII punctuation; smart quotes and em-dashes
/// would be a surprising transformation.
enum MarkdownToHTML {

    private static let logger = Logger(subsystem: "com.beebox.beechat", category: "MarkdownToHTML")

    // MARK: - cmark option flags

    /// Options passed to cmark-gfm. UNSAFE is on so raw HTML in markdown
    /// passes through for the sanitizer to handle. SMART is deliberately off.
    private static let cmarkOptions: Int32 = Int32(CMARK_OPT_UNSAFE)

    // MARK: - GFM extension names

    private static let gfmExtensionNames = ["table", "strikethrough", "autolink", "tasklist"]

    // MARK: - Thread-safe initialization

    /// Ensure cmark_gfm_core_extensions_ensure_registered() is called exactly
    /// once. This is thread-safe via dispatch_once.
    private static let extensionsRegistration: Void = {
        cmark_gfm_core_extensions_ensure_registered()
    }()

    // MARK: - Public API

    /// Convert a markdown string to HTML.
    ///
    /// - Parameter markdown: Raw markdown content from an agent message.
    ///   May also contain HTML (which passes through with UNSAFE enabled).
    /// - Returns: HTML string suitable for `HTMLSanitizer.sanitize()`.
    ///   Returns empty string for empty input.
    ///
    /// The conversion uses GFM extensions (table, strikethrough, autolink,
    /// tasklist) and the `CMARK_OPT_UNSAFE` flag so that raw HTML in the
    /// markdown input is preserved for downstream sanitization.
    static func convert(_ markdown: String) -> String {
        guard !markdown.isEmpty else { return "" }

        // Ensure extensions are registered (once, thread-safe)
        _ = extensionsRegistration

        let utf8 = markdown.utf8
        let len = utf8.count

        // Create parser with our options
        guard let parser = cmark_parser_new(cmarkOptions) else {
            logger.error("cmark_parser_new returned nil")
            return ""
        }
        defer { cmark_parser_free(parser) }

        // Attach GFM extensions
        for name in gfmExtensionNames {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            } else {
                logger.warning("cmark-gfm extension not found: \(name)")
            }
        }

        // Feed the markdown to the parser
        let buffer = Array(markdown.utf8)
        buffer.withUnsafeBufferPointer { bufPtr in
            // cmark_parser_feed takes (buffer, len) and handles
            // non-null-terminated input correctly.
            cmark_parser_feed(parser, bufPtr.baseAddress, len)
        }

        // Parse the document
        guard let document = cmark_parser_finish(parser) else {
            logger.error("cmark_parser_finish returned nil")
            return ""
        }
        defer { cmark_node_free(document) }

        // Get the syntax extensions list from the parser for rendering
        let extensions = cmark_parser_get_syntax_extensions(parser)

        // Render to HTML
        guard let htmlPtr = cmark_render_html(document, cmarkOptions, extensions) else {
            logger.error("cmark_render_html returned nil")
            return ""
        }
        defer { free(htmlPtr) }

        let html = String(cString: htmlPtr)
        return html
    }
}