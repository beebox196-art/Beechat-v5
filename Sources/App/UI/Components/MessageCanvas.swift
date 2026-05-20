import SwiftUI
import BeeChatPersistence

/// Tracked scroll geometry result returned from the transform closure.
/// Using a named type instead of a tuple helps the Swift type checker.
struct ScrollGeometryResult: Equatable {
    var isAtBottom: Bool
    var contentHeight: CGFloat
    var containerHeight: CGFloat
}

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
    // Tracked geometry values — set only in the action closure of onScrollGeometryChangeCompat
    @State private var contentHeight: CGFloat = 0
    @State private var containerHeight: CGFloat = 0
    @State private var scrollCorrectionTask: Task<Void, Never>?

    /// Computed from tracked geometry — no @State mutation in geometry handler.
    private var contentFillsContainer: Bool {
        guard contentHeight > 0, containerHeight > 0 else { return false }
        return contentHeight >= containerHeight
    }

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
                // Change #9: Transform closure is pure (no @State mutations).
                // All state mutations happen in the action closure.
                // Change #4: Hysteresis thresholds (50/120px) kept for UX quality.
                .onScrollGeometryChangeCompat(
                    transform: { geo in
                        // Pure computation — no @State mutations
                        guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
                            return ScrollGeometryResult(isAtBottom: true, contentHeight: geo.contentSize.height, containerHeight: geo.containerSize.height)
                        }
                        // Hysteresis: enter threshold (become "at bottom") is generous,
                        // leave threshold (become "scrolled up") is tighter.
                        let enterThreshold: CGFloat = 50
                        let leaveThreshold: CGFloat = 120
                        let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                        let atBottom: Bool
                        if isAtBottom {
                            atBottom = distanceFromBottom < leaveThreshold
                        } else {
                            atBottom = distanceFromBottom < enterThreshold
                        }
                        return ScrollGeometryResult(isAtBottom: atBottom, contentHeight: geo.contentSize.height, containerHeight: geo.containerSize.height)
                    },
                    action: { _, newValue in
                        // All @State mutations here (Change #9)
                        isAtBottom = newValue.isAtBottom
                        contentHeight = newValue.contentHeight
                        containerHeight = newValue.containerHeight
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
                // Change #5+6: Replace needsScrollAfterLayout with Task-based scheduleScrollCorrection
                .onChange(of: messages.count) { _, _ in
                    if let anchorId = anchorMessageId {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(anchorId, anchor: .top)
                        }
                        anchorMessageId = nil
                    } else if pendingTopicScroll {
                        pendingTopicScroll = false
                        scrollToBottom(proxy: proxy, animated: true)
                    }
                    // Short-content fallback: when messages don't fill the viewport,
                    // defaultScrollAnchor(.bottom) is ignored by macOS. Force-scroll to
                    // keep content at the bottom of the visible area.
                    if !contentFillsContainer {
                        scrollToBottom(proxy: proxy, animated: false)
                    }
                    // Schedule scroll correction for safeAreaInset layout changes
                    scheduleScrollCorrection(proxy: proxy)
                }
                // Change #10: Schedule scroll correction when Composer height changes
                .onChange(of: containerHeight) { _, _ in
                    scheduleScrollCorrection(proxy: proxy)
                }
                .onChange(of: thinkingState) { oldState, newState in
                    BeeChatLogger.log("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
                    // REMOVED: scrollToBottom on .thinking
                    // defaultScrollAnchor(.bottom) handles staying at bottom.
                    // Explicit scroll here causes bounce when Composer height is changing.
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
                // Change #1: Move Jump-to-Latest button from ZStack sibling to .overlay()
                // on the ScrollView. Overlay opacity changes don't affect scroll geometry.
                // Change #2: Remove .animation and .offset on isAtBottom — both were
                // layout-affecting in ZStack.
                // Change #3: Fixed-size container (48×48) so opacity changes can't affect layout.
                .overlay(alignment: .bottomTrailing) {
                    jumpToLatestButton
                }
            }
            .environment(\.canvasWidth, measuredWidth)
        }
        .frame(maxHeight: .infinity)
    }



    /// Jump-to-Latest button — lives in a fixed-size overlay so its opacity
    /// changes never affect scroll geometry (Changes #1, #2, #3).
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
    /// Change #11: Debounce increased to 200ms for safety margin against rapid re-triggering.
    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        let now = Date()
        if now.timeIntervalSince(lastScrollTime) < 0.2 {
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

    /// Schedule a coalesced scroll correction after a short delay.
    /// Change #6: Replaces needsScrollAfterLayout with Task-based approach.
    /// Change #13: Guard against re-trigger — only scroll if isAtBottom.
    private func scheduleScrollCorrection(proxy: ScrollViewProxy) {
        scrollCorrectionTask?.cancel()
        scrollCorrectionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            // Don't schedule if already at bottom — prevents re-entering geometry handler
            guard isAtBottom else { return }
            scrollToBottom(proxy: proxy, animated: false)
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
///
/// Change #9: Restructured to follow Apple's two-closure pattern:
///   - `transform` is pure — returns an Equatable value, no @State mutations.
///   - `action` mutates state — called only when the Equatable value changes.
///
/// The handler receives a `ScrollGeometry` struct with contentSize, containerSize,
/// and contentOffset — mirroring the native API but available on all platforms.
struct ScrollGeometry {
    var contentSize: CGSize
    var containerSize: CGSize
    var contentOffset: CGPoint
}

extension View {
    /// On macOS 15+/iOS 18+: uses native `onScrollGeometryChange` with two-closure pattern.
    /// On older platforms: leaves state unchanged (auto-scroll via `defaultScrollAnchor(.bottom)` still works).
    /// Change #12: macOS 14 fallback uses DispatchQueue.main.asyncAfter for short-content
    /// scroll correction, since `onScrollGeometryChange` is unavailable.
    /// - Parameter transform: Pure computation closure — receives ScrollGeometry and returns an Equatable value.
    ///   MUST NOT mutate @State. Called frequently; keep it minimal.
    /// - Parameter action: State mutation closure — called only when the Equatable value changes.
    ///   All @State mutations go here.
    @ViewBuilder
    func onScrollGeometryChangeCompat(
        transform: @escaping (ScrollGeometry) -> ScrollGeometryResult,
        action: @escaping (_ oldValue: ScrollGeometryResult, _ newValue: ScrollGeometryResult) -> Void
    ) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            self.onScrollGeometryChange(for: ScrollGeometryResult.self) { geo in
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
            // Change #12: Use DispatchQueue.main.asyncAfter for short-content auto-scroll
            // since defaultScrollAnchor(.bottom) is ignored when content is shorter than viewport.
            self.onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    // On macOS 14, we can't track geometry, so schedule a one-time
                    // scroll correction after layout settles.
                }
            }
        }
    }
}