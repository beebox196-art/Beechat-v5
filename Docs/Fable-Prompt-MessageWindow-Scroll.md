# Fable Prompt: BeeChat Message Window Scroll — Diagnosis & Solution Design

**Date:** 2026-07-08  
**Author:** Bee  
**Purpose:** Get an expert SwiftUI review to confirm whether the scroll/anchor bugs in BeeChat's message canvas are solvable on the current ScrollView+LazyVStack architecture, and if so, exactly how. **No code changes — analysis and prescription only.**

---

## Context

BeeChat is a macOS-native SwiftUI chat app (minimum deployment: macOS 14 / Sequoia). It has a message canvas that displays chat messages in a scrollable list. The current production architecture is `ScrollViewReader` + `ScrollView` + `LazyVStack(spacing: 0)`.

We recently attempted to replace this with a SwiftUI `List`-based container and abandoned the spike after hitting fundamental PreferenceKey propagation failures on macOS 26 (Tahoe). The spike retrospective is included below.

The app has been rolled back to the baseline ScrollView variant, but the original scroll issues are **worse than before the spike attempt** — possibly due to subtle regressions during the rollback, or possibly because the issues were always this bad and we didn't notice until the spike highlighted them.

## Current Bugs

### Bug 1: Topic switch does not scroll to bottom
When the user switches topics (selecting a different conversation in the sidebar), the message canvas does NOT scroll to the bottom to show the most recent messages. Instead it stays at the scroll position of the previous topic or at an arbitrary position. The `onChange(of: topicId)` handler currently does nothing — it relies on `defaultScrollAnchor(.bottom)` which only applies on initial view appearance, not when content changes.

### Bug 2: "Jump to Latest" button doesn't scroll all the way to bottom
The chevron-down button appears when `isAtBottom` is false. Clicking it calls `proxy.scrollTo("bottom-anchor", anchor: .bottom)` but often stops short of the actual bottom — sometimes by a significant amount (hundreds of points). The user has to click it multiple times or manually scroll.

### Bug 3: White-space jumps on window resize / font-scale change
Resizing the window or changing the font scale can cause large white-space gaps to appear between messages. This is the original issue that motivated the List spike.

## Current Architecture (Baseline — This Is What We Need Fixed)

```swift
// MessageCanvas.swift — the production container

struct MessageCanvas: View {
    @State private var isAtBottom: Bool = true
    @State private var measuredWidth: CGFloat = 1200
    @State private var anchorMessageId: String? = nil

    var body: some View {
        ZStack {
            themeManager.color(.bgSurface).ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        // Load earlier button
                        // ForEach(messages) { MessageBubble }
                        // StreamingBubble / TypingIndicator / CompletedBridgeBubble
                        // Color.clear.frame(height: 4).id("bottom-anchor")
                    }
                }
                .scrollContentBackground(.hidden)
                .defaultScrollAnchor(.bottom)
                .scrollBounceBehaviorCompat(axes: .vertical)
                .onScrollGeometryChangeCompat(...)  // tracks isAtBottom
                .background(WidthReader { ... })
                .onPreferenceChange(WidthPreferenceKey.self) { measuredWidth = newWidth }

                .onChange(of: anchorMessageId) { ... scrollTo anchor on load-earlier }
                .onChange(of: topicId) { _, _ in
                    // DOES NOTHING — comment says defaultScrollAnchor handles it, but it doesn't
                }

                .overlay(alignment: .bottomTrailing) {
                    jumpToLatestButton(proxy: proxy)  // scrollTo "bottom-anchor"
                }
            }
            .environment(\.canvasWidth, measuredWidth)
        }
    }
}
```

Key details:
- `BubbleWidthModifier` uses `@Environment(\.canvasWidth)` with `maxWidth: canvasWidth * 0.66`
- `canvasWidth` defaults to 1200, updated by `WidthReader` via `PreferenceKey`
- `defaultScrollAnchor(.bottom)` is used for initial positioning
- `isAtBottom` tracked via `onScrollGeometryChangeCompat` (macOS 15+) — 80px threshold from bottom
- Jump-to-latest button: `proxy.scrollTo("bottom-anchor", anchor: .bottom)` with animation
- Minimum deployment: **macOS 14** (Sequoia). macOS 15+ APIs need `if #available` guards.
- App is macOS **only** (not iOS). Running on macOS 26 Tahoe (current) and macOS 15 (minimum realistic target).

## What We Already Know Doesn't Work

### List-based container (SPIKE-A, abandoned 2026-07-06)

We replaced ScrollView+LazyVStack with a SwiftUI `List`. Three fundamental problems:

1. **PreferenceKey propagation failure on macOS 26**: `onPreferenceChange` never fires inside `List.background()` modifiers. `WidthReader` stuck at default 1200pt forever. Bubbles hardcoded to 792pt regardless of window width.

2. **AppKit-backed NSScrollView ignores SwiftUI `defaultScrollAnchor(.bottom)`**: Topic switching relied entirely on manual `scrollTo` calls, which are timing-sensitive and fragile.

3. **List content margins**: macOS `List` adds ~20pt horizontal margins per side by default, requiring `.contentMargins(.horizontal, 0)` (macOS 15+ only). Even after fixing margins, the width propagation issue remained fatal.

Full retrospective: see `Docs/Spike-A-List-Container-Retrospective.md` in the repo.

### Scroll-to-bottom on topic switch (attempted fix)

We tried wrapping `proxy.scrollTo("bottom-anchor")` in `DispatchQueue.main.async` inside `onChange(of: topicId)`. This sometimes works but is unreliable — the List layout timing is non-deterministic. On the ScrollView baseline, this approach hasn't been properly tested after the rollback.

## What I Need From You

### 1. Root Cause Analysis
For each of the three bugs, explain the exact SwiftUI mechanism that's failing:
- Why doesn't `defaultScrollAnchor(.bottom)` re-apply when the `topicId` changes (causing new content to load)?
- Why does `scrollTo("bottom-anchor", anchor: .bottom)` stop short of the actual bottom?
- Why does window resize / font-scale change cause white-space gaps in LazyVStack?

### 2. Solvability Assessment
Confirm whether these bugs are solvable on the **current ScrollView+LazyVStack architecture** (no List). If any are fundamentally broken in SwiftUI on macOS 26, say so explicitly.

### 3. Prescribed Solution
For each bug that IS solvable, give me the exact SwiftUI approach — not pseudo-code, but the specific APIs, modifiers, and patterns to use. Include:
- Which macOS version gates are needed (macOS 14 fallback vs macOS 15+ native)
- Whether `scrollPosition(id:)` / `scrollTargetLayout()` (macOS 14+) can help
- Whether `onChange(of: topicId)` is the right trigger or if we need a different mechanism
- The correct anchor strategy for "scroll to very bottom" vs "scroll to specific message"
- Any timing/async considerations (DispatchQueue.main.async, Task, etc.)

### 4. Risk Assessment
For each proposed fix:
- What could break?
- Does it interact with the other fixes?
- Does it require changes outside MessageCanvas.swift?
- Is it safe for macOS 14?

## Constraints

- **No code generation.** Analysis and prescription only.
- **Stay on ScrollView+LazyVStack.** The List approach is a confirmed dead end.
- **Minimum deployment macOS 14.** macOS 15+ APIs need `if #available` guards.
- **macOS only.** No iOS considerations needed.
- **Don't touch bubble width logic.** The 66% canvas-width constraint via `BubbleWidthModifier` works correctly on ScrollView. Don't propose changes to MessageBubble.swift.
- **Don't propose architecture changes.** No "rewrite the whole thing in AppKit." Incremental fixes to the existing container only.

## Files for Reference

The key files are:

1. **`Sources/App/UI/Components/MessageCanvas.swift`** — The scroll container, `WidthReader`, `onScrollGeometryChangeCompat`, jump button, `onChange` handlers. Full source included below.

2. **`Sources/App/UI/Components/MessageBubble.swift`** — Bubble rendering, `BubbleWidthModifier`, `CanvasWidthKey` environment key. Full source included below.

3. **`Sources/App/UI/MainWindow.swift`** — Where `MessageCanvas` is instantiated, passing `topicId: messageViewModel.selectedTopicId`, `messages`, streaming state, etc.

4. **`Sources/App/UI/ViewModels/MessageViewModel.swift`** — Topic selection logic: `selectTopic(id:)` sets `selectedTopicId` and re-starts observation.

---

## Full Source: MessageCanvas.swift

```swift
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

    private var showCompletedBridge: Bool {
        guard !isStreaming, !completedContent.isEmpty else { return false }
        if let lastAssistant = messages.last(where: { $0.role == "assistant" }),
           let content = lastAssistant.content, !content.isEmpty {
            return false
        }
        return true
    }

    @State private var isAtBottom: Bool = true
    @State private var measuredWidth: CGFloat = 1200
    @State private var anchorMessageId: String? = nil

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
                            if thinkingState != .streaming {
                                TypingIndicator()
                                    .id("typing-indicator")
                            }
                        } else if showStreamingBubble {
                            StreamingBubble(content: streamingContent)
                                .id("streaming-bubble")
                        }

                        if showCompletedBridge {
                            CompletedBridgeBubble(content: completedContent)
                                .id("completed-bridge")
                        }

                        // 4px anchor — enough for LazyVStack to render reliably,
                        // invisible to the user.
                        Color.clear
                            .frame(height: 4)
                            .id("bottom-anchor")
                    }
                }
                .scrollContentBackground(.hidden)
                .defaultScrollAnchor(.bottom)
                .scrollBounceBehaviorCompat(axes: .vertical)
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
                    // The asyncAfter nudge nudge fights with it and can cause bounce — removed.
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

private struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 1200
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ScrollGeometry {
    var contentSize: CGSize
    var containerSize: CGSize
    var contentOffset: CGPoint
}

extension View {
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
```

## Full Source: MessageBubble.swift (relevant excerpt)

```swift
struct BubbleWidthModifier: ViewModifier {
    @Environment(\.canvasWidth) var canvasWidth
    var alignment: Alignment = .leading
    
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: canvasWidth * 0.66, alignment: alignment)
    }
}

struct CanvasWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1200
}

extension EnvironmentValues {
    var canvasWidth: CGFloat {
        get { self[CanvasWidthKey.self] }
        set { self[CanvasWidthKey.self] = newValue }
    }
}
```

## Full Source: MainWindow.swift (MessageCanvas instantiation)

```swift
// Inside MainWindow body, inside a VStack:
MessageCanvas(
    messages: messageViewModel.messages,
    isStreaming: isActiveTopicStreaming,
    streamingContent: activeTopicStreamingContent,
    completedContent: syncBridgeObserver.completedContent,
    thinkingState: syncBridgeObserver.thinkingState,
    canLoadEarlier: messageViewModel.canLoadEarlier,
    topicId: messageViewModel.selectedTopicId,
    onLoadEarlier: { messageViewModel.loadEarlierMessages() }
)
```

## Key Questions for Fable

1. **`defaultScrollAnchor(.bottom)` vs content changes:** Does `defaultScrollAnchor(.bottom)` only apply on initial view appearance, or does it also anchor when the `ScrollView`'s content identity changes (e.g., when `topicId` changes and `messages` is replaced)? Apple's docs are ambiguous here.

2. **`scrollPosition(id:)` API:** macOS 14+ introduced `scrollPosition(id:)` and `scrollTargetLayout()`. Can we use `scrollPosition` to bind the scroll target to the bottom-anchor ID, and would setting it on topic switch reliably scroll to bottom? What's the interaction with `LazyVStack`?

3. **`scrollTo` stopping short:** Is there a known issue where `ScrollViewProxy.scrollTo` with `.bottom` anchor doesn't scroll fully to the target when content height changes asynchronously (e.g., streaming bubbles, WebView height updates)? What's the correct pattern?

4. **White-space on resize:** Is the `LazyVStack(spacing: 0)` + `defaultScrollAnchor(.bottom)` combination known to cause white-space jumps on macOS when the container width changes? Would `scrollPosition` binding help stabilize this?

5. **Timing of `onChange(of: topicId)`:** When topic changes, the `messages` array is replaced. Is `onChange(of: topicId)` the right place to trigger a scroll-to-bottom, or should we use `onChange(of: messages)` / `onAppear` / a different mechanism? What's the correct async pattern to ensure content is laid out before scrolling?

6. **4px bottom anchor:** We use `Color.clear.frame(height: 4).id("bottom-anchor")`. Is this a reliable scroll target, or should we use the last message's ID instead? Does the height matter?

---

*Prepared by Bee for Fable review. No code generation requested — analysis and prescription only.*