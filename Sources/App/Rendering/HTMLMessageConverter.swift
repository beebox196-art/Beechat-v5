// Reference scaffold for BeeChat-v5 — the primary build effort under the native-first path.
// Requires SwiftSoup; add to Package.swift dependencies:
//   .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0")
// and "SwiftSoup" to the App target. Runs off-main at message ingest; cache the result
// (in-memory keyed by message id, or a GRDB column) so conversion happens once per message.
#if canImport(SwiftSoup)

import CryptoKit
import Foundation
import os
import SwiftSoup
import SwiftUI // underlineStyle attribute scope; the block model is UI-adjacent anyway

/// Block-level output model. A single AttributedString cannot carry code blocks with
/// backgrounds, native async images, or per-block styling — so the converter emits
/// blocks and the bubble renders them as stacked SwiftUI views (sketch at bottom).
/// Inline styling is *semantic* (PresentationIntent), so ThemeManager fonts/colors
/// apply at render time and theme switches restyle without reconverting.
enum MessageBlock: Equatable {
    case paragraph(AttributedString)
    case heading(level: Int, text: AttributedString)
    case codeBlock(language: String?, code: String)
    case quote(blocks: [MessageBlock])
    case list(ordered: Bool, items: [[MessageBlock]])
    case image(source: URL, alt: String)
    case rule
}

struct ConvertedMessage: Equatable {
    let blocks: [MessageBlock]
    /// true → content exceeds the native subset (tables, unknown tags, resource caps).
    /// The bubble should render the *original sanitized HTML* via MessageWebView instead.
    let needsWebView: Bool
}

enum HTMLMessageConverter {

    private static let logger = Logger(subsystem: "com.beebox.beechat", category: "HTMLMessageConverter")

    // MARK: Native subset

    /// Tags the converter maps with full fidelity. Anything else trips needsWebView —
    /// deliberately including <table>: attributed strings cannot do grid layout.
    /// <div> is treated as a paragraph boundary; its class/id/style attributes are
    /// dropped by design (theme owns presentation). <sub>/<sup>/<small>/<mark> are
    /// plain-text passthrough (content kept, effect dropped) — pinned by matrix C19.
    private static let nativeTags: Set<String> = [
        "p", "div", "br", "b", "strong", "i", "em", "s", "del", "strike", "u",
        "code", "a", "span", "h1", "h2", "h3", "h4", "h5", "h6",
        "ul", "ol", "li", "blockquote", "pre", "img", "hr",
        "sub", "sup", "small", "mark",
    ]

    /// Parsing untrusted input: caps are DoS protection, not style policy.
    /// Exceeding any cap falls through to the web view (which WebKit hardens for us).
    private static let maxNodes = 5_000
    private static let maxDepth = 32
    /// Maximum input text length. Inputs exceeding this are truncated before parsing.
    /// This is a DoS mitigation, not a content policy.
    static let maxTextLength = 200_000
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "tel", "file"]

    /// Number of SHA-256 bytes to keep when logging content identity (4 bytes = 8 hex chars).
    /// Sufficient to distinguish distinct HTML strings within a single conversation; collision
    /// rate is negligible at the bail-out warning sites (1–78 fires / 26 min in the v0.9.5e
    /// session). Log-safe: pure ASCII hex, no PII.
    private static let hashLogBytes = 4

    /// SHA-256 → first 4 bytes as 8 hex chars. In-process stable (no per-launch seed).
    /// Used to label bail-out warnings so expected re-entry reconversion can be
    /// distinguished from identity churn without topic switches.
    private static func shortContentHash(_ s: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(s.utf8))
        let digest = hasher.finalize()
        return digest.prefix(hashLogBytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Entry point

    static func convert(_ sanitizedHTML: String) -> ConvertedMessage {
        guard sanitizedHTML.count <= maxTextLength else {
            logger.warning("HTML exceeds maxTextLength (\(sanitizedHTML.count)/\(maxTextLength)) — falling back to WebView [hash:\(Self.shortContentHash(sanitizedHTML))]")
            return ConvertedMessage(blocks: [], needsWebView: true)
        }
        guard let doc = try? SwiftSoup.parseBodyFragment(sanitizedHTML),
              let body = doc.body()
        else {
            logger.error("SwiftSoup parse failed — falling back to WebView")
            return ConvertedMessage(blocks: [], needsWebView: true)
        }

        var state = WalkState()
        let blocks = convertChildren(of: body, depth: 0, state: &state)
        if state.bailedOut {
            logger.warning("HTML walk bailed out (nodes/depth cap exceeded) — falling back to WebView [hash:\(Self.shortContentHash(sanitizedHTML))]")
            return ConvertedMessage(blocks: [], needsWebView: true)
        }
        return ConvertedMessage(blocks: blocks, needsWebView: false)
    }

    private struct WalkState {
        var nodeCount = 0
        var bailedOut = false
        mutating func visit(depth: Int) -> Bool {
            nodeCount += 1
            if nodeCount > maxNodes || depth > maxDepth { bailedOut = true }
            return !bailedOut
        }
    }

    // MARK: Block walk

    private static func convertChildren(of element: Element, depth: Int,
                                        state: inout WalkState) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var pendingInline = AttributedString()

        func flushInline() {
            let trimmed = pendingInline.trimmedWhitespace()
            if !trimmed.characters.isEmpty { blocks.append(.paragraph(trimmed)) }
            pendingInline = AttributedString()
        }

        for node in element.getChildNodes() {
            guard state.visit(depth: depth) else { return blocks }

            if let text = node as? TextNode {
                pendingInline += AttributedString(text.text().collapsedWhitespace())
                continue
            }
            guard let child = node as? Element else { continue }
            let tag = child.tagName().lowercased()

            guard nativeTags.contains(tag) else { state.bailedOut = true; return blocks }

            switch tag {
            case "p", "div":
                flushInline()
                let inner = buildInline(child, depth: depth + 1, state: &state)
                    .trimmedWhitespace()
                if !inner.characters.isEmpty { blocks.append(.paragraph(inner)) }
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flushInline()
                let level = Int(String(tag.dropFirst())) ?? 6
                blocks.append(.heading(level: level,
                                       text: buildInline(child, depth: depth + 1, state: &state)))
            case "pre":
                flushInline()
                // <pre><code class="language-swift"> convention. Mixed content inside
                // <pre> (e.g. <b> spans from server-side highlighting) is flattened to
                // its raw text — markup inside code blocks is not preserved natively;
                // if styled code matters, that message belongs on the WebView path.
                // NOTE: this path uses rawText (whitespace-preserving), never
                // collapsedWhitespace() — <pre> is exempt from HTML whitespace collapse.
                let codeEl = (try? child.select("code").first()) ?? nil
                let lang = codeEl.flatMap { el -> String? in
                    let cls = (try? el.className()) ?? ""
                    return cls.split(separator: " ")
                        .first { $0.hasPrefix("language-") }
                        .map { String($0.dropFirst("language-".count)) }
                }
                let code = rawText(codeEl ?? child)
                blocks.append(.codeBlock(language: lang,
                                         code: code.trimmingCharacters(in: .newlines)))
            case "blockquote":
                flushInline()
                blocks.append(.quote(blocks: convertChildren(of: child, depth: depth + 1,
                                                             state: &state)))
            case "ul", "ol":
                flushInline()
                let items = child.children().array()
                    .filter { $0.tagName().lowercased() == "li" }
                    .map { convertChildren(of: $0, depth: depth + 1, state: &state) }
                blocks.append(.list(ordered: tag == "ol", items: items))
            case "img":
                flushInline()
                let src = (try? child.attr("src")) ?? ""
                let alt = (try? child.attr("alt")) ?? ""
                if let url = URL(string: src),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    blocks.append(.image(source: url, alt: alt))
                } else if !alt.isEmpty {
                    blocks.append(.paragraph(AttributedString(alt)))
                } // data:/file: images: policy decision — currently dropped
            case "hr":
                flushInline()
                blocks.append(.rule)
            case "br":
                pendingInline += AttributedString("\n")
            default:
                // Inline tag at block level (bare <b>Hello</b> message)
                pendingInline += buildInline(child, depth: depth + 1, state: &state)
            }
        }
        flushInline()
        return blocks
    }

    // MARK: Inline walk

    private static func buildInline(_ element: Element, depth: Int,
                                    state: inout WalkState) -> AttributedString {
        var result = AttributedString()
        for node in element.getChildNodes() {
            guard state.visit(depth: depth) else { return result }

            if let text = node as? TextNode {
                result += AttributedString(text.text().collapsedWhitespace())
                continue
            }
            guard let child = node as? Element else { continue }
            let tag = child.tagName().lowercased()
            guard nativeTags.contains(tag) else { state.bailedOut = true; return result }

            var inner = buildInline(child, depth: depth + 1, state: &state)
            switch tag {
            // InlinePresentationIntent is a single OptionSet attribute: it must be
            // UNIONED per run, not assigned, or <b><i>x</i></b> loses the italic.
            case "b", "strong":
                addIntent(.stronglyEmphasized, to: &inner)
            case "i", "em":
                addIntent(.emphasized, to: &inner)
            case "s", "del", "strike":
                addIntent(.strikethrough, to: &inner)
            case "u":
                inner.underlineStyle = .single
            case "code":
                addIntent(.code, to: &inner)
            case "a":
                let href = (try? child.attr("href")) ?? ""
                if let url = URL(string: href),
                   allowedLinkSchemes.contains(url.scheme?.lowercased() ?? "") {
                    // file: URLs flow into FileLinkText's existing OpenURLAction policy
                    inner.link = url
                }
            case "br":
                inner = AttributedString("\n")
            case "img":
                // Inline images degrade to alt text; block images are handled above
                inner = AttributedString((try? child.attr("alt")) ?? "")
            default:
                break // span/sub/sup/small/mark: transparent wrapper, content kept
            }
            result += inner
        }
        return result
    }

    /// Unions an intent into every run — see comment at call sites.
    private static func addIntent(_ intent: InlinePresentationIntent,
                                  to string: inout AttributedString) {
        for run in string.runs {
            let existing = string[run.range].inlinePresentationIntent ?? []
            string[run.range].inlinePresentationIntent = existing.union(intent)
        }
    }

    /// Whitespace-preserving text extraction for <pre> content (SwiftSoup's text()
    /// collapses newlines). Descends through any inline markup, flattening it.
    private static func rawText(_ node: Node) -> String {
        if let text = node as? TextNode { return text.getWholeText() }
        guard let element = node as? Element else { return "" }
        if element.tagName().lowercased() == "br" { return "\n" }
        return element.getChildNodes().map(rawText).joined()
    }
}

private extension String {
    /// HTML whitespace semantics: runs of whitespace collapse to one space, but a
    /// boundary space must survive so "<b>bold</b> text" doesn't become "boldtext".
    /// NOTE: only used on the inline/paragraph path — <pre> content bypasses this
    /// entirely via rawText(), which preserves whitespace verbatim.
    func collapsedWhitespace() -> String {
        let collapsed = components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return isEmpty ? "" : " " }
        let lead = first?.isWhitespace == true ? " " : ""
        let trail = last?.isWhitespace == true ? " " : ""
        return lead + collapsed + trail
    }
}

private extension AttributedString {
    func trimmedWhitespace() -> AttributedString {
        var copy = self
        while let f = copy.characters.first, f.isWhitespace {
            copy.characters.removeFirst()
        }
        while let l = copy.characters.last, l.isWhitespace {
            copy.characters.removeLast()
        }
        return copy
    }
}

// MARK: - Render sketch (for MessageContent integration)
//
//  struct ConvertedMessageView: View {
//      @Environment(ThemeManager.self) var theme
//      let converted: ConvertedMessage
//      var body: some View {
//          VStack(alignment: .leading, spacing: 6) {
//              ForEach(converted.blocks.indices, id: \.self) { i in
//                  switch converted.blocks[i] {
//                  case .paragraph(let text):
//                      Text(text).font(theme.font(.body)).textSelection(.enabled)
//                  case .codeBlock(_, let code):
//                      ScrollView(.horizontal) { Text(code).font(theme.font(.mono)) }
//                          .padding(8).background(theme.color(.codeBg)).cornerRadius(8)
//                  case .image(let url, let alt):
//                      AsyncImage(url: url) { $0.resizable().scaledToFit() }
//                          placeholder: { Text(alt) }
//                  // .heading/.quote/.list/.rule analogous — theme tokens at render time
//                  default: EmptyView()
//                  }
//              }
//          }
//      }
//  }
//
//  MessageContent becomes:
//    converted.needsWebView ? MessageWebView(html:…)  : ConvertedMessageView(converted:…)

#endif
