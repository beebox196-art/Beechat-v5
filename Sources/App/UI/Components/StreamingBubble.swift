import SwiftUI
import WebKit

/// Streaming bubble — renders the live AI response as it arrives.
///
/// When `FeatureFlags.htmlRenderingEnabled` is true (read from environment),
/// the streaming content is sanitized and rendered in a WebView for rich
/// formatting (bold, code, links, etc.). When false, plain Text is used as before.
///
/// The feature flag wraps the new path; if anything breaks, we flip it off and
/// we're back to plain text. Zero risk to the current chat experience.
struct StreamingBubble: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(FeatureFlags.self) var featureFlags
    let content: String

    /// WebView height, driven by ResizeObserver JS bridge.
    @State private var webViewHeight: CGFloat = 40 // sensible minimum for first paint

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bee")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))

                if featureFlags.htmlRenderingEnabled && !content.isEmpty {
                    // HTML path: markdown→HTML → sanitize → WebView render
                    MessageWebView(
                        html: HTMLSanitizer.sanitize(MarkdownToHTML.convert(content)),
                        themeTokens: themeManager.cssTokens,
                        fontScale: themeManager.fontScale,
                        height: $webViewHeight,
                        onLink: { url in
                            LinkPolicy.open(url)
                        }
                    )
                    .frame(height: webViewHeight)
                    // Cursor blink overlay — the WebView handles its own text,
                    // but we still show the blinking cursor to indicate streaming
                    .overlay(alignment: .bottomTrailing) {
                        Text("▌")
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.accentPrimary))
                            .opacity(cursorVisible ? 1 : 0)
                            .animation(themeManager.animation(.slow).repeatForever(autoreverses: true), value: cursorVisible)
                            .padding(.trailing, 4)
                            .padding(.bottom, 2)
                            .allowsHitTesting(false)
                    }
                } else {
                    // Plain text path (original behaviour)
                    HStack(spacing: 0) {
                        Text(content)
                            .font(themeManager.font(.body))
                            .textSelection(.enabled)

                        Text("▌")
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.accentPrimary))
                            .opacity(cursorVisible ? 1 : 0)
                            .animation(themeManager.animation(.slow).repeatForever(autoreverses: true), value: cursorVisible)
                    }
                }
            }
            .padding(.horizontal, themeManager.spacing(.lg))
            .padding(.vertical, themeManager.spacing(.md))
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: themeManager.radius(.xl), style: .continuous)
                    .fill(themeManager.color(.bgPanel))
            )
            .foregroundColor(themeManager.color(.textPrimary))
            .shadow(
                color: themeManager.color(.shadowMedium).opacity(0.1),
                radius: 4, x: 0, y: 2
            )
            .modifier(BubbleWidthModifier())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("AI is typing")
            .accessibilityHint("Content being generated")

            Spacer(minLength: 34)
        }
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.vertical, themeManager.spacing(.xs))
        .onAppear { cursorVisible = true }
    }

    @State private var cursorVisible = false
}