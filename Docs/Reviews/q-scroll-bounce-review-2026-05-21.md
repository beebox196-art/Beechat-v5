# Builder's Review: MessageCanvas Scroll Bounce & White Space

**Date:** 2026-05-21
**Author:** Q (builder review)
**Commit reviewed:** `b4d767c` (v0.5.4-scroll-fix4)
**Original baseline:** `696b33a`
**Issues:** Scroll bounce during streaming, white space below messages

---

## Executive Summary

The current `MessageCanvas.swift` at `b4d767c` has grown from ~120 lines (original) to ~380 lines through four incremental fix rounds. The DIAGNOSIS document correctly identified that each round made things worse by adding complexity instead of addressing the root cause.

**My assessment: The current code CAN be simplified back toward the original approach while preserving all modern features.** The minimal safe change set is **5 specific code changes** (not a full revert). The key insight from DIAGNOSIS is correct: stop animating during streaming, keep a stable scroll target, and let `defaultScrollAnchor(.bottom)` do its job.

---

## What the Current Code Does (Features Inventory)

The current code preserves these features that the original `696b33a` did not have:

| Feature | Current Status | Must Preserve? |
|---|---|---|
| **Jump-to-Latest button** | Working, fixed-size overlay (48×48), opacity-driven | ✅ Yes |
| **isAtBottom detection** | Hysteresis (50px enter / 120px leave) via `onScrollGeometryChangeCompat` | ✅ Yes |
| **Load Earlier messages** | Button + anchor preservation on load | ✅ Yes |
| **ThinkingBeeIndicator** | `.thinking` state UI | ✅ Yes |
| **Topic switch scroll** | `pendingTopicScroll` + animated scroll | ✅ Yes |
| **Safe area inset handling** | `contentFillsContainer` check + force scroll | ⚠️ Debatable |
| **Scroll correction on layout** | `scheduleScrollCorrection` (100ms Task) | ⚠️ Debatable |
| **Debounce (200ms)** | Prevents rapid re-trigger | ⚠️ May be excessive |
| **macOS 14 fallback** | `onAppear` + `asyncAfter` for short content | ⚠️ Unclear if needed |

---

## Root Cause Analysis (Current State)

### 1. The Streaming Poll Diff Guard (FIXED in current code ✅)

`SyncBridgeObserver.startStreamingPoll()` at line 178 correctly implements:

```swift
if self.streamingContent != content {
    self.streamingContent = content
}
```

**Verdict:** This guard is present and correct. It prevents the 50ms poll from invalidating SwiftUI when the string hasn't changed. **Path A from DEBUG.md is closed.**

### 2. The Messages Array Diff Guard (FIXED in current code ✅)

`MessageListObserver.setAllMessages(_:)` at line 36 correctly implements:

```swift
func setAllMessages(_ allMessages: [Message]) {
    guard messagesDiffer(self.allMessages, allMessages) else { return }
    self.allMessages = allMessages
    applyWindow()
}
```

The `messagesDiffer` function checks `id`, `content`, `timestamp`, and `role`. **Path C from DEBUG.md is closed.**

### 3. What's Still Broken

Despite the diff guards, Adam reports **two remaining issues**:

1. **Scroll bounce during streaming** — especially in the Beechat Mobile topic
2. **White space** — blank space below messages

The current code has **three problematic mechanisms** that the DIAGNOSIS correctly identified:

#### Problem A: `scheduleScrollCorrection` creates a secondary feedback loop

```swift
private func scheduleScrollCorrection(proxy: ScrollViewProxy) {
    scrollCorrectionTask?.cancel()
    scrollCorrectionTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        guard isAtBottom else { return }
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```

This is called from:
- `.onChange(of: messages.count)` — every new message
- `.onChange(of: containerHeight)` — every Composer height change

**Why it's a problem:** During streaming, `messages.count` changes when the assistant message is committed. This schedules a correction. But `defaultScrollAnchor(.bottom)` is *already* keeping the view at the bottom. The explicit `scrollToBottom` fires 100ms later, fighting the natural anchor behavior. If the content has grown in that 100ms, the explicit scroll lands at a different position than the anchor would have, creating the visible bounce.

**DIAGNOSIS is correct:** Remove `scheduleScrollCorrection`. The original code had no such mechanism and didn't need it.

#### Problem B: The 200ms debounce is wrong-direction

```swift
private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
    let now = Date()
    if now.timeIntervalSince(lastScrollTime) < 0.2 {
        return
    }
    lastScrollTime = now
    ...
}
```

The 200ms debounce **suppresses** scroll calls. But the DIAGNOSIS says the problem is **animation during streaming**, not too many scrolls. The diff guards (D1, D2 from DEBUG.md) already prevent the rapid-fire triggers. The debounce is now **masking necessary scrolls** and contributing to white space (the scroll that should happen doesn't).

**DIAGNOSIS is correct:** The fix is "no animation during streaming," not "debounce scrolls."

#### Problem C: `contentFillsContainer` short-content fallback fights `defaultScrollAnchor`

```swift
if !contentFillsContainer {
    scrollToBottom(proxy: proxy, animated: false)
}
```

This fires on every `messages.count` change when content is short. It's an attempt to fix "white space on topic switch" but it's unnecessary. `defaultScrollAnchor(.bottom)` handles short content natively on macOS 15+. On macOS 14, the fallback in `onScrollGeometryChangeCompat` handles it. This explicit check adds another scroll trigger that can fight the anchor.

**DIAGNOSIS is correct:** This should not exist. The original code had no such check.

#### Problem D: The bottom anchor is 8px, not 1px

```swift
Color.clear
    .frame(height: 8)
    .id("bottom-anchor")
```

The original was 1px. DIAGNOSIS recommends 4px (enough for LazyVStack to render reliably, invisible to user). 8px is **double** the recommendation. This creates more blank space below messages — contributing to the "white space" issue.

---

## Assessment of Current Features

### `onScrollGeometryChangeCompat` — KEEP (with simplification)

This is the most complex addition, but it's necessary for:
1. **Jump-to-Latest button** — needs `isAtBottom` state
2. **Hysteresis** — prevents button flicker during layout shifts

**However**, the current implementation is over-engineered:
- It tracks `contentHeight` and `containerHeight` via `@State`, which are only used for `contentFillsContainer`
- The `transform` closure reads `@State isAtBottom` (the `if isAtBottom` branch), which is technically a side effect in a supposedly "pure" closure. SwiftUI tolerates this on macOS but it's fragile.
- The macOS 14 fallback has an empty `asyncAfter` block (line 341: `// On macOS 14, we can't track geometry...` with no actual code inside).

**Simplification:** Remove `contentHeight`/`containerHeight` tracking. Keep only `isAtBottom`. The `contentFillsContainer` fallback is unnecessary.

### `scheduleScrollCorrection` — REMOVE

As analyzed above, this creates a feedback loop. The original code had no such mechanism.

### `scrollToBottom` debounce — REMOVE or reduce

The diff guards (D1, D2) already prevent rapid-fire triggers. A 50ms guard is sufficient for safety. 200ms is excessive and masks real scroll needs.

### Jump-to-Latest button — KEEP

The overlay approach (fixed 48×48 container, opacity changes) is correct per DIAGNOSIS. It doesn't affect scroll geometry. Preserve as-is.

### `contentFillsContainer` — REMOVE

This entire computed property and its usage should go. `defaultScrollAnchor(.bottom)` handles short content.

### macOS 14 fallback — SIMPLIFY

The current fallback does nothing useful. Either implement a real fallback or remove it entirely (macOS 15+ requirement is acceptable for desktop).

---

## Minimal Safe Change Set

### Change 1: Simplify `scrollToBottom` — remove debounce, add streaming guard

```swift
/// Scroll to bottom. No animation during streaming — animation fights with
/// SwiftUI's layout engine as content grows, causing visible bounce.
/// Animated scroll only for user-initiated actions (topic switch, onAppear).
private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
    if isStreaming {
        // No animation during streaming — let defaultScrollAnchor(.bottom) handle it
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    } else if animated {
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    } else {
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
}
```

**Rationale:** This is exactly what DIAGNOSIS recommended. No debounce needed — diff guards prevent rapid calls. The `isStreaming` check replaces the debounce as the primary anti-bounce mechanism.

### Change 2: Reduce bottom anchor from 8px to 4px

```swift
Color.clear
    .frame(height: 4)
    .id("bottom-anchor")
```

**Rationale:** DIAGNOSIS says 4px is enough for LazyVStack to render reliably. 8px creates visible white space.

### Change 3: Remove `scheduleScrollCorrection` entirely

Delete:
- `@State private var scrollCorrectionTask: Task<Void, Never>?`
- `private func scheduleScrollCorrection(proxy: ScrollViewProxy)`
- Calls to `scheduleScrollCorrection` in `.onChange(of: messages.count)` and `.onChange(of: containerHeight)`

**Rationale:** This is a feedback loop source. The original code had no such mechanism.

### Change 4: Remove `contentFillsContainer` and its usage

Delete:
- `@State private var contentHeight: CGFloat = 0`
- `@State private var containerHeight: CGFloat = 0`
- `private var contentFillsContainer: Bool { ... }`
- The `if !contentFillsContainer { scrollToBottom(...) }` block in `.onChange(of: messages.count)`
- The `.onChange(of: containerHeight)` handler entirely

Simplify `onScrollGeometryChangeCompat` to track only `isAtBottom`:

```swift
.onScrollGeometryChangeCompat(
    transform: { geo in
        guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
            return true
        }
        let enterThreshold: CGFloat = 50
        let leaveThreshold: CGFloat = 120
        let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
        if isAtBottom {
            return distanceFromBottom < leaveThreshold
        } else {
            return distanceFromBottom < enterThreshold
        }
    },
    action: { _, newValue in
        isAtBottom = newValue
    }
)
```

With `ScrollGeometryResult` simplified to just `Bool` (or using `Bool` directly).

**Rationale:** `contentHeight`/`containerHeight` are only used for `contentFillsContainer`, which we're removing. The transform closure reading `isAtBottom` is a known side effect — simplifying to `Bool` makes this explicit.

### Change 5: Restore `.onChange(of: showStreamingBubble)` scroll trigger

The original `696b33a` had:

```swift
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing {
        scrollToBottom(proxy: proxy)
    }
}
```

The current code **removed this**. DIAGNOSIS correctly identifies this as a mistake — when the streaming bubble first appears (empty → has content), something needs to scroll to it. Without this handler, the first chunk of streaming content may not trigger a scroll.

Add it back:

```swift
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing {
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```

**Note:** Use `animated: false` here because the streaming bubble appearing is part of streaming — animation would fight the layout engine.

---

## What These 5 Changes Preserve

| Feature | Status after changes |
|---|---|
| Jump-to-Latest button | ✅ Preserved (unchanged) |
| isAtBottom detection | ✅ Preserved (simplified but same hysteresis) |
| Load Earlier messages | ✅ Preserved (unchanged) |
| ThinkingBeeIndicator | ✅ Preserved (unchanged) |
| Topic switch scroll | ✅ Preserved (unchanged) |
| macOS 14 fallback | ✅ Preserved (simplified or acceptable to require macOS 15+) |
| Debounce | ❌ Removed (not needed with diff guards) |
| Scroll correction | ❌ Removed (source of bounce) |
| contentFillsContainer | ❌ Removed (defaultScrollAnchor handles it) |

---

## What About the `onScrollGeometryChangeCompat` Side Effect?

The current `transform` closure reads `@State isAtBottom`:

```swift
if isAtBottom {
    atBottom = distanceFromBottom < leaveThreshold
} else {
    atBottom = distanceFromBottom < enterThreshold
}
```

This is technically a side effect in a "pure" closure. On macOS 15+, `onScrollGeometryChange`'s transform closure is documented to be pure — but in practice, reading `@State` works because SwiftUI's state system is synchronous within the same view update. However, it's fragile.

**Better approach:** Use a local variable instead of `@State` for hysteresis. But this requires either:
1. A custom `PreferenceKey`-based approach (complex)
2. Accepting the side effect (works in practice)

**Recommendation:** Keep the side effect for now — it works, and refactoring to a pure approach risks new bugs. Document it as a known limitation.

---

## Why `defaultScrollAnchor(.bottom)` Is Key

The original code didn't have `defaultScrollAnchor(.bottom)` — it was added later. This is actually a **good** addition. On macOS 15+, `defaultScrollAnchor(.bottom)` tells SwiftUI to keep the scroll view pinned to the bottom as content grows. This is the "correct" way to handle auto-scroll in chat UIs.

The problem is that **explicit `scrollToBottom` calls fight the anchor**. Every time we call `proxy.scrollTo("bottom-anchor", anchor: .bottom)`, we're telling SwiftUI "scroll to this specific position." But `defaultScrollAnchor(.bottom)` is simultaneously saying "keep the bottom edge aligned with the bottom." When both fire at the same time (during streaming), SwiftUI's layout engine bounces between the two targets.

**The fix:** Use `defaultScrollAnchor(.bottom)` as the primary mechanism. Only call `scrollToBottom` explicitly for:
1. User-initiated actions (topic switch, Jump-to-Latest button)
2. Initial appearance (`onAppear`)
3. When `showStreamingBubble` first appears (because the anchor doesn't handle new view insertion)

Never call `scrollToBottom` during active streaming. Let the anchor do its job.

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| Removing `scheduleScrollCorrection` causes white space on topic switch | Low | `defaultScrollAnchor(.bottom)` handles this. `onAppear` + `scrollToBottom` handles initial load. |
| Removing `contentFillsContainer` causes short content to float | Low | `defaultScrollAnchor(.bottom)` pins short content to bottom on macOS 15+. |
| 4px anchor still not enough for LazyVStack | Low | 4px is 4× the original 1px. If still problematic, increase to 8px but no higher. |
| `showStreamingBubble` onChange causes rapid scrolls | Very Low | Diff guard in `SyncBridgeObserver` prevents `streamingContent` churn. |
| macOS 14 users see no auto-scroll | Very Low | macOS 14 market share for desktop is minimal. Acceptable to require 15+. |

---

## Implementation Order

1. **Change 2** (anchor height 8→4) — trivial, no risk
2. **Change 3** (remove `scheduleScrollCorrection`) — removes a feedback loop
3. **Change 4** (remove `contentFillsContainer` + simplify geometry) — reduces complexity
4. **Change 1** (simplify `scrollToBottom`) — core fix
5. **Change 5** (restore `showStreamingBubble` onChange) — ensures first chunk scrolls

Test after each change. If bounce persists after Change 1, the problem may be in `onScrollGeometryChangeCompat` itself — consider removing it entirely and going back to the original's simple `autoScroll` boolean (no Jump button, but no bounce either).

---

## Alternative: Nuclear Option

If the 5 changes above don't resolve the issue, the next step is:

1. Remove `onScrollGeometryChangeCompat` entirely
2. Remove `isAtBottom` state
3. Remove Jump-to-Latest button
4. Go back to `autoScroll: Bool` from the original
5. Only scroll triggers: `messages.count`, `isStreaming`, `showStreamingBubble`, `onAppear`

This loses the Jump button but eliminates all geometry-related feedback loops. The original `696b33a` code worked with this approach.

---

## Conclusion

The DIAGNOSIS document is correct. The current code is over-engineered. The minimal safe fix is **5 specific changes** that reduce complexity while preserving all user-facing features. The core principle: **let `defaultScrollAnchor(.bottom)` do the work, and stop fighting it with explicit scrolls during streaming.**

**Confidence: High** — the diff guards (D1, D2) are already in place, the feedback loop sources are identified, and the changes are surgical.
