import SwiftUI

/// Native SwiftUI view that renders a `ConvertedMessage`'s block array
/// using theme tokens — no hardcoded sizes, fontScale works.
///
/// This is the settled-message companion to StreamingBubble's WebView path.
/// Conversion happens once at settle time (off-main thread), and the result
/// is cached. This view only reads it.
///
/// ## Known regression (P0 accepted)
/// Per-block `Text` means cross-block selection breaks vs today's single
/// `FileLinkText`. This is a conscious trade-off for native rendering
/// (accessibility wins: `.isHeader` on headings, theme tokens, fontScale).
/// A future step should add a "copy full text" action to compensate.
///
/// ## Known gap (not this step)
/// Markdown input with the flag ON shows literal asterisks — that needs a
/// markdown→HTML step, which is out of scope for Step 3.
struct ConvertedMessageView: View {
    @Environment(ThemeManager.self) var themeManager
    let converted: ConvertedMessage

    var body: some View {
        VStack(alignment: .leading, spacing: themeManager.spacing(.sm)) {
            ForEach(Array(converted.blocks.enumerated()), id: \.offset) { _, block in
                blockView(for: block)
            }
        }
    }

    @ViewBuilder
    private func blockView(for block: MessageBlock) -> some View {
        switch block {
        case .paragraph(let text):
            paragraphView(text)
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .codeBlock(let language, let code):
            codeBlockView(language: language, code: code)
        case .quote(let blocks):
            quoteView(blocks: blocks)
        case .list(let ordered, let items):
            listView(ordered: ordered, items: items)
        case .image(let source, let alt):
            imageView(source: source, alt: alt)
        case .rule:
            ruleView
        }
    }

    // MARK: - Paragraph

    private func paragraphView(_ text: AttributedString) -> some View {
        Text(text)
            .font(themeManager.font(.body))
            .textSelection(.enabled)
    }

    // MARK: - Heading

    private func headingView(level: Int, text: AttributedString) -> some View {
        let token: TypographyToken = {
            switch level {
            case 1: return .display
            case 2: return .heading
            case 3: return .subheading
            default: return .body
            }
        }()

        return Text(text)
            .font(themeManager.font(token))
            .textSelection(.enabled)
            .accessibilityHeading(headingLevel(for: level))
    }

    // MARK: - Code Block

    private func codeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))
                    .padding(.horizontal, themeManager.spacing(.sm))
                    .padding(.top, themeManager.spacing(.xs))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(themeManager.font(.mono))
                    .textSelection(.enabled)
                    .padding(.horizontal, themeManager.spacing(.sm))
                    .padding(.vertical, themeManager.spacing(.sm))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.color(.bgPanel))
        .clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
                .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
        )
        .contextMenu {
            Button("Copy Code") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                #endif
            }
        }
    }

    // MARK: - Block Quote

    private func quoteView(blocks: [MessageBlock]) -> some View {
        HStack(spacing: themeManager.spacing(.sm)) {
            RoundedRectangle(cornerRadius: 2)
                .fill(themeManager.color(.accentPrimary))
                .frame(width: 4)

            ConvertedMessageView(converted: ConvertedMessage(blocks: blocks, needsWebView: false))
        }
        .padding(.leading, themeManager.spacing(.sm))
    }

    // MARK: - List

    private func listView(ordered: Bool, items: [[MessageBlock]]) -> some View {
        VStack(alignment: .leading, spacing: themeManager.spacing(.xs)) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, subblocks in
                HStack(alignment: .top, spacing: themeManager.spacing(.xs)) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(themeManager.font(.body))
                        .foregroundColor(themeManager.color(.textSecondary))
                        .frame(minWidth: ordered ? 24 : 12, alignment: .trailing)

                    ConvertedMessageView(converted: ConvertedMessage(blocks: subblocks, needsWebView: false))
                }
            }
        }
    }

    // MARK: - Image

    private func imageView(source: URL, alt: String) -> some View {
        AsyncImage(url: source) { phase in
            switch phase {
            case .success(let image):
                image.resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.sm), style: .continuous))
            case .failure:
                Text(alt)
                    .font(themeManager.font(.caption))
                    .foregroundColor(themeManager.color(.textSecondary))
            case .empty:
                ProgressView()
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Horizontal Rule

    private var ruleView: some View {
        Divider()
            .overlay(themeManager.color(.borderDefault))
            .padding(.vertical, themeManager.spacing(.xs))
    }
}

// MARK: - Accessibility Heading Level Helper

func headingLevel(for level: Int) -> AccessibilityHeadingLevel {
    switch level {
    case 1: return .h1
    case 2: return .h2
    case 3: return .h3
    case 4: return .h4
    case 5: return .h5
    default: return .h6
    }
}

// MARK: - Preview

#Preview("ConvertedMessageView") {
    let sample = ConvertedMessage(blocks: [
        .heading(level: 2, text: try! AttributedString(markdown: "Hello **World**")),
        .paragraph(try! AttributedString(markdown: "This is a paragraph with **bold** and *italic* text.")),
        .codeBlock(language: "swift", code: "let x = 42\nprint(x)"),
        .list(ordered: false, items: [
            [.paragraph(try! AttributedString(markdown: "First item"))],
            [.paragraph(try! AttributedString(markdown: "Second item"))],
        ]),
        .quote(blocks: [
            .paragraph(try! AttributedString(markdown: "A quoted passage")),
        ]),
        .rule,
    ], needsWebView: false)

    ConvertedMessageView(converted: sample)
        .environment(ThemeManager.shared)
}