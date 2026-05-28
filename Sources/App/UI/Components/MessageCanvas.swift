import SwiftUI
import BeeChatPersistence

/// Scrollable message canvas — displays messages and typing indicator.
///
/// Scroll philosophy (v3, 2026-05-28): `defaultScrollAnchor(.bottom)` handles
/// auto-scroll natively. The only manual scroll is "Jump to Latest" (user-initiated).
///
/// During streaming, the StreamingBubble grows every 50ms as content arrives. This
/// causes LazyVStack to recalculate layout, and defaultScrollAnchor(.bottom) chases
/// the growing height, creating visible bounce. The fix: track the streaming bubble's
/// height and give it a monotonically-increasing min-height so the ScrollView only
/// sees downward expansion (never resize), which anchor(.bottom) handles smoothly.
struct MessageCanvas: View {
    @Environment(ThemeManager.self) var themeManager

    let messages: [Message]
    let isStreaming: Bool
    var streamingContent: String = ""
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

    @State private var isAtBottom: Bool = true
    @State private var measuredWidth: CGFloat = 1200
    @State private var anchorMessageId: String? = nil
    /// Tracks the maximum height the streaming bubble has reached.
    /// Only grows, never shrinks — reset when streaming ends.
    /// This prevents LazyVStack layout bounce during streaming.
    @State private var streamingMinHeight: CGFloat = 0

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
                                .frame(minHeight: streamingMinHeight, alignment: .top)
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: StreamingHeightKey.self,
                                            value: geo.size.height
                                        )
                                    }
                                )
                                .onPreferenceChange(StreamingHeightKey.self) { newHeight in
                                    // Only grow, never shrink — prevents bounce
                                    if newHeight > streamingMinHeight {
                                        streamingMinHeight = newHeight
                                    }
                                }
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
                .onChange(of: topicId) { _, newId in
                    if newId != nil {
                        // Topic switch: scroll to bottom after SwiftUI renders new content.
                        // defaultScrollAnchor(.bottom) handles the initial position,
                        // but if messages arrive incrementally, we need a manual nudge.
                        isAtBottom = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    jumpToLatestButton(proxy: proxy)
                }
            }
            .environment(\.canvasWidth, measuredWidth)
        }
        .frame(maxHeight: .infinity)
        // Reset streaming min-height only when streaming is truly done
        // (not just a momentary flicker). Checks both flags to avoid
        // resetting during brief isStreaming=false races between poll cycles.
        .onChange(of: isStreaming) { _, isNowStreaming in
            if !isNowStreaming && streamingContent.isEmpty {
                streamingMinHeight = 0
            }
        }
        .onChange(of: streamingContent) { _, newContent in
            // Belt-and-braces: if streaming ended but minHeight hasn't reset
            // (e.g., streamingContent was cleared before isStreaming went false)
            if !isStreaming && newContent.isEmpty {
                streamingMinHeight = 0
            }
        }
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
                        .font(.system(size: 14, weight: .semibold))
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

/// Preference key for tracking streaming bubble height (monotonically increasing).
private struct StreamingHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
