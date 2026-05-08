# BeeChat v5: Jump to Latest Message

**Spec ID:** BC5-SPEC-005  
**Date:** 2026-05-08  
**Author:** Bee (coordinator)  
**Status:** DRAFT — Team Review  
**Priority:** Medium (UX polish)  

---

## Problem Statement

When a conversation has many messages, BeeChat sometimes jumps to the top (oldest messages) on topic switch or message arrival. The user must manually scroll down to find the latest messages. There is no visual indicator that new messages have arrived while scrolled up, and no way to jump back to the latest message.

Even when auto-scroll works correctly, if the user scrolls up to read older messages, new incoming messages silently appear below with no indication — the user doesn't know there's something new to read.

---

## Root Cause Analysis

### 1. Topic switch resets the message list

`MessageListObserver.startObserving()` clears all messages and starts with `messageLimit = 25`. The `MessageCanvas` then calls `scrollToBottom` on `onAppear`. But if the stream hasn't delivered messages yet, there's nothing to scroll to. When messages arrive later (via `.onChange(of: messages.count)`), the scroll happens — but with `LazyVStack`, the bottom-anchor may not be laid out yet, causing the scroll to land at the top instead.

### 2. No scroll position tracking

`MessageCanvas` has `@State private var autoScroll = true` but it's never set to `false`. There is no detection of the user scrolling up, and no way to know if the view is "at the bottom" or "scrolled up."

### 3. No new-message indicator

When the user is scrolled up and new messages arrive, there is no visual cue that new content exists below the visible area.

---

## Solution

Three changes, all within `MessageCanvas.swift`:

### 1. Detect scroll position

Use a `GeometryReader` at the bottom of the scroll view to detect whether the user is near the bottom. When the bottom-anchor is within a threshold of the scroll viewport, the user is "at bottom." When it's outside the threshold, the user has scrolled up.

```swift
@State private var isAtBottom: Bool = true
private let bottomThreshold: CGFloat = 80  // pixels from bottom to count as "at bottom"
```

On every scroll frame, check if the bottom-anchor is visible/near the viewport bottom edge. Set `isAtBottom` accordingly.

### 2. Conditional auto-scroll

Only auto-scroll to the bottom when `isAtBottom == true`. If the user has scrolled up, don't force them back down — let them read.

Existing `scrollToBottom` calls in `.onChange(of: messages.count)` and `.onChange(of: isStreaming)` should be gated:

```swift
.onChange(of: messages.count) { _, _ in
    if isAtBottom {
        scrollToBottom(proxy: proxy)
    } else {
        showJumpButton = true  // show "new messages" indicator
    }
}
```

### 3. Jump to Latest button

An overlay button that appears when the user is not at the bottom. Positioned in the bottom-right corner of the message canvas, above the composer.

```swift
if !isAtBottom {
    Button(action: {
        scrollToBottom(proxy: proxy)
        isAtBottom = true
    }) {
        Image(systemName: "chevron.down")
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 36, height: 36)
            .background(.ultraThinMaterial)
            .clipShape(Circle()))
    }
    .buttonStyle(.plain)
    .transition(.opacity.combined(with: .move(edge: .bottom)))
    .padding(.bottom, 12)
    .padding(.trailing, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
}
```

---

## What Changes

| File | Change |
|------|--------|
| `MessageCanvas.swift` | Add `isAtBottom` detection, gate auto-scroll, add Jump to Latest overlay |

That's it. One file, three logical changes. No new views, no new models, no new dependencies.

---

## What Does NOT Change

- `MessageListObserver` — no changes
- `MessageViewModel` — no changes
- `MainWindow` — no changes
- `Composer` — no changes
- Database — no changes
- `SyncBridge` — no changes

---

## Detailed Design

### Scroll Position Detection

Use `onAppear` / `onDisappear` of an invisible anchor view at the bottom of the `LazyVStack`, combined with `scrollPosition` (iOS 17+ / macOS 14+). Since BeeChat targets macOS 14+, we can use the native `scrollPosition(id:)` API.

However, `scrollPosition(id:)` tracks which item is visible, not whether the user is "near the bottom." The most reliable approach for "near bottom" detection is a `GeometryReader` anchor preference:

```swift
// Invisible anchor at the very bottom of the content
Color.clear
    .frame(height: 1)
    .id("bottom-anchor")
    .overlay(
        GeometryReader { geo in
            Color.clear.preference(
                key: BottomAnchorPreferenceKey.self,
                value: geo.frame(in: .named("scroll")).minY
            )
        }
    )
```

Then read the preference and compare against the scroll view's visible height:

```swift
.onPreferenceChange(BottomAnchorPreferenceKey.self) { bottomY in
    // If bottom-anchor's top edge is within threshold of the visible area's bottom
    isAtBottom = (bottomY < visibleHeight + bottomThreshold)
    showJumpButton = !isAtBottom
}
```

### Topic Switch: Ensure Bottom on Entry

When switching topics, the message list resets. We must ensure the user starts at the bottom of the new topic. Gate this with a `topicChangeToken` — increment it when the topic changes, force scroll to bottom on that change regardless of `isAtBottom`.

```swift
@State private var topicChangeToken: Int = 0

// In MainWindow, when selectTopic fires:
// MessageCanvas gets a new messages array, so .onChange(of: messages) fires.
// On .onChange of the messages array identity (not count), scroll to bottom unconditionally.
```

Simpler approach: use `.id()` on the `MessageCanvas` tied to `selectedTopicId`. When the topic changes, SwiftUI destroys and recreates the view, and `.onAppear` fires — which already calls `scrollToBottom`. This should work if the messages are already loaded.

**The real fix for the "scrolls to top" bug:** The issue is that `scrollToBottom` fires when `messages.count` changes from 0→N (stream delivers initial batch), but the `LazyVStack` hasn't laid out the bottom-anchor yet. Fix: add a small delay or use `DispatchQueue.main.async` to ensure layout is complete before scrolling.

```swift
private func scrollToBottom(proxy: ScrollViewProxy) {
    DispatchQueue.main.async {
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}
```

This ensures the layout pass is complete before we try to scroll.

---

## Implementation Steps

1. Add `isAtBottom` and `showJumpButton` state to `MessageCanvas`
2. Add `BottomAnchorPreferenceKey` for scroll position detection
3. Add `GeometryReader` overlay on bottom-anchor to emit position
4. Add `.onPreferenceChange` to update `isAtBottom`
5. Gate existing `scrollToBottom` calls on `isAtBottom` (except `onAppear`)
6. Fix `scrollToBottom` with `DispatchQueue.main.async` to ensure layout completion
7. Add Jump to Latest overlay button
8. Test: topic switch lands at bottom, scrolling up shows button, tapping jumps back, new messages while scrolled up show button

**Estimated: 0.5 day**

---

## Risk Table

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | `DispatchQueue.main.async` scroll delay feels sluggish | Low | Low | 0ms delay (next run loop only). If noticeable, use `withAnimation` to mask it. |
| 2 | PreferenceKey fires too frequently, causes jank | Low | Medium | Throttle with simple timestamp check — ignore if < 100ms since last update. |
| 3 | Jump button overlaps streaming bubble | Low | Low | Position above the streaming area with enough padding. |
| 4 | `scrollTo` with `LazyVStack` still lands at top | Medium | Medium | `DispatchQueue.main.async` fix. If still flaky, add 2nd attempt after 200ms. |

---

## Test Cases

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Switch to topic with existing messages | Scroll lands at latest message |
| 2 | Send a message while at bottom | Auto-scrolls to new message |
| 3 | Scroll up to read older messages | No auto-scroll on new messages, Jump button appears |
| 4 | Tap Jump to Latest button | Scrolls to bottom, button disappears |
| 5 | New message arrives while scrolled up | Jump button appears (stays) |
| 6 | User scrolls back to bottom manually | Jump button disappears |
| 7 | Streaming starts while at bottom | Auto-scrolls during streaming |
| 8 | Streaming starts while scrolled up | No forced scroll, Jump button visible |
| 9 | Load earlier messages | Scroll position stays on current message (anchor preservation already works) |
| 10 | Topic switch after having scrolled up in previous topic | New topic starts at bottom |

---

## Questions for Review

1. ~~Jump button style~~ — **Circle with chevron down.** Decided: circular button with frosted glass background.
2. ~~"New messages" count~~ — **No count.** Sidebar unread indicator handles this. Button is just a jump-to-latest affordance.
3. **Animation** — Button appears/disappears with opacity+slide. Is this the right feel, or should it be instant?

---

*Ready for team review.*