import SwiftUI
import BeeChatPersistence

/// Scrollable message canvas — displays messages and typing indicator.
/// Auto-scrolls to bottom on new messages. Measures canvas width for bubble sizing.
///
/// Scroll philosophy (2026-05-21 consensus): Let `defaultScrollAnchor(.bottom)` do
/// the work. Only call `scrollToBottom` explicitly for user-initiated actions and
/// initial scroll triggers. Never animate during streaming — animation fights
/// SwiftUI's layout engine and causes visible bounce.
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
    @State private var scrollProxy: ScrollViewProxy?
    @State private var measuredWidth: CGFloat = 1200
    @State private var anchorMessageId: String?
    @State private var pendingTopicScroll: Bool = false

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

                        // 4px anchor — enough for LazyVStack to render reliably,
                        // invisible to the user. 8px was visibly too tall (white space).
                        Color.clear
                            .frame(height: 4)
                            .id("bottom-anchor")
                    }
                }
                .scrollContentBackground(.hidden)
                .defaultScrollAnchor(.bottom)
                // Simplified geometry tracking — only tracks isAtBottom for Jump button.
                // Removed contentHeight/containerHeight (only used for removed contentFillsContainer).
                .onScrollGeometryChangeCompat(
                    transform: { geo in
                        guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
                            return true
                        }
                        let enterThreshold: CGFloat = 50
                        let leaveThreshold: CGFloat = 120
                        let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                        if isAtBottom {
                            return distanceFromBottom < leaveThreshold
                        } else {
                            return distanceFromBottom < enterThreshold
                        }
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
                // Primary scroll trigger: new messages committed to the list
                .onChange(of: messages.count) { _, _ in
                    if let anchorId = anchorMessageId {
                        // Preserve scroll position after "Load earlier messages"
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(anchorId, anchor: .top)
                        }
                        anchorMessageId = nil
                    } else if pendingTopicScroll {
                        pendingTopicScroll = false
                        scrollToBottom(proxy: proxy, animated: true)
                    }
                }
                // Streaming bubble appeared — scroll to it (first chunk needs a trigger)
                .onChange(of: showStreamingBubble) { _, isShowing in
                    if isShowing {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                }
                .onChange(of: topicId) { _, newId in
                    if newId != nil {
                        isAtBottom = true
                        if messages.isEmpty {
                            pendingTopicScroll = true
                        } else {
                            scrollToBottom(proxy: proxy, animated: true)
                        }
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .overlay(alignment: .bottomTrailing) {
                    jumpToLatestButton
                }
            }
            .environment(\.canvasWidth, measuredWidth)
        }
        .frame(maxHeight: .infinity)
    }

    /// Jump-to-Latest button — lives in a fixed-size overlay so its opacity
    /// changes never affect scroll geometry.
    private var jumpToLatestButton: some View {
        Color.clear
            .frame(width: 48, height: 48)
            .overlay {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let proxy = scrollProxy {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
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
                .opacity(isAtBottom ? 0 : 1)
                .allowsHitTesting(!isAtBottom)
                .accessibilityLabel("Jump to latest message")
                .accessibilityHint("Scrolls to the most recent message")
                .accessibilityHidden(isAtBottom)
            }
            .padding(.bottom, 12)
            .padding(.trailing, 12)
    }

    /// Scroll to bottom. No animation during streaming — animation fights with
    /// SwiftUI's layout engine as content grows, causing visible bounce.
    /// Animated scroll only for user-initiated actions (topic switch, onAppear).
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        if isStreaming {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        } else if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
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
        }
    }
}