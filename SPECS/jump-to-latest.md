# BeeChat v5: Jump to Latest Message

**Spec ID:** BC5-SPEC-005  
**Date:** 2026-05-08 (v2 — revised after team review)  
**Author:** Bee (coordinator)  
**Reviewers:** Q (implementation), Mel (UX), Kieran (safety)  
**Status:** APPROVED — Ready for Build  
**Priority:** Medium (UX polish)  

---

## Problem Statement

When a conversation has many messages, BeeChat sometimes jumps to the top (oldest messages) on topic switch. The user must manually scroll down. When scrolled up reading older messages, new messages appear below with no indication. There is no way to jump back to the latest message.

---

## Root Cause

`MessageCanvas` calls `scrollToBottom` via `.onChange(of: messages.count)` when messages arrive, but `LazyVStack` hasn't laid out the bottom-anchor yet. `scrollTo` on a non-existent ID is a no-op, so the view stays at the top.

---

## Solution

Three changes, one file (`MessageCanvas.swift`):

### 1. Detect scroll position with `onScrollGeometryChange`

Use the macOS 14+ native API instead of GeometryReader+PreferenceKey. This fires only when the computed value changes, not on every frame — no jank.

```swift
@State private var isAtBottom: Bool = true

ScrollView(.vertical, showsIndicators: true) { ... }
    .onScrollGeometryChange(for: Bool.self) { geometry in
        let remaining = geometry.contentSize.height - geometry.contentBounds.maxY
        return remaining < bottomThreshold
    } action: { oldValue, newValue in
        // Hysteresis: use different thresholds for entering/leaving bottom
        // to prevent flicker during momentum scrolling
        if oldValue && !newValue {
            // Was at bottom, now scrolled up — only trigger if clearly away
            let remaining = // recompute from geometry
            isAtBottom = remaining < leaveBottomThreshold
        } else if !oldValue && newValue {
            // Was scrolled up, now near bottom — use stricter threshold
            isAtBottom = true
        } else {
            isAtBottom = newValue
        }
    }
```

**Hysteresis thresholds:**
- `enterBottom` (stricter): 50px — must be within 50px to count as "at bottom"
- `leaveBottom` (looser): 120px — must scroll more than 120px away to leave "at bottom"

This prevents flicker when the user scrolls near the boundary.

### 2. Conditional auto-scroll with streaming and send overrides

Gate auto-scroll on `isAtBottom`, except for two cases:

```swift
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        // Preserve position when loading earlier messages
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(anchorId, anchor: .top)
        }
        anchorMessageId = nil
    } else if isAtBottom || isUserMessage || isActiveTopicStreaming {
        scrollToBottom(proxy: proxy)
    } else {
        // User is scrolled up reading — don't force them down
        showJumpButton = true
    }
}
```

- `isUserMessage`: true when the latest message has role "user" — always scroll to see your own message
- `isActiveTopicStreaming`: true when streaming is active for the current topic — always follow the stream

### 3. Jump to Latest button overlay

A circular frosted-glass button that appears when the user is not at the bottom:

```swift
if !isAtBottom {
    Button(action: {
        scrollToBottom(proxy: scrollProxy)
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

### 4. Fix the "scrolls to top" bug

Store `ScrollViewProxy` in `@State` for safe async capture. Use a retry mechanism for `LazyVStack` layout timing:

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

### 5. Clean up dead state

Remove `@State private var autoScroll = true` — it's unused and would conflict with `isAtBottom`.

---

## What Does NOT Change

- `MessageListObserver` — no changes
- `MessageViewModel` — no changes  
- `MainWindow` — no changes
- `Composer` — no changes
- Database — no changes
- `SyncBridge` — no changes

---

## Implementation Steps

1. Remove dead `autoScroll` state from `MessageCanvas`
2. Add `@State private var isAtBottom: Bool = true`
3. Add `@State private var scrollProxy: ScrollViewProxy?`
4. Store proxy in `onAppear` of `ScrollViewReader`
5. Add `onScrollGeometryChange` with hysteresis thresholds
6. Gate auto-scroll on `isAtBottom || isUserMessage || isActiveTopicStreaming`
7. Add Jump to Latest overlay button
8. Replace `scrollToBottom(proxy:)` with retry mechanism
9. Add accessibility labels
10. Test all 10 scenarios

**Estimated: 0.75 day**

---

## Test Cases

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Switch to topic with existing messages | Scroll lands at latest message |
| 2 | Send a message while at bottom | Auto-scrolls to new message |
| 3 | Scroll up to read older messages | No auto-scroll, Jump button appears |
| 4 | Tap Jump to Latest button | Scrolls to bottom, button disappears |
| 5 | New message arrives while scrolled up | Jump button stays visible |
| 6 | Scroll back to bottom manually | Jump button disappears |
| 7 | Streaming starts while at bottom | Auto-scrolls during stream |
| 8 | Streaming starts while scrolled up | No forced scroll, Jump button visible |
| 9 | User sends message while scrolled up | Always scrolls to bottom |
| 10 | Load earlier messages | Scroll position preserved (anchor) |
| 11 | Topic switch after scrolling up in previous topic | New topic starts at bottom |
| 12 | Momentum scrolling near bottom | No button flicker (hysteresis) |

---

*Approved by Q, Mel, and Kieran on 2026-05-08. Ready for build.*