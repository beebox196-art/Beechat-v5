import SwiftUI
import BeeChatPersistence

struct MessageContent: View {
    @Environment(ThemeManager.self) var themeManager
    let message: Message

    /// Cached conversion result. Computed once on first render (or when
    /// message.content changes), then reused. When the flag is OFF this
    /// stays nil and the existing FileLinkText path runs unchanged.
    @State private var converted: ConvertedMessage?

    var body: some View {
        if FeatureFlags.shared.htmlRenderingEnabled,
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
        // Sanitize once, convert once, cache the result.
        let conversion = converted ?? {
            let sanitized = HTMLSanitizer.sanitize(content)
            return HTMLMessageConverter.convert(sanitized)
        }()

        if conversion.needsWebView {
            // Content exceeds native subset (tables, unknown tags, resource caps).
            // Render the original sanitized HTML via WebView.
            let sanitized = HTMLSanitizer.sanitize(content)
            MessageWebView(
                html: sanitized,
                themeTokens: themeManager.cssTokens,
                fontScale: themeManager.fontScale,
                height: .constant(0), // settled message uses intrinsic sizing
                onLink: { url in
                    // TODO: Wire through FileLinkText's OpenURLAction policy.
                    // Currently uses NSWorkspace.shared.open as stopgap.
                    if let scheme = url.scheme,
                       HTMLSanitizer.allowedSchemes.contains(scheme.lowercased()) {
                        #if os(macOS)
                        NSWorkspace.shared.open(url)
                        #endif
                    }
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
                .onAppear {
                    if converted == nil { converted = conversion }
                }
        }
    }
}