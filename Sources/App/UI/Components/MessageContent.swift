import SwiftUI
import BeeChatPersistence

struct MessageContent: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(FeatureFlags.self) var featureFlags
    let message: Message

    /// Cached conversion result. Computed once on first render (or when
    /// message.content changes), then reused. When the flag is OFF this
    /// stays nil and the existing FileLinkText path runs unchanged.
    @State private var converted: ConvertedMessage?
    /// WebView height binding for settled messages that need the WebView path.
    /// ResizeObserver JS writes the measured content height here, exactly like
    /// StreamingBubble's $webViewHeight — without a real binding the WebView
    /// collapses to zero height.
    @State private var settledWebViewHeight: CGFloat = 40

    var body: some View {
        if featureFlags.htmlRenderingEnabled,
           let content = message.content, !content.isEmpty {
            htmlRenderingPath(content: content)
        } else if let content = message.content, !content.isEmpty {
            // Flag OFF: existing plain-text path — completely unchanged
            FileLinkText(content: content)
                .font(themeManager.font(.body))
                .textSelection(.enabled)
        } else {
            Text(" ")
                .font(themeManager.font(.body))
        }
    }

    // MARK: - HTML Rendering Path

    @ViewBuilder
    private func htmlRenderingPath(content: String) -> some View {
        // Convert markdown→HTML, then sanitize, then convert to native blocks.
        // Pipeline: content → MarkdownToHTML → HTMLSanitizer → HTMLMessageConverter
        let conversion = converted ?? {
            let htmlContent = MarkdownToHTML.convert(content)
            let sanitized = HTMLSanitizer.sanitize(htmlContent)
            return HTMLMessageConverter.convert(sanitized)
        }()

        if conversion.needsWebView {
            // Content exceeds native subset (tables, unknown tags, resource caps).
            // Render the original sanitized HTML via WebView.
            //
            // BUG FIX: Previously used height: .constant(0) which created a read-only
            // binding that always returned 0 and silently discarded ResizeObserver writes.
            // This caused the WebView to collapse to zero height, making messages vanish
            // on completion (only the timestamp remained visible). Now uses a real
            // @State binding, identical to StreamingBubble's pattern.
            let htmlContent = MarkdownToHTML.convert(content)
            let sanitized = HTMLSanitizer.sanitize(htmlContent)
            MessageWebView(
                html: sanitized,
                themeTokens: themeManager.cssTokens,
                fontScale: themeManager.fontScale,
                height: $settledWebViewHeight,
                onLink: { url in
                    LinkPolicy.open(url)
                }
            )
            .onAppear {
                if converted == nil { converted = conversion }
            }
        } else if conversion.blocks.isEmpty {
            // Conversion produced no blocks (e.g. empty content after sanitization).
            // Fall back to plain text.
            FileLinkText(content: content)
                .font(themeManager.font(.body))
                .textSelection(.enabled)
        } else {
            ConvertedMessageView(converted: conversion)
                .environment(\.openURL, OpenURLAction { url in
                    LinkPolicy.open(url)
                    return .handled
                })
                .onAppear {
                    if converted == nil { converted = conversion }
                }
        }
    }
}