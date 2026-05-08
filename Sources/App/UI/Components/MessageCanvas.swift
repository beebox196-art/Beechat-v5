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
    @State private var debounceTask: Task<Void, Never>?
    @State private var lastScrollTime: Date = .distantPast
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

                        Color.clear
                            .frame(height: 2)
                            .id("bottom-anchor")
                            .onAppear {
                                debounceTask?.cancel()
                                debounceTask = Task {
                                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                                    guard !Task.isCancelled else { return }
                                    await MainActor.run { isAtBottom = true }
                                }
                            }
                            .onDisappear {
                                debounceTask?.cancel()
                                debounceTask = Task {
                                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                                    guard !Task.isCancelled else { return }
                                    await MainActor.run { isAtBottom = false }
                                }
                            }
                    }
                }
                .scrollContentBackground(.hidden)
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
                        // Topic switched — scroll to bottom once messages render
                        pendingTopicScroll = false
                        scrollToBottom(animated: true)
                    } else if isAtBottom || isUserMessage || isStreaming {
                        scrollToBottom(animated: false)
                    }
                    // else: user is scrolled up reading — don't force scroll.
                }
                .onChange(of: isStreaming) { _, isNowStreaming in
                    if isNowStreaming {
                        scrollToBottom(animated: false)
                    }
                }
                .onChange(of: showStreamingBubble) { _, isShowing in
                    if isShowing {
                        scrollToBottom(animated: false)
                    }
                }
                .onChange(of: thinkingState) { oldState, newState in
                    BeeChatLogger.log("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
                }
                .onChange(of: topicId) { _, newId in
                    if newId != nil {
                        isAtBottom = true
                        lastScrollTime = .distantPast
                        if messages.isEmpty {
                            // No messages yet — defer scroll until they render
                            pendingTopicScroll = true
                        } else {
                            scrollToBottom(animated: true)
                        }
                    }
                }
                .onAppear {
                    scrollProxy = proxy
                    scrollToBottom(animated: true)
                }
            }
            .environment(\.canvasWidth, measuredWidth)

            // Jump to Latest button — visible when user has scrolled up
            if !isAtBottom {
                Button(action: {
                    scrollToBottom(animated: true)
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

    private func scrollToBottom(animated: Bool = false) {
        guard let proxy = scrollProxy else { return }

        // During streaming/thinking, deduplicate: skip if scrolled recently
        if isStreaming || thinkingState != .idle {
            let now = Date()
            guard now.timeIntervalSince(lastScrollTime) > 0.3 else { return }
            lastScrollTime = now
        }

        // Prefer scrolling to the last message when available — more reliable than
        // bottom-anchor because the anchor is only 2pt and ScrollView may not
        // layout LazyVStack content immediately on topic switch.
        let targetId = messages.last?.id ?? "bottom-anchor"

        if animated {
            DispatchQueue.main.async { [proxy] in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(targetId, anchor: .bottom)
                }
            }
            // Fallback: re-scroll after layout settles (LazyVStack renders asynchronously)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [proxy] in
                proxy.scrollTo(targetId, anchor: .bottom)
            }
        } else {
            // Synchronous — no animation, no fallback, no dispatch delay
            proxy.scrollTo(targetId, anchor: .bottom)
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
    static let defaultValue: CGFloat = 1200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


