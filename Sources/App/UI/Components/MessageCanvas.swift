import SwiftUI
import BeeChatPersistence

/// Scrollable message canvas — displays messages and typing indicator.
///
/// Scroll philosophy (v5, 2026-06-13, SP-001): `ScrollPosition` is the single
/// source of truth for scroll position, paired with selective
/// `defaultScrollAnchor` calls (one for initial offset, one for content-size
/// changes). No imperative `ScrollViewReader`, no `proxy.scrollTo`, no
/// `onAppear`/`onChange(of: topicId)` `scrollTo` handlers, no
/// `onScrollGeometryChangeCompat`, no `scrollBounceBehaviorCompat`.
///
/// The "Jump to Latest" button and the auto-scroll-on-new-message policy
/// both drive `scrollPosition` directly.
///
/// Streaming poll is throttled to ~5fps (200ms) to reduce SwiftUI layout
/// recalculations. The StreamingBubble expands naturally in the VStack; no
/// height feedback loop is used.
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

    // SP-001: ScrollPosition is the single source of truth for scroll
    // position. Replaces the 4-5 layer patch stack (defaultScrollAnchor +
    // onAppear + onChange(topicId) + onScrollGeometryChange + bounceBehavior).
    @State private var scrollPosition = ScrollPosition()
    // Width (separate concern) — used by MessageBubble for max-width: 66%.
    @State private var measuredWidth: CGFloat = 1200
    // Load-earlier anchor — preserves the prior "pin to first visible row
    // when new content is inserted above" behavior.
    @State private var anchorMessageId: String? = nil

    /// Derived from `scrollPosition.viewID`. Single source of truth for
    /// whether the user is at the bottom of the conversation — drives the
    /// "Jump to Latest" button visibility.
    ///
    /// Internal (not `private`) so unit tests can verify the predicate
    /// logic. The behavior is documented in `MessageCanvasTests`.
    var isAtBottom: Bool {
        guard let lastId = messages.last?.id else { return true }
        // If no viewID has been recorded yet (first render, no scroll),
        // the user is effectively at the top of an empty/short scroll view
        // which is "at bottom" for an empty conversation.
        guard let viewId = scrollPosition.viewID(type: String.self) else {
            return true
        }
        return viewId == lastId
    }

    var body: some View {
        ZStack {
            themeManager.color(.bgSurface)
                .ignoresSafeArea()

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

                    // 3-way indicator chain (BWS-001 Fix #1, kept).
                    // Extracted to a static method for testability —
                    // `MessageCanvas.indicatorChain(...)` returns the
                    // `Indicator` kind, which we then render inline.
                    switch Self.indicatorChain(
                        thinkingState: thinkingState,
                        isStreaming: isStreaming,
                        streamingContent: streamingContent,
                        showStreamingBubble: showStreamingBubble
                    ) {
                    case .thinkingBee:
                        ThinkingBeeIndicator(mode: .thinking)
                            .id("thinking-bee")
                    case .typing:
                        TypingIndicator()
                            .id("typing-indicator")
                    case .streamingBubble:
                        StreamingBubble(content: streamingContent)
                            .id("streaming-bubble")
                    case .none:
                        EmptyView()
                    }

                    // 4pt anchor — addressable scroll target for the
                    // bottom edge. Provides a reliable landing spot for
                    // scrollTo(edge: .bottom) when the conversation is
                    // very short or empty.
                    Color.clear
                        .frame(height: 4)
                        .id("bottom-anchor")
                }
                .scrollTargetLayout()  // SP-001: makes .id() values addressable
            }
            .scrollContentBackground(.hidden)
            // SP-001: single, declarative scroll-position binding.
            // .bottom anchor means the bottom-most visible view updates
            // the binding — this is what `isAtBottom` reads.
            .scrollPosition($scrollPosition, anchor: .bottom)
            // SP-001: two separate defaultScrollAnchor calls (one per role).
            // ScrollAnchorRole is per-call, not a set.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            // Width (separate concern) — kept.
            .background(
                WidthReader { width in
                    Color.clear
                        .preference(key: WidthPreferenceKey.self, value: width)
                }
            )
            .onPreferenceChange(WidthPreferenceKey.self) { newWidth in
                measuredWidth = newWidth
            }
            // SP-001: load-earlier anchor — preserved, uses new API.
            .onChange(of: anchorMessageId) { _, newId in
                if let anchorId = newId {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        scrollPosition.scrollTo(id: anchorId)
                    }
                    anchorMessageId = nil
                }
            }
            // SP-001: the single auto-scroll-on-new-message policy.
            // "If the user is at the bottom, stay at the bottom."
            // Replaces the 4 prior onChange handlers that all called
            // scrollToBottom (RC2 from the consensus review).
            .onChange(of: messages) { _, newMessages in
                if let lastId = newMessages.last?.id,
                   scrollPosition.viewID(type: String.self) == lastId {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                jumpToLatestButton
            }
        }
        .environment(\.canvasWidth, measuredWidth)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Jump-to-Latest

    /// Fixed-size overlay, opacity-only transitions. Driven by the computed
    /// `isAtBottom` (derived from `scrollPosition.viewID`).
    private var jumpToLatestButton: some View {
        Color.clear
            .frame(width: 48, height: 48)
            .overlay {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
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

    // MARK: - Indicator chain (BWS-001 Fix #1, kept)

    /// Static, testable indicator chain.
    ///
    /// 3-way: `.thinking` → `.typing` → `.streaming-bubble`.
    ///
    /// Pre-fix (BWS-001), the `else if isStreaming && streamingContent.isEmpty`
    /// branch was guarded by `if thinkingState != .streaming`, which is dead
    /// code (the outer `else if` already excludes `.thinking`). The
    /// `TypingIndicator` never appeared, producing a 50-200 ms empty slot
    /// between the `ThinkingBeeIndicator` and the first `StreamingBubble`.
    /// Post-fix, when streaming is true but no content has arrived yet, the
    /// chain returns `.typing` to bridge the gap.
    enum Indicator: Equatable {
        case none
        case thinkingBee
        case typing
        case streamingBubble
    }

    static func indicatorChain(
        thinkingState: ThinkingState,
        isStreaming: Bool,
        streamingContent: String,
        showStreamingBubble: Bool
    ) -> Indicator {
        if thinkingState == .thinking {
            return .thinkingBee
        } else if isStreaming && streamingContent.isEmpty {
            return .typing
        } else if showStreamingBubble {
            return .streamingBubble
        } else {
            return .none
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
