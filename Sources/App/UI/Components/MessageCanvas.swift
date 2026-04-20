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

    @State private var autoScroll = true
    @State private var measuredWidth: CGFloat = 800

    var body: some View {
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
            .onAppear {
                scrollToBottom(proxy: proxy)
            }
        }
        .environment(\.canvasWidth, measuredWidth)
        .frame(maxHeight: .infinity)
        .background(themeManager.color(.bgSurface))
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
    static let defaultValue: CGFloat = 800
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}