# BC5-SPEC-005 Issue: Scroll Bar Bouncing During Streaming

**Date:** 2026-05-08  
**Priority:** Medium (UX irritation, not broken)  
**Status:** DRAFT — Team Review  

---

## Problem

The scrollbar bounces up and down during and after the "bee spinning" (thinking/streaming) state. Adam reports this is "slightly irritating."

## Root Cause

Multiple scroll triggers fire in rapid succession during streaming, and each `scrollToBottom()` call fires **twice** (immediate + 200ms fallback):

1. `onChange(of: isStreaming)` fires when streaming starts → `scrollToBottom()` (2 scroll calls)
2. `onChange(of: showStreamingBubble)` fires when the streaming bubble appears → `scrollToBottom()` (2 scroll calls)
3. `onChange(of: messages.count)` fires on every message update during streaming → `scrollToBottom()` (2 scroll calls each)
4. The first call in each `scrollToBottom()` uses `withAnimation(.easeInOut(duration: 0.2))` — this animated scroll fights with SwiftUI's own layout adjustments as the streaming bubble grows

During a typical streaming response, this can produce 6-10+ `scrollTo` calls, each with animation, causing the scrollbar to visibly bounce.

## Proposed Fix

### 1. Remove animation from `scrollToBottom()`

The animated scroll looks nice on topic switch but causes bouncing during streaming. Use `withAnimation` only for the initial topic-switch scroll, not for every message update:

```swift
private func scrollToBottom(animated: Bool = false) {
    guard let proxy = scrollProxy else { return }
    DispatchQueue.main.async { [proxy] in
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
    // Fallback only for initial topic switch
    if animated {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [proxy] in
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}
```

### 2. Deduplicate streaming scroll calls

During streaming, only the first scroll is needed. Subsequent calls within a short window should be suppressed:

```swift
@State private var lastScrollTime: Date = .distantPast

private func scrollToBottomIfNeeded() {
    let now = Date()
    guard now.timeIntervalSince(lastScrollTime) > 0.3 else { return }
    lastScrollTime = now
    scrollToBottom()
}
```

Use `scrollToBottom()` (with animation and fallback) only for:
- Topic switch (`onChange(of: topicId)`)
- `onAppear`

Use `scrollToBottomIfNeeded()` (deduplicated, no animation) for:
- `onChange(of: messages.count)` during streaming
- `onChange(of: isStreaming)`
- `onChange(of: showStreamingBubble)`

### 3. Remove the 200ms fallback during streaming

The fallback exists for LazyVStack layout timing on topic switch. During streaming, content is already rendered — no need for a retry. Only use the fallback for the initial topic-switch scroll.

---

## Questions for Team

1. Should `scrollToBottom` ever be animated? Only topic switch, or never?
2. Is 0.3s the right deduplication window, or should it be shorter?
3. Should we also debounce the `onAppear`/`onDisappear` for `isAtBottom` during streaming to prevent the Jump button flickering?

*Awaiting team review before implementation.*