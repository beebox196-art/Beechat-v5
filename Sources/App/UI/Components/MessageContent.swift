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
    @State private var settledWebViewHeight: CGFloat

    /// Custom init seeds the @State from `WebViewHeightCache`. Settled bubbles
    /// we've measured before mount at their true height instead of the 40pt
    /// floor; first-time bubbles still fall back to 40 until the WebView spins
    /// up and the transactional reporter writes the honest value.
    init(message: Message) {
        self.message = message
        _settledWebViewHeight = State(initialValue:
            WebViewHeightCache.shared.seed(id: message.id) ?? 40)
    }

    var body: some View {
        if featureFlags.htmlRenderingEnabled,
           let content = message.content, !content.isEmpty {
            htmlRenderingPath(content: content)
        } else if let content = message.content, !content.isEmpty {
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
            let result = HTMLMessageConverter.convert(sanitized)
            return result
        }()

        if conversion.needsWebView {
            // Content exceeds native subset (tables, unknown tags, resource caps).
            // Render the original sanitized HTML via WebView.
            let htmlContent = MarkdownToHTML.convert(content)
            let sanitized = HTMLSanitizer.sanitize(htmlContent)
            MessageWebView(
                html: sanitized,
                themeTokens: themeManager.cssTokens,
                fontScale: themeManager.fontScale,
                height: $settledWebViewHeight,
                onLink: { url in
                    LinkPolicy.open(url)
                },
                cacheKey: message.id
            )
            .frame(height: settledWebViewHeight)
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