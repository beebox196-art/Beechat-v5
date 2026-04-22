import SwiftUI
import BeeChatPersistence

/// Scrollable message canvas — displays messages and typing indicator.
/// Auto-scrolls to bottom on new messages. Measures canvas width for bubble sizing
/// via a non-greedy WidthReader (GeometryReader returning Color.clear as background overlay)
/// instead of a greedy outer GeometryReader that breaks VStack layout.
struct MessageCanvas: View {
    @Environment(ThemeManager.self) var themeManager

    let messages: [Message]
    let isStreaming: Bool
    var streamingContent: String = ""

    /// Whether to show the streaming bubble.
    /// Keeps the streaming bubble visible after streaming ends (isStreaming → false)
    /// until the GRDB ValueObservation delivers the persisted assistant message.
    /// Dedup: if the last persisted assistant message already contains the same
    /// content, the streaming bubble is hidden to avoid duplication.
    private var showStreamingBubble: Bool {
        guard !streamingContent.isEmpty else { return false }
        // Check if the last persisted assistant message already matches
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

    var body: some View {
        ZStack {
            // Solid background fills entire area — no system bleed-through
            themeManager.color(.bgSurface)
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(messages, id: \.id) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if isStreaming && streamingContent.isEmpty {
                            // Streaming just started — no text yet, show animated dots
                            TypingIndicator()
                                .id("typing-indicator")
                        } else if showStreamingBubble {
                            // Streaming text arriving, or streaming finished but persisted
                            // message hasn't arrived yet — keep the bubble visible.
                            StreamingBubble(content: streamingContent)
                                .id("streaming-bubble")
                        }

                        // Bottom anchor for auto-scroll
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
                    scrollToBottom(proxy: proxy)
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

// MARK: - Width Reader (non-greedy GeometryReader)

/// A GeometryReader that returns Color.clear, so it doesn't participate in layout.
/// Used as a .background() overlay to measure parent width without being greedy.
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