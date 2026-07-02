import SwiftUI
import BeeChatPersistence

/// Scrollable message canvas — displays messages and typing indicator.
///
/// Scroll philosophy (v4, 2026-06-01): `defaultScrollAnchor(.bottom)` handles auto-scroll
/// natively. The only manual scroll is "Jump to Latest" (user-initiated).
///
/// Streaming poll is throttled to ~5fps (200ms) to reduce SwiftUI layout recalculations.
/// The StreamingBubble expands naturally in the VStack; no height feedback loop is used.
struct MessageCanvas: View {
    @Environment(ThemeManager.self) var themeManager

    let messages: [Message]
    let isStreaming: Bool
    var streamingContent: String = ""
    /// Bridge content from SyncBridgeObserver.completedContent — the final response
    /// captured when streaming ends. Fills the gap between streaming stopping and
    /// GRDB delivering the settled message to the UI.
    var completedContent: String = ""
    var thinkingState: ThinkingState = .idle
    var canLoadEarlier: Bool = false
    var topicId: String? = nil
    var onLoadEarlier: () -> Void = {}

    private var showStreamingBubble: Bool {
        guard !streamingContent.isEmpty else { return false }
        if let lastAssistant = messages.last(where: { $0.role == "assistant" }),
           let content = lastAssistant.content,
           !content.isEmpty,
           content == streamingContent {
            return false
        }
        return true
    }

    /// Whether to show the completed-content bridge bubble.
    /// This fills the gap between streaming ending (isStreaming=false) and
    /// GRDB delivering the settled message to the messages array.
    private var showCompletedBridge: Bool {
        guard !isStreaming, !completedContent.isEmpty else { return false }
        // Only show if the last assistant message is missing or has stale content
        if let lastAssistant = messages.last(where: { $0.role == "assistant" }),
           let content = lastAssistant.content, !content.isEmpty {
            // The settled message already has content — bridge not needed
            return false
        }
        return true
    }

    @State private var isAtBottom: Bool = true
    @State private var measuredWidth: CGFloat = 1200
    @State private var anchorMessageId: String? = nil

    var body: some View {
        ZStack {
            themeManager.color(.bgSurface)
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        if canLoadEarlier {
                            Button(action: {
                                anchorMessageId = messages.first?.id
                                onLoadEarlier()
                            }) {
                                HStack {
                                    Spacer()
                                    Text("Load earlier messages")
                                        .font(themeManager.font(.caption))
                                        .foregroundStyle(themeManager.color(.textSecondary))
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            .id("load-earlier")
                        }

                        ForEach(messages, id: \.id) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if thinkingState == .thinking {
                            ThinkingBeeIndicator(mode: .thinking)
                                .id("thinking-bee")
                        } else if isStreaming && streamingContent.isEmpty {
                            // Suppress TypingIndicator during thinking→streaming transition
                            if thinkingState != .streaming {
                                TypingIndicator()
                                    .id("typing-indicator")
                            }
                        } else if showStreamingBubble {
                            StreamingBubble(content: streamingContent)
                                .id("streaming-bubble")
                        }

                        // Completed-content bridge bubble: fills the gap between
                        // streaming ending and GRDB delivering the settled message.
                        // Renders identically to a settled assistant message.
                        if showCompletedBridge {
                            CompletedBridgeBubble(content: completedContent)
                                .id("completed-bridge")
                        }

                        // 4px anchor — enough for LazyVStack to render reliably,
                        // invisible to the user. 8px was visibly too tall (white space).
                        Color.clear
                            .frame(height: 4)
                            .id("bottom-anchor")
                    }
                }
                .scrollContentBackground(.hidden)
                .defaultScrollAnchor(.bottom)
                .scrollBounceBehaviorCompat(axes: .vertical)
                .onScrollGeometryChangeCompat(
                    transform: { geo in
                        guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
                            return true
                        }
                        // Simple threshold: within 80px of bottom = at bottom
                        let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                        return distanceFromBottom < 80
                    },
                    action: { _, newValue in
                        isAtBottom = newValue
                    }
                )
                .background(
                    WidthReader { width in
                        Color.clear
                            .preference(key: WidthPreferenceKey.self, value: width)
                    }
                )
                .onPreferenceChange(WidthPreferenceKey.self) { newWidth in
                    measuredWidth = newWidth
                }

                // Manual scrolls: load-earlier anchor, topic switch, and appear
                .onChange(of: anchorMessageId) { _, newId in
                    if let anchorId = newId {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(anchorId, anchor: .top)
                        }
                        anchorMessageId = nil
                    }
                }
                .onChange(of: topicId) { _, _ in
                    // defaultScrollAnchor(.bottom) handles initial positioning.
                    // The asyncAfter nudge fights with it and can cause bounce — removed.
                }
                .overlay(alignment: .bottomTrailing) {
                    jumpToLatestButton(proxy: proxy)
                }
            }
            .environment(\.canvasWidth, measuredWidth)
        }
        .frame(maxHeight: .infinity)
    }

    /// Jump-to-Latest button — fixed-size overlay, opacity-only transitions.
    /// Takes the ScrollViewProxy directly so it works even though the button
    /// lives outside the ScrollViewReader closure.
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Color.clear
            .frame(width: 48, height: 48)
            .overlay {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                    isAtBottom = true
                }) {
                    Image(systemName: "chevron.down")
                        .font(themeManager.font(.body))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to latest message")
                .accessibilityHint("Scrolls to the most recent message")
                .opacity(isAtBottom ? 0 : 1)
                .allowsHitTesting(!isAtBottom)
                .accessibilityHidden(isAtBottom)
            }
            .padding(.bottom, 12)
            .padding(.trailing, 12)
    }
}

private struct WidthReader<Content: View>: View {
    var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { geometry in
            self.content(geometry.size.width)
        }
    }
}

/// Preference key for passing measured width up the view hierarchy.
private struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 1200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Scroll Geometry Compatibility (macOS 14+)

/// Compatibility wrapper for `onScrollGeometryChange` which requires macOS 15+.
/// On macOS 14, `isAtBottom` stays true (Jump button hidden, auto-scroll still works
/// via `defaultScrollAnchor(.bottom)`).
struct ScrollGeometry {
    var contentSize: CGSize
    var containerSize: CGSize
    var contentOffset: CGPoint
}

extension View {
    /// On macOS 15+/iOS 18+: uses native `onScrollGeometryChange` with two-closure pattern.
    /// On older platforms: leaves state unchanged (auto-scroll via `defaultScrollAnchor(.bottom)` still works).
    @ViewBuilder
    func onScrollGeometryChangeCompat(
        transform: @escaping (ScrollGeometry) -> Bool,
        action: @escaping (_ oldValue: Bool, _ newValue: Bool) -> Void
    ) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geo in
                let sg = ScrollGeometry(
                    contentSize: geo.contentSize,
                    containerSize: geo.containerSize,
                    contentOffset: geo.contentOffset
                )
                return transform(sg)
            } action: { oldValue, newValue in
                action(oldValue, newValue)
            }
        } else {
            // macOS 14 fallback: no onScrollGeometryChange available.
            // defaultScrollAnchor(.bottom) handles auto-scroll.
            // isAtBottom stays true (Jump button hidden).
            self
        }
    }

    @ViewBuilder
    func scrollBounceBehaviorCompat(axes: Axis.Set) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            self.scrollBounceBehavior(.basedOnSize, axes: axes)
        } else {
            self
        }
    }
}

/// Completed-content bridge bubble — renders final assistant content as a settled
/// message during the gap between streaming ending and GRDB delivering the update.
/// Uses the same styling as a regular assistant MessageBubble but without a cursor
/// or streaming indicator. Disappears as soon as the GRDB observation delivers the
/// settled message (completedContent is cleared by MainWindow).
struct CompletedBridgeBubble: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(FeatureFlags.self) var featureFlags
    let content: String

    /// WebView height binding for rich content (same pattern as MessageContent).
    @State private var webViewHeight: CGFloat = 40

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bee")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))

                if featureFlags.htmlRenderingEnabled && !content.isEmpty {
                    // Rich HTML path — same rendering pipeline as MessageContent
                    let htmlContent = MarkdownToHTML.convert(content)
                    let sanitized = HTMLSanitizer.sanitize(htmlContent)
                    let conversion = HTMLMessageConverter.convert(sanitized)

                    if conversion.needsWebView {
                        MessageWebView(
                            html: sanitized,
                            themeTokens: themeManager.cssTokens,
                            fontScale: themeManager.fontScale,
                            height: $webViewHeight,
                            onLink: { url in LinkPolicy.open(url) }
                        )
                    } else if !conversion.blocks.isEmpty {
                        ConvertedMessageView(converted: conversion)
                            .environment(\.openURL, OpenURLAction { url in
                                LinkPolicy.open(url)
                                return .handled
                            })
                    } else {
                        FileLinkText(content: content)
                            .font(themeManager.font(.body))
                            .textSelection(.enabled)
                    }
                } else {
                    // Plain text path
                    FileLinkText(content: content)
                        .font(themeManager.font(.body))
                        .textSelection(.enabled)
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
            .accessibilityLabel("Assistant message")

            Spacer(minLength: 34)
        }
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.vertical, themeManager.spacing(.xs))
    }
}
