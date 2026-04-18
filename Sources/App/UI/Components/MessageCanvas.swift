import SwiftUI
import BeeChatPersistence

/// Scrollable message canvas — displays messages and typing indicator.
/// Auto-scrolls to bottom on new messages. Measures canvas width for bubble sizing.
struct MessageCanvas: View {
    @Environment(ThemeManager.self) var themeManager

    let messages: [Message]
    let isStreaming: Bool

    @State private var autoScroll = true
    @State private var measuredWidth: CGFloat = 800

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages, id: \.id) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if isStreaming {
                            TypingIndicator()
                                .id("typing-indicator")
                        }

                        // Bottom anchor for auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id("bottom-anchor")
                    }
                }
                .onChange(of: messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: isStreaming) { _, isNowStreaming in
                    if isNowStreaming {
                        scrollToBottom(proxy: proxy)
                    }
                }
                .onAppear {
                    measuredWidth = geometry.size.width
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    measuredWidth = newWidth
                }
            }
            .environment(\.canvasWidth, measuredWidth)
        }
        .background(themeManager.color(.bgSurface))
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}