import SwiftUI
import BeeChatPersistence

/// Scrollable message canvas — displays messages and typing indicator.
/// Auto-scrolls to bottom on new messages. Measures canvas width for bubble sizing
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
    @State private var lastScrollTime: Date = .distantPast

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

                        Color.clear
                            .frame(height: 8)
                            .id("bottom-anchor")
                    }
                }
                .scrollContentBackground(.hidden)
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    // Guard against invalid geometry (empty content, zero-size container)
                    guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
                        return isAtBottom
                    }
                    let threshold: CGFloat = 24
                    let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                    return distanceFromBottom < threshold
                } action: { _, newValue in
                    // Only update state when the value actually changes to prevent
                    // layout feedback loops (isAtBottom → Jump button → geometry change → isAtBottom)
                    if isAtBottom != newValue {
                        isAtBottom = newValue
                    }
                }
                .background(
                    WidthReader { width in
                        Color.clear
                            .preference(key: WidthPreferenceKey.self, value: width)
                    }
                )
                .onPreferenceChange(WidthPreferenceKey.self) { newWidth in
                    measuredWidth = newWidth
                }
                .onChange(of: messages.count) { _, _ in
                    if let anchorId = anchorMessageId {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(anchorId, anchor: .top)
                        }
                        anchorMessageId = nil
                    } else if pendingTopicScroll {
                        pendingTopicScroll = false
                        scrollToBottom(proxy: proxy, animated: true)
                    } else if isAtBottom || isUserMessage {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                    // else: user is scrolled up reading — don't force scroll.
                }
                .onChange(of: thinkingState) { oldState, newState in
                    BeeChatLogger.log("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
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
            }
            .environment(\.canvasWidth, measuredWidth)

            // Jump to Latest button — always present but fades in/out.
            // Using opacity instead of conditional rendering prevents layout feedback loops
            // where isAtBottom toggles → button appears/disappears → geometry changes → isAtBottom toggles
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
            .accessibilityLabel("Jump to latest message")
            .accessibilityHint("Scrolls to the most recent message")
            .opacity(isAtBottom ? 0 : 1)
            .allowsHitTesting(!isAtBottom)
            .accessibilityHidden(isAtBottom)
            .offset(y: isAtBottom ? 8 : 0)
            .animation(.easeInOut(duration: 0.2), value: isAtBottom)
            .padding(.bottom, 12)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(maxHeight: .infinity)
    }

    private var isUserMessage: Bool {
        guard let lastMessage = messages.last else { return false }
        return lastMessage.role == "user"
    }

    /// Scroll to bottom. No animation during streaming — animation fights with
    /// SwiftUI's layout engine as content grows, causing visible bounce.
    /// Animated scroll only for user-initiated actions (topic switch, onAppear).
    /// Debounced: overlapping calls within 100 ms are coalesced to prevent
    /// infinite layout loops from rapid state updates.
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) < 0.1 {
            return
        }
        lastScrollTime = now
        if animated {
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