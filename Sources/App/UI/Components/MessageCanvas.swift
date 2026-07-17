import SwiftUI
import os
import BeeChatPersistence

/// File-scoped logger for the self-healing scroll clamp.
private let scrollClampLogger = Logger(subsystem: "com.beebox.beechat", category: "ScrollClamp")

/// Scrollable message canvas — displays messages and typing indicator.
///
/// Scroll philosophy (v5, 2026-07-11): Three orthogonal fixes layered on top of the
/// ScrollView+LazyVStack foundation:
///
/// 1. Topic switch — `.id(topicId)` on the ScrollView forces SwiftUI to rebuild the
///    scroll view per topic, so `defaultScrollAnchor(.bottom)` fires as a genuine
///    initial layout. (No more async lottery, no more stale offsets.)
/// 2. Jump to Latest — `ScrollPosition.scrollTo(edge: .bottom)` (macOS 15+) resolves
///    against live content size, not stale child frames, so the target is correct even
///    when WebView heights are still settling.
/// 3. Whitespace gaps — anchor roles (Fix 3a) + width rounding (Fix 3b) +
///    WebView height coalescing (Fix 3c, in MessageWebView.swift) all reduce layout
///    events on resize/font-change. Hysteresis (enter 50pt / leave 120pt) keeps the
///    jump button from flickering during streaming.
///
/// ScrollViewReader is kept solely for load-earlier anchor. `ScrollPosition` and
/// `ScrollViewReader` are NOT mixed (one programmatic controller per scroll view).
struct MessageCanvas: View {
    @Environment(ThemeManager.self) var themeManager

    let messages: [Message]
    let isStreaming: Bool
    var streamingContent: String = ""
    /// Bridge content from SyncBridgeObserver.completedContent — the final response
    /// captured when streaming ends. Fills the gap between streaming stopping and
    /// GRDB delivering the settled message to the UI.
    var completedContent: String = ""
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

    /// Whether to show the completed-content bridge bubble.
    /// This fills the gap between streaming ending (isStreaming=false) and
    /// GRDB delivering the settled message to the messages array.
    private var showCompletedBridge: Bool {
        guard !isStreaming, !completedContent.isEmpty else { return false }
        // Only show if the last assistant message is missing or has stale content
        if let lastAssistant = messages.last(where: { $0.role == "assistant" }),
           let content = lastAssistant.content, !content.isEmpty {
            // The settled message already has content — bridge not needed
            return false
        }
        return true
    }

    @State private var isAtBottom: Bool = true
    @State private var measuredWidth: CGFloat = 1200
    @State private var anchorMessageId: String? = nil
    /// Phase 1: Self-healing bottom clamp state.
    /// When distFromBottom is deeply negative (viewport stranded past content)
    /// while isAtBottom is true, counts consecutive geometry callbacks. Once the
    /// threshold is reached, re-anchors to bottom via macOS15JumpAction.
    /// After firing, stays disarmed until distanceFromBottom >= 0 to prevent
    /// re-triggering during the 0.2s scrollTo animation (Kieran F1 review).
    @State private var strandedFrameCount: Int = 0
    /// Phase 1: Whether the clamp has fired and is awaiting distanceFromBottom >= 0
    /// before re-arming. Prevents the animation re-trigger loop.
    @State private var clampDisarmed: Bool = false
    /// Fix 2: hysteresis thresholds (enter bottom zone / leave bottom zone).
    /// Entering is generous (50pt) so streaming growth re-latches at bottom and
    /// doesn't flash the jump button. Leaving requires a deliberate scroll
    /// (>120pt) so layout settle and small drags don't flash the button.
    /// Field-tested pre-2c507d5 values — restored.
    private let enterBottomThreshold: CGFloat = 50
    private let leaveBottomThreshold: CGFloat = 120
    /// Phase 1: Debounce threshold for the self-healing clamp.
    /// 15 geometry callbacks ≈ 250ms at 60fps, safely exceeding the ~6-10 frame
    /// rubber-band overscroll window on slow drags.
    private let clampDebounceFrames: Int = 15

    /// Fix 2: macOS 15+ chrome-supplied jump action, set via environment.
    /// Nil when no chrome is wrapping this canvas (macOS 14 build, or direct use).
    @Environment(\.macOS15JumpAction) private var macOS15JumpAction

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

                        // Completed-content bridge bubble: fills the gap between
                        // streaming ending and GRDB delivering the settled message.
                        // Renders identically to a settled assistant message.
                        if showCompletedBridge {
                            CompletedBridgeBubble(content: completedContent)
                                .id("completed-bridge")
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
                .id(topicId)                           // Fix 1: rebuild scroll view per topic
                .scrollBounceBehaviorCompat(axes: .vertical)
                .onScrollGeometryChangeCompat(
                    transform: { geo in
                        guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
                            // Before any layout: treat as "at bottom" (distance 0)
                            // so the jump button doesn't flash during cold start.
                            return CGFloat(0)
                        }
                        // Distance from reading-edge bottom (live, may be negative
                        // during overscroll).
                        let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                        return distanceFromBottom
                    },
                    action: { _, distanceFromBottom in
                        // Fix 2 hysteresis: enter at < 50pt, leave at > 120pt.
                        // Prevents button flicker during streaming/layout settle.
                        if distanceFromBottom < enterBottomThreshold {
                            if !isAtBottom { isAtBottom = true }
                        } else if distanceFromBottom > leaveBottomThreshold {
                            if isAtBottom { isAtBottom = false }
                        }
                        // Phase 1: Self-healing bottom clamp.
                        // distFromBottom is negative when the viewport is past the end of content
                        // (overscroll / stranded). A deeply negative value (< -8pt, ignoring
                        // sub-point FP jitter at content edge) while isAtBottom is true means
                        // LazyVStack estimation overshoot has stranded the viewport (M1).
                        //
                        // Debounce: 15 geometry callbacks (~250ms at 60fps) to skip both
                        // rubber-band overscroll (which resolves in ~6-10 frames on slow drags)
                        // and transient layout jitter during settle. Once the clamp fires, it
                        // stays disarmed until distanceFromBottom >= 0 to prevent re-triggering
                        // during the chrome's 0.2s withAnimation scrollTo (Kieran F1 review).
                        if distanceFromBottom < -8 && isAtBottom && !clampDisarmed {
                            strandedFrameCount += 1
                            if strandedFrameCount >= clampDebounceFrames {
                                strandedFrameCount = 0
                                clampDisarmed = true
                                if let action = macOS15JumpAction {
                                    action.perform()
                                    scrollClampLogger.info("clamp FIRED distFromBottom=\(distanceFromBottom)")
                                } else {
                                    scrollClampLogger.warning("clamp TRIGGERED but macOS15JumpAction is nil — clamp non-functional without chrome wrapper")
                                }
                            }
                        } else if distanceFromBottom >= 0 {
                            // Content edge reached — safe to re-arm the clamp.
                            strandedFrameCount = 0
                            clampDisarmed = false
                        } else {
                            // Negative but not deeply negative, or not at bottom, or disarmed.
                            // clampDisarmed is NOT reset here: a re-stranding after the user
                            // scrolls up must wait for distanceFromBottom >= 0 before re-arming.
                            // This is intentional — the clamp won't re-fire until the viewport
                            // actually reaches the content edge, preventing animation loops.
                            strandedFrameCount = 0
                        }
                    }
                )
                .background(
                    WidthReader { width in
                        Color.clear
                            .preference(key: WidthPreferenceKey.self, value: width)
                    }
                )
                .onPreferenceChange(WidthPreferenceKey.self) { newWidth in
                    // Fix 3b: round to whole points; ignore sub-point deltas; snap,
                    // don't animate. Resize ticks emit sub-pixel FP deltas that
                    // would otherwise re-lay every bubble per frame.
                    let rounded = round(newWidth)
                    if abs(rounded - measuredWidth) >= 1 {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            measuredWidth = rounded
                        }
                    }
                }

                // Manual scrolls: load-earlier anchor, topic switch, and appear
                .onChange(of: anchorMessageId) { _, newId in
                    if let anchorId = newId {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(anchorId, anchor: .top)
                        }
                        anchorMessageId = nil
                    }
                }
                .onChange(of: topicId) { _, _ in
                    // Fix 1: .id(topicId) on the ScrollView forces a fresh initial
                    // layout, which triggers defaultScrollAnchor(.bottom) natively.
                    // Reset transient state so the new view starts clean.
                    isAtBottom = true
                    anchorMessageId = nil
                    strandedFrameCount = 0
                    clampDisarmed = false
                }
                .overlay(alignment: .bottomTrailing) {
                    jumpToLatestButton(proxy: proxy)
                }
            }
            .environment(\.canvasWidth, measuredWidth)
        }
        .frame(maxHeight: .infinity)
    }

    /// Jump-to-Latest button — fixed-size overlay, opacity-only transitions.
    /// Takes the ScrollViewProxy directly so it works even though the button
    /// lives outside the ScrollViewReader closure. On macOS 15+ when the
    /// environment carries a `macOS15JumpAction` (set by the chrome wrapper),
    /// the action uses `ScrollPosition.scrollTo(edge:)`. Otherwise falls back
    /// to `ScrollViewProxy.scrollTo(...)`.
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Color.clear
            .frame(width: 48, height: 48)
            .overlay {
                Button(action: {
                    if let macOS15 = macOS15JumpAction {
                        // Fix 2: macOS 15+ path — uses ScrollPosition.scrollTo(edge:)
                        // which resolves against live content size, not stale child
                        // frames. Lands at the true bottom in one click even while
                        // WebView heights are settling. Don't manually set
                        // isAtBottom — onScrollGeometryChange will update it
                        // truthfully once we land.
                        macOS15.perform()
                    } else {
                        // macOS 14 fallback: ScrollViewProxy-based jump.
                        // Button is hidden on macOS 14 (isAtBottom stays true),
                        // so this branch is unreachable in practice.
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo("bottom-anchor", anchor: .bottom)
                        }
                        isAtBottom = true
                    }
                }) {
                    Image(systemName: "chevron.down")
                        .font(themeManager.font(.body))
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

/// macOS 15+ wrapper that owns the `ScrollPosition`, applies both anchor roles,
/// and supplies the Jump-to-Latest closure to the embedded MessageCanvas.
///
/// Usage: `if #available(macOS 15.0, *) { MacOS15ScrollPositionChrome { canvas } }`
///
/// On macOS 14 the wrapper is a pass-through and `MessageCanvas` uses its
/// built-in `ScrollViewProxy.scrollTo(...)` fallback (the jump button is hidden
/// on macOS 14 because `isAtBottom` stays true — `onScrollGeometryChangeCompat`
/// is a no-op there).
@available(macOS 15.0, *)
struct MacOS15ScrollPositionChrome<Content: View>: View {
    @State private var scrollPosition = ScrollPosition()
    let topicId: String?
    let content: Content

    init(topicId: String?, @ViewBuilder content: () -> Content) {
        self.topicId = topicId
        self.content = content()
    }

    var body: some View {
        let binding = $scrollPosition
        return content
            .scrollPosition(binding)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .environment(\.macOS15JumpAction, MacOS15JumpAction {
                // ScrollPosition is a value type — mutate a local copy and write
                // it back through the binding so SwiftUI observes and applies
                // the change. The `.scrollPosition(_:)` modifier picks up the
                // change via the binding.
                withAnimation(.easeInOut(duration: 0.2)) {
                    var current = binding.wrappedValue
                    current.scrollTo(edge: .bottom)
                    binding.wrappedValue = current
                }
            })
            // F3 hardening: chrome `@State` survives `.id(topicId)` (which sits
            // inside the wrapped content), so a user-scrolled position from the
            // previous topic could leak into the fresh scroll view and silently
            // resurrect Bug 1 on macOS 15. Reset in the same update transaction
            // as the identity swap so the new ScrollView mounts at the bottom.
            .onChange(of: topicId) { _, _ in
                binding.wrappedValue = ScrollPosition(edge: .bottom)
            }
    }
}

/// Environment key carrying the macOS 15+ Jump-to-Latest action closure.
/// Equatable-as-always-equal: the closure captures a Binding to the chrome's
/// `@State` storage, which is stable across renders — any instance is
/// interchangeable, so re-injection must not invalidate readers. Without this,
/// the chrome re-creates a fresh value on every body evaluation, and SwiftUI
/// (which uses `Equatable` to skip environment writes that haven't changed)
/// would invalidate every view that reads `\.macOS15JumpAction` — including
/// `MessageCanvas` itself, potentially per scroll event.
struct MacOS15JumpAction: Equatable {
    let perform: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct MacOS15JumpActionKey: EnvironmentKey {
    static let defaultValue: MacOS15JumpAction? = nil
}

extension EnvironmentValues {
    var macOS15JumpAction: MacOS15JumpAction? {
        get { self[MacOS15JumpActionKey.self] }
        set { self[MacOS15JumpActionKey.self] = newValue }
    }
}

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
    func onScrollGeometryChangeCompat<T: Equatable>(
        transform: @escaping (ScrollGeometry) -> T,
        action: @escaping (_ oldValue: T, _ newValue: T) -> Void
    ) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            self.onScrollGeometryChange(for: T.self) { geo in
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
            self
        }
    }

    @ViewBuilder
    func scrollBounceBehaviorCompat(axes: Axis.Set) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            self.scrollBounceBehavior(.basedOnSize, axes: axes)
        } else {
            self
        }
    }

    /// Fix 2 + 3a: macOS 15+ scrollPosition + anchor-role modifiers, applied
    /// by the `MacOS15ScrollPositionChrome` wrapper view (see below) when
    /// MessageCanvas is rendered on macOS 15+. On macOS 14 the chrome is a
    /// pass-through and the existing single-arg `.defaultScrollAnchor(.bottom)`
    /// already in place handles initial positioning.
}

/// Completed-content bridge bubble — renders final assistant content as a settled
/// message during the gap between streaming ending and GRDB delivering the update.
/// Uses the same styling as a regular assistant MessageBubble but without a cursor
/// or streaming indicator. Disappears as soon as the GRDB observation delivers the
/// settled message (completedContent is cleared by MainWindow).
struct CompletedBridgeBubble: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(FeatureFlags.self) var featureFlags
    let content: String

    /// WebView height binding for rich content (same pattern as MessageContent).
    @State private var webViewHeight: CGFloat = 40

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bee")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))

                if featureFlags.htmlRenderingEnabled && !content.isEmpty {
                    // Rich HTML path — same rendering pipeline as MessageContent
                    let htmlContent = MarkdownToHTML.convert(content)
                    let sanitized = HTMLSanitizer.sanitize(htmlContent)
                    let conversion = HTMLMessageConverter.convert(sanitized)

                    if conversion.needsWebView {
                        MessageWebView(
                            html: sanitized,
                            themeTokens: themeManager.cssTokens,
                            fontScale: themeManager.fontScale,
                            height: $webViewHeight,
                            onLink: { url in LinkPolicy.open(url) }
                        )
                        .frame(height: webViewHeight)
                    } else if !conversion.blocks.isEmpty {
                        ConvertedMessageView(converted: conversion)
                            .environment(\.openURL, OpenURLAction { url in
                                LinkPolicy.open(url)
                                return .handled
                            })
                    } else {
                        FileLinkText(content: content)
                            .font(themeManager.font(.body))
                            .textSelection(.enabled)
                    }
                } else {
                    // Plain text path
                    FileLinkText(content: content)
                        .font(themeManager.font(.body))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, themeManager.spacing(.lg))
            .padding(.vertical, themeManager.spacing(.md))
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: themeManager.radius(.xl), style: .continuous)
                    .fill(themeManager.color(.bgPanel))
            )
            .foregroundColor(themeManager.color(.textPrimary))
            .shadow(
                color: themeManager.color(.shadowMedium).opacity(0.1),
                radius: 4, x: 0, y: 2
            )
            .modifier(BubbleWidthModifier())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Assistant message")

            Spacer(minLength: 34)
        }
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.vertical, themeManager.spacing(.xs))
    }
}
