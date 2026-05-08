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
    @State private var visibleHeight: CGFloat = 0

    private let enterBottomThreshold: CGFloat = 50
    private let leaveBottomThreshold: CGFloat = 120

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
                            .frame(height: 1)
                            .id("bottom-anchor")
                            .overlay(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: BottomAnchorPreferenceKey.self,
                                        value: geo.frame(in: .named("messageScrollView")).minY
                                    )
                                }
                            )
                    }
                }
                .coordinateSpace(name: "messageScrollView")
                .scrollContentBackground(.hidden)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: WidthPreferenceKey.self, value: geo.size.width)
                            .preference(key: VisibleHeightPreferenceKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(WidthPreferenceKey.self) { newWidth in
                    measuredWidth = newWidth
                }
                .onPreferenceChange(VisibleHeightPreferenceKey.self) { newHeight in
                    visibleHeight = newHeight
                }
                .onPreferenceChange(BottomAnchorPreferenceKey.self) { bottomY in
                    // bottomY = anchor's minY in scroll view coordinate space
                    // When at bottom: bottomY ≈ visibleHeight (anchor visible near bottom edge)
                    // When scrolled up: bottomY > visibleHeight (anchor is below visible area)
                    let distanceBelowVisible = bottomY - visibleHeight
                    if distanceBelowVisible < enterBottomThreshold {
                        isAtBottom = true
                    } else if distanceBelowVisible > leaveBottomThreshold {
                        isAtBottom = false
                    }
                    // Between thresholds: keep current state (hysteresis prevents flicker)
                }
                .onChange(of: messages.count) { _, _ in
                    if let anchorId = anchorMessageId {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(anchorId, anchor: .top)
                        }
                        anchorMessageId = nil
                    } else if isAtBottom || isUserMessage || isStreaming {
                        scrollToBottom()
                    }
                    // else: user is scrolled up reading — don't force scroll.
                }
                .onChange(of: isStreaming) { _, isNowStreaming in
                    if isNowStreaming {
                        scrollToBottom()
                    }
                }
                .onChange(of: showStreamingBubble) { _, isShowing in
                    if isShowing {
                        scrollToBottom()
                    }
                }
                .onChange(of: thinkingState) { oldState, newState in
                    BeeChatLogger.log("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
                }
                .onChange(of: topicId) { _, newId in
                    if newId != nil {
                        isAtBottom = true
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                    scrollToBottom()
                }
            }
            .environment(\.canvasWidth, measuredWidth)

            // Jump to Latest button — visible when user has scrolled up
            if !isAtBottom {
                Button(action: {
                    scrollToBottom()
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
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .padding(.bottom, 12)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var isUserMessage: Bool {
        guard let lastMessage = messages.last else { return false }
        return lastMessage.role == "user"
    }

    private func scrollToBottom() {
        guard let proxy = scrollProxy else { return }
        // First attempt: next run loop (after layout)
        DispatchQueue.main.async { [proxy] in
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
        // Fallback: 200ms later (guarantees LazyVStack has rendered)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [proxy] in
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}



/// Preference key for passing measured width up the view hierarchy.
private struct WidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 1200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Preference key for tracking the visible height of the scroll view.
private struct VisibleHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Preference key for tracking the bottom anchor position in the scroll view.
private struct BottomAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
