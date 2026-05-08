# BeeChat v5: Jump to Latest Message

**Spec ID:** BC5-SPEC-005  
**Date:** 2026-05-08 (v4 — final, build-ready)  
**Author:** Bee (coordinator)  
**Reviewers:** Q (implementation), Mel (UX), Kieran (safety)  
**Status:** APPROVED — Ready for Build  
**Priority:** Medium (UX polish)  

---

## Problem Statement

When a conversation has many messages, BeeChat sometimes jumps to the top on topic switch. When scrolled up, new messages appear below with no indication and no way to jump back.

---

## Root Cause

`scrollToBottom` fires when `messages.count` changes (0→N on topic switch), but `LazyVStack` hasn't laid out the bottom-anchor yet. `scrollTo` on a non-existent ID is a no-op, so the view stays at the top.

---

## Solution

All changes in two files: `MessageCanvas.swift` (primary) and `MainWindow.swift` (one-line parameter addition).

### 1. Scroll position detection (macOS 14 compatible)

Use GeometryReader + PreferenceKey (not `onScrollGeometryChange`, which requires macOS 15+). Add hysteresis to prevent button flicker.

**Add coordinate space to the ScrollView** (without this, GeometryReader returns `.zero`):

```swift
ScrollView(.vertical, showsIndicators: true) { ... }
    .coordinateSpace(name: "messageScrollView")
```

New state:

```swift
@State private var isAtBottom: Bool = true

private let enterBottomThreshold: CGFloat = 50   // within 50px = "at bottom"
private let leaveBottomThreshold: CGFloat = 120  // >120px away = "scrolled up"
```

Place a GeometryReader on the bottom-anchor:

```swift
Color.clear
    .frame(height: 1)
    .id("bottom-anchor")
    .overlay(
        GeometryReader { geo in
            Color.clear.preference(
                key: BottomAnchorPreferenceKey.self,
                value: geo.frame(in: .named("messageScrollView")).minY
            )
        }
    )
```

Handle preference change with hysteresis. `bottomY` is the minY of the bottom-anchor in the scroll view's coordinate space:

```swift
.onPreferenceChange(BottomAnchorPreferenceKey.self) { bottomY in
    if bottomY < enterBottomThreshold {
        isAtBottom = true
    } else if bottomY > leaveBottomThreshold {
        isAtBottom = false
    }
    // Between thresholds: keep current state (hysteresis prevents flicker)
}
```

### 2. Conditional auto-scroll

Gate ALL scroll-triggering handlers on `isAtBottom`, with two exceptions:

- **User sends a message** → always scroll to bottom
- **Streaming is active** → always scroll to bottom (users expect to follow streams)

```swift
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        withAnimation(.easeInOut(duration: 0.15)) {
            scrollProxy?.scrollTo(anchorId, anchor: .top)
        }
        anchorMessageId = nil
    } else if isAtBottom || isUserMessage || isStreaming {
        scrollToBottom()
    }
    // else: user is scrolled up reading — don't force scroll.
    // Jump button shows automatically via !isAtBottom.
}
.onChange(of: isStreaming) { _, isNowStreaming in
    if isNowStreaming { scrollToBottom() }
}
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing { scrollToBottom() }
}
```

Note: `isStreaming` and `showStreamingBubble` handlers always scroll — streaming should auto-follow regardless of scroll position. This matches user expectations. No separate `showJumpButton` state — button visibility is driven entirely by `!isAtBottom`.

### 3. Detect user-sent messages

```swift
private var isUserMessage: Bool {
    guard let lastMessage = messages.last else { return false }
    return lastMessage.role == "user"
}
```

When the user sends a message, it's added to the array and `messages.count` fires. The handler checks `isUserMessage` and always scrolls. Confirmed: `Message.role` is `public var role: String`.

### 4. Jump to Latest button

Button visibility driven by `!isAtBottom`. No separate `showJumpButton` state.

```swift
if !isAtBottom {
    Button(action: {
        scrollToBottom()
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
```

### 5. Fix "scrolls to top" bug with retry

Store `ScrollViewProxy` in `@State` for safe async capture. Set it as the first line of `.onAppear` before calling `scrollToBottom()`. Use retry mechanism:

```swift
@State private var scrollProxy: ScrollViewProxy?

private func scrollToBottom() {
    guard let proxy = scrollProxy else { return }
    // First attempt: next run loop (after layout)
    DispatchQueue.main.async { [proxy] in
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
    // Fallback: 200ms later (guarantees LazyVStack has rendered)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [proxy] in
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
}
```

In `.onAppear`:
```swift
.onAppear {
    scrollProxy = proxy
    scrollToBottom()
}
```

**Note on 200ms fallback:** If the user scrolls up within 200ms of a `scrollToBottom()` call, the fallback could override their manual scroll. This is an extremely unlikely edge case (user must send a message AND start scrolling up within 200ms). Accepted risk.

### 6. Reset on topic switch

Add `topicId: String?` parameter to `MessageCanvas`. Pass `messageViewModel.selectedTopicId` from MainWindow.

```swift
var topicId: String? = nil
```

When the topic changes, reset scroll state:

```swift
.onChange(of: topicId) { _, newId in
    if newId != nil {
        isAtBottom = true
    }
}
```

This ensures a new topic always starts scrolled to bottom, even if the previous topic was scrolled up.

### 7. Clean up dead state

Remove `@State private var autoScroll = true` — it's never used. Confirmed: only reference in the entire codebase is the declaration line.

### 8. PreferenceKey definition

```swift
private struct BottomAnchorPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
```

Available since macOS 10.15. No availability issues on macOS 14.

---

## What Does NOT Change

- `MessageListObserver` — no changes
- `MessageViewModel` — no changes
- `MainWindow` — passes `topicId: messageViewModel.selectedTopicId` to `MessageCanvas` (one-line addition)
- `Composer` — no changes
- Database — no changes
- `SyncBridge` — no changes
- `WidthReader` / `WidthPreferenceKey` — untouched
- `anchorMessageId` logic for "Load earlier messages" — untouched
- `ThinkingBeeIndicator`, `TypingIndicator`, `StreamingBubble` — untouched

---

## Implementation Steps

1. Add `var topicId: String? = nil` parameter to `MessageCanvas`
2. Pass `topicId: messageViewModel.selectedTopicId` from `MainWindow`
3. Remove `@State private var autoScroll = true`
4. Add `@State private var isAtBottom: Bool = true`
5. Add `@State private var scrollProxy: ScrollViewProxy?`
6. Add `BottomAnchorPreferenceKey` struct
7. Add `.coordinateSpace(name: "messageScrollView")` to the ScrollView
8. Add GeometryReader overlay on `bottom-anchor`
9. Add `.onPreferenceChange` with hysteresis thresholds (50px/120px)
10. Store proxy in `.onAppear` (set `scrollProxy = proxy` as first line) and update all `scrollToBottom` call sites
11. Gate `.onChange(of: messages.count)` on `isAtBottom || isUserMessage || isStreaming`
12. Keep `.onChange(of: isStreaming)` and `.onChange(of: showStreamingBubble)` always-scrolling (streaming auto-follows)
13. Add Jump button overlay (visibility driven by `!isAtBottom`, no separate `showJumpButton` state)
14. Add `.onChange(of: topicId)` to reset `isAtBottom`
15. Add retry mechanism to `scrollToBottom()`
16. Add accessibility labels to Jump button
17. Test all 12 scenarios

**Estimated: 0.75 day**

---

## Test Cases

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Switch to topic with existing messages | Scroll lands at latest message |
| 2 | Send a message while at bottom | Auto-scrolls to new message |
| 3 | Scroll up to read older messages | No auto-scroll, Jump button appears |
| 4 | Tap Jump to Latest button | Scrolls to bottom, button disappears |
| 5 | New message arrives while scrolled up | Jump button stays visible, no forced scroll |
| 6 | Scroll back to bottom manually | Jump button disappears (hysteresis: within 50px) |
| 7 | Streaming starts while at bottom | Auto-scrolls during streaming |
| 8 | Streaming starts while scrolled up | Auto-scrolls to bottom (streaming always follows) |
| 9 | User sends message while scrolled up | Always scrolls to bottom |
| 10 | Load earlier messages | Scroll position preserved (anchor) |
| 11 | Topic switch after scrolling up in previous topic | New topic starts at bottom |
| 12 | Momentum scroll near bottom boundary | No button flicker (hysteresis) |

---

## Risk Table

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | PreferenceKey fires too frequently | Low | Medium | Hysteresis prevents state flicker; SwiftUI coalesces preference changes |
| 2 | Retry causes visible double-scroll | Very Low | Low | Second attempt is unanimated no-op if first succeeded |
| 3 | `isAtBottom` not reset on topic switch | N/A | N/A | Explicit `.onChange(of: topicId)` reset |
| 4 | Streaming forces scroll when user scrolled up | By design | Low | Matches user expectations — streams auto-follow |
| 5 | LazyVStack doesn't render bottom-anchor | Low | Medium | Retry fallback after 200ms |
| 6 | 200ms fallback overrides manual scroll | Very Low | Low | User must scroll up within 200ms of send — accepted risk |
| 7 | `scrollProxy` goes stale across view rebuilds | Very Low | Low | `scrollTo` on stale proxy is a no-op, not a crash |

---

*Approved by Q, Mel, and Kieran on 2026-05-08. Ready for build.*