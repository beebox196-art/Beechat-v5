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

    @State private var autoScroll = true
    @State private var measuredWidth: CGFloat = 1200
    @State private var anchorMessageId: String?

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
                    } else {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: isStreaming) { _, isNowStreaming in
                    if isNowStreaming {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: showStreamingBubble) { _, isShowing in
                    if isShowing {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onChange(of: thinkingState) { oldState, newState in
                    BeeChatLogger.log("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
                }
                .onAppear {
                    scrollToBottom(proxy: proxy)
                }
            }
            .environment(\.canvasWidth, measuredWidth)
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.2)) {
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
    static let defaultValue: CGFloat = 1200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
