import SwiftUI
import BeeChatPersistence

/// Scrollable message canvas — displays messages and typing indicator.
///
/// Scroll philosophy (v4, 2026-06-01): `defaultScrollAnchor(.bottom)` handles auto-scroll
/// natively. The only manual scroll is "Jump to Latest" (user-initiated).
///
/// Streaming poll is throttled to ~5fps (200ms) to reduce SwiftUI layout recalculations.
/// The StreamingBubble expands naturally in the VStack; no height feedback loop is used.
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

    // MARK: - Spike instrumentation (v0.9.5d list-container spike)
    // Phase derived from existing inputs so we do not need to touch MainWindow.
    // SpikeScrollTrace writes per-frame geometry to JSONL when SPIKE_LIST_CONTAINER
    // or CANVAS_SCROLL_METRICS=1 is set; see CanvasScrollMetrics.swift.
    private var scrollPhase: ScrollPhase {
        if anchorMessageId != nil { return .loadEarlier }
        if thinkingState == .thinking { return .thinking }
        if isStreaming && streamingContent.isEmpty { return .streamingStart }
        if isStreaming { return .streaming }
        if !completedContent.isEmpty && !isStreaming { return .completedBridge }
        // Heuristic: if we just transitioned into a new user message phase, mark it.
        // (composer-shrink race = case B; we still emit the same phase for parity.)
        if let last = messages.last, last.role == "user",
           last.content == streamingContent {
            return .userSend
        }
        if showStreamingBubble { return .streaming }
        return .settled
    }

    var body: some View {
        ZStack {
            themeManager.color(.bgSurface)
                .ignoresSafeArea()

            ScrollViewReader { proxy in
                #if SPIKE_LIST_CONTAINER
                spikeListContainer(proxy: proxy)
                #else
                spikeScrollContainer(proxy: proxy)
                #endif
            }
            .environment(\.canvasWidth, measuredWidth)
        }
        .frame(maxHeight: .infinity)
    }

    /// Default scroll container — `ScrollView { LazyVStack }` (the v4 architecture).
    /// Kept identical to the previous behaviour so the spike baseline remains a
    /// pure build-flag flip away.
    @ViewBuilder
    private func spikeScrollContainer(proxy: ScrollViewProxy) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            canvasRows()
        }
        .scrollContentBackground(.hidden)
        .defaultScrollAnchor(.bottom)
        .scrollBounceBehaviorCompat(axes: .vertical)
        .modifier(SpikeScrollTraceBootstrap(phase: scrollPhase))
        .onScrollGeometryChangeCompat(
            transform: { geo in
                guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
                    return true
                }
                // Simple threshold: within 80px of bottom = at bottom
                let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return distanceFromBottom < 80
            },
            action: { _, newValue in
                isAtBottom = newValue
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
            // defaultScrollAnchor(.bottom) handles initial positioning.
            // The asyncAfter nudge fights with it and can cause bounce — removed.
        }
        .overlay(alignment: .bottomTrailing) {
            jumpToLatestButton(proxy: proxy)
        }
    }

    #if SPIKE_LIST_CONTAINER
    /// Spike alternate container — AppKit-backed `List`.
    /// Known hazard (Fable brief): `defaultScrollAnchor(.bottom)` is unreliable
    /// on macOS `List` because the rows are AppKit-backed. Minimal bottom-pinning
    /// idiom: append an empty trailing row tagged "bottom-anchor" and use the
    /// `ScrollViewProxy` to `scrollTo("bottom-anchor", anchor: .bottom)` whenever
    /// the row count or transient-streaming state changes.
    ///
    /// Style policy: `.listStyle(.plain)` + `.scrollContentBackground(.hidden)`
    /// to keep the bubble background the same as the canvas background.
    /// Selectability is disabled at the row level to avoid stealing focus from
    /// the composer. This is a behavioural spike; pixel parity is out of scope.
    @ViewBuilder
    private func spikeListContainer(proxy: ScrollViewProxy) -> some View {
        List {
            canvasRowsList(proxy: proxy)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(themeManager.color(.bgSurface))
        .modifier(SpikeScrollTraceBootstrap(phase: scrollPhase))
        .onScrollGeometryChangeCompat(
            transform: { geo in
                guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
                    return true
                }
                let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return distanceFromBottom < 80
            },
            action: { _, newValue in
                isAtBottom = newValue
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
        // Bottom-pinning idiom: when message count or transient state changes,
        // scroll the anchor into view. This is a direct stand-in for
        // `defaultScrollAnchor(.bottom)` because the AppKit-backed List does not
        // honour the SwiftUI anchor primitive on macOS.
        .onChange(of: messages.count) { _, _ in
            guard isAtBottom else { return }
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
        .onChange(of: streamingContent) { _, _ in
            guard isAtBottom else { return }
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
        .onChange(of: completedContent) { _, _ in
            guard isAtBottom else { return }
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
        .onChange(of: thinkingState) { _, _ in
            guard isAtBottom else { return }
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
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
            // See note above: anchor changes handled by message-count onChange below.
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
        .overlay(alignment: .bottomTrailing) {
            jumpToLatestButton(proxy: proxy)
        }
    }
    #endif

    /// Inner row content shared by both scroll-container variants. Identical
    /// row composition; only the outer container changes between baseline and
    /// spike builds.
    @ViewBuilder
    private func canvasRows() -> some View {
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

    #if SPIKE_LIST_CONTAINER
    /// Same row content as `canvasRows()` but as `List` rows (each row must be
    /// a single top-level view inside a `List` section). We split the
    /// conditional transient rows so each `if` branch is its own row. The
    /// "load earlier" button is its own row; each message is its own row;
    /// the thinking / typing / streaming / completed-bridge bubbles are
    /// single rows; the trailing anchor is its own row.
    @ViewBuilder
    private func canvasRowsList(proxy: ScrollViewProxy) -> some View {
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
            .listRowBackground(themeManager.color(.bgSurface))
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .id("load-earlier")
        }

        ForEach(messages, id: \.id) { message in
            MessageBubble(message: message)
                .listRowBackground(themeManager.color(.bgSurface))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .id(message.id)
        }

        if thinkingState == .thinking {
            ThinkingBeeIndicator(mode: .thinking)
                .listRowBackground(themeManager.color(.bgSurface))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .id("thinking-bee")
        } else if isStreaming && streamingContent.isEmpty {
            if thinkingState != .streaming {
                TypingIndicator()
                    .listRowBackground(themeManager.color(.bgSurface))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets())
                    .id("typing-indicator")
            }
        } else if showStreamingBubble {
            StreamingBubble(content: streamingContent)
                .listRowBackground(themeManager.color(.bgSurface))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .id("streaming-bubble")
        }

        if showCompletedBridge {
            CompletedBridgeBubble(content: completedContent)
                .listRowBackground(themeManager.color(.bgSurface))
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .id("completed-bridge")
        }

        Color.clear
            .frame(height: 4)
            .listRowBackground(themeManager.color(.bgSurface))
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
            .id("bottom-anchor")
    }
    #endif

    /// Jump-to-Latest button — fixed-size overlay, opacity-only transitions.
    /// Takes the ScrollViewProxy directly so it works even though the button
    /// lives outside the ScrollViewReader closure.
    private func jumpToLatestButton(proxy: ScrollViewProxy) -> some View {
        Color.clear
            .frame(width: 48, height: 48)
            .overlay {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                    isAtBottom = true
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

/// `SpikeScrollTraceBootstrap` — applied to the scroll container so the trace
/// logger sees phase and composer-height context. Lightweight: when
/// `SpikeTrace.enabled == false` this is a no-op passthrough.
struct SpikeScrollTraceBootstrap: ViewModifier {
    let phase: ScrollPhase

    func body(content: Content) -> some View {
        if SpikeTrace.enabled {
            content
                .onAppear { SpikeTrace.bootstrapIfNeeded() }
                .onChange(of: phase, initial: false) { _, newPhase in
                    Task { await ScrollTraceLogger.shared.setPhase(newPhase) }
                }
                .spikeScrollTrace(phaseProvider: { phase })
        } else {
            content
        }
    }
}

// MARK: - Scroll Geometry Compatibility (macOS 14+)

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
    func onScrollGeometryChangeCompat(
        transform: @escaping (ScrollGeometry) -> Bool,
        action: @escaping (_ oldValue: Bool, _ newValue: Bool) -> Void
    ) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            self.onScrollGeometryChange(for: Bool.self) { geo in
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
