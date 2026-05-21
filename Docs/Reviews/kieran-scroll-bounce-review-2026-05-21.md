# Kieran Adversarial Review: Scroll Bounce & White Space

**Date:** 2026-05-21  
**Reviewer:** Kieran  
**File under review:** `Sources/App/UI/Components/MessageCanvas.swift`  
**Reference docs:** `DIAGNOSIS-scroll-bounce-2026-05-10.md`, `DEBUG.md`, `SyncBridgeObserver.swift`

---

## Executive Summary

The current code is **still overcomplicated** and still exhibits the fundamental problem the DIAGNOSIS identified: **multiple competing scroll triggers that fight each other during streaming**. The DIAGNOSIS's "revert to simplicity with two changes" recommendation was correct, and the code has drifted further from it, not closer. The D1 diff guard in `SyncBridgeObserver` is working (good), but MessageCanvas has accumulated *more* scroll complexity, not less.

**Verdict: Revert-to-simplicity approach is still the right call, but needs refinement based on what's evolved since the DIAGNOSIS.**

---

## 1. Is the current code still overcomplicated?

**Yes. Significantly.**

The DIAGNOSIS recommended exactly two changes to the original simple code. The current file has **at least 6 distinct scroll-triggering mechanisms**:

| # | Trigger | Lines | Problem |
|---|---------|-------|---------|
| 1 | `onChange(of: messages.count)` | 140-155 | Multiple sub-actions: anchor scroll, topic scroll, short-content fallback, schedule correction |
| 2 | `onChange(of: containerHeight)` | 157-159 | Schedules another correction — fires when Composer resizes |
| 3 | `scheduleScrollCorrection` (method) | 247-258 | Async Task with 100ms delay + `isAtBottom` guard + scrollTo |
| 4 | `onChange(of: topicId)` | 166-173 | Sets `isAtBottom`, triggers scroll |
| 5 | `onAppear` | 175-177 | Triggers scroll |
| 6 | `contentFillsContainer` guard | 149-153 | Short-content forced scroll inside the messages.count handler |

Compare this to the DIAGNOSIS recommendation: **"One scroll trigger, not many. React to 'new content at bottom' once, not to multiple state changes."**

The `scheduleScrollCorrection` method alone is a compound problem — it's an async Task that reads `isAtBottom` (which may be stale by the time the 100ms delay elapses), conditionally fires `scrollToBottom`, and gets called from *two different* `onChange` handlers. During streaming, this creates a cascade:

```
messages.count changes → scheduleScrollCorrection (Task A queued)
containerHeight changes → scheduleScrollCorrection (Task A cancelled, Task B queued)
100ms later → Task B fires → scrollToBottom → layout change → geometry fires → isAtBottom flips → ?
```

This is exactly the kind of feedback loop the DIAGNOSIS warned against.

### What can be removed:

- **`scheduleScrollCorrection` entirely.** It's a band-aid for `defaultScrollAnchor(.bottom)` not being trusted. If we trust `defaultScrollAnchor(.bottom)`, this is dead code. If we don't trust it, we need to fix *why*, not add more triggers.
- **`onChange(of: containerHeight)`**. Composer height changes are layout events that `defaultScrollAnchor(.bottom)` should handle. If it doesn't, that's a different bug.
- **`contentFillsContainer` computed property + short-content fallback** in the messages.count handler. `defaultScrollAnchor(.bottom)` handles this natively on macOS 15+.
- **`contentHeight`, `containerHeight`, `scrollCorrectionTask` @State variables.** Dead if the above is removed.
- **`ScrollGeometryResult`, the transform closure complexity, and the hysteresis logic** in `onScrollGeometryChangeCompat`. This exists solely to track `isAtBottom` for the Jump button AND for the scroll correction guard. The Jump button needs `isAtBottom`; the scroll correction doesn't. If scroll correction is removed, the hysteresis can be simplified.

---

## 2. Does the current code still have the bugs identified in the DIAGNOSIS?

### Bug 1: Animation during streaming — ✅ FIXED

```swift
private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
    ...
    if animated {
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    } else {
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
}
```

And callers pass `animated: false` during streaming. **Good.** The DIAGNOSIS's Change #1 is implemented.

### Bug 2: Scroll target instability — ✅ FIXED (partially)

The code scrolls to `"bottom-anchor"` consistently. It does NOT scroll to `"streaming-bubble"`. **Good.** However, the anchor is 8px tall instead of the DIAGNOSIS-recommended 4px.

**Is 8px a problem?** It's visible white space below the last message. The DIAGNOSIS specifically said 4px — "enough for LazyVStack to render reliably, invisible to the user." 8px is double that and *is* visible. This is likely contributing to the white space Adam reports.

### Bug 3: Missing `onChange(of: showStreamingBubble)` — ⚠️ STILL MISSING

The DIAGNOSIS explicitly warned: *"Removing `onChange(of: showStreamingBubble)` removed a necessary scroll trigger. When the streaming bubble first appears (empty → has content), something needs to scroll to it."*

The current code does NOT have this handler. The argument would be that `defaultScrollAnchor(.bottom)` handles it — and for macOS 15+ that's probably true. But on macOS 14, the `onScrollGeometryChangeCompat` fallback does nothing (the DispatchQueue block is empty). **This is a latent bug on macOS 14.**

### Bug 4: `.scrollBounceBehavior(.automatic)` — ✅ NOT PRESENT

This bad change from "Fix D" is not in the current code. **Good.**

---

## 3. Is the revert-to-simplicity approach still the right call?

**Yes, with one adjustment.**

The DIAGNOSIS was right about the direction. But the current code has evolved features that need to be preserved:

- `isAtBottom` tracking (for the Jump-to-Latest button) — keep, but simplify
- `thinkingState` handling — keep (but the empty `onChange` handler should be removed)
- `canLoadEarlier` / "Load earlier messages" — keep
- Topic switch scroll handling — keep
- `showStreamingBubble` computed property — keep (it's needed for the streaming bubble display logic)

The revert should remove:
1. `scheduleScrollCorrection` and everything it touches
2. `onChange(of: containerHeight)`
3. `contentFillsContainer` and the short-content forced scroll
4. The `contentHeight`/`containerHeight`/`scrollCorrectionTask` @State variables
5. The `anchorMessageId` mechanism (used in the messages.count handler for "Load earlier" preservation — but this is a separate concern from scroll-to-bottom and can be handled differently)

And restore:
1. Simple `onChange(of: messages.count)` that just scrolls to bottom
2. `onChange(of: showStreamingBubble)` for initial streaming scroll (if macOS 14 support is needed)

---

## 4. NEW issues not in the original DIAGNOSIS

### 4.1: `showStreamingBubble` recomputes on every poll cycle

```swift
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
```

The D1 diff guard in `SyncBridgeObserver` stops *identical* content from triggering a SwiftUI invalidation. But this computed property still runs on every `messages` array change (from the DB observation). If `messages` changes but `streamingContent` doesn't, `showStreamingBubble` still recomputes. It's not expensive, but it means `MessageCanvas.body` re-evaluates and the LazyVStack gets another layout pass.

**Severity: Low.** Not the root cause of bounce, but contributes to layout churn.

### 4.2: The hysteresis in `onScrollGeometryChangeCompat` reads `isAtBottom` inside the transform closure

```swift
.onScrollGeometryChangeCompat(
    transform: { geo in
        ...
        if isAtBottom {       // <-- Reads @State in transform
            atBottom = distanceFromBottom < leaveThreshold
        } else {
            atBottom = distanceFromBottom < enterThreshold
        }
        return ScrollGeometryResult(isAtBottom: atBottom, ...)
    },
    action: { _, newValue in
        isAtBottom = newValue.isAtBottom  // <-- Writes @State in action
    }
)
```

The comment says *"Change #9: Transform closure is pure (no @State mutations)"*. But it **reads** `isAtBottom`, which means the transform's output depends on state that was set by the previous action call. This creates a dependency chain where the transform and action are coupled across invocations. During rapid layout changes (streaming), `isAtBottom` can flip-flop between the hysteresis thresholds, causing `scheduleScrollCorrection` to fire or not fire unpredictably.

**Severity: Medium.** This is a subtle feedback loop. The transform should be truly pure — compute `isAtBottom` from geometry alone, not from previous state.

### 4.3: `scrollToBottom` debounce (200ms) fights with `scheduleScrollCorrection` delay (100ms)

```swift
// In scrollToBottom:
if now.timeIntervalSince(lastScrollTime) < 0.2 {
    return  // Debounce: skip if called within 200ms
}

// In scheduleScrollCorrection:
try? await Task.sleep(for: .milliseconds(100))
scrollToBottom(proxy: proxy, animated: false)  // May be debounced away!
```

The correction task waits 100ms, then calls `scrollToBottom`. But `scrollToBottom` has a 200ms debounce. If a scroll happened within the last 200ms (very likely during streaming), the correction silently does nothing. This means `scheduleScrollCorrection` is mostly dead code — it schedules work that gets debounced away.

**Severity: Medium.** It's not causing harm (the debounce saves it), but it's wasted complexity that obscures the real scroll behavior.

### 4.4: `onChange(of: thinkingState)` is a no-op with a misleading comment

```swift
.onChange(of: thinkingState) { oldState, newState in
    BeeChatLogger.log("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
    // REMOVED: scrollToBottom on .thinking
    // defaultScrollAnchor(.bottom) handles staying at bottom.
}
```

This handler fires and logs but does nothing. It's harmless but confusing to readers. If `defaultScrollAnchor(.bottom)` handles it, why is the handler still here? Either remove it or put the scroll back.

### 4.5: `anchorMessageId` mechanism in messages.count handler

```swift
if let anchorId = anchorMessageId {
    withAnimation(.easeInOut(duration: 0.15)) {
        proxy.scrollTo(anchorId, anchor: .top)
    }
    anchorMessageId = nil
}
```

This preserves scroll position when "Load earlier messages" fires. It's legitimate functionality, but it's in the same `onChange(of: messages.count)` handler as the scroll-to-bottom logic. When a user loads earlier messages, `messages.count` changes, and this code scrolls to the anchor. But then the code *continues* to the `contentFillsContainer` check and `scheduleScrollCorrection`, which may also fire. These concerns are tangled.

**Severity: Low.** Works correctly but is structurally messy. Should be in its own `onChange`.

---

## 5. Recommended Changes

### Priority 1 — Fix the bounce (High confidence: 90%)

**Remove `scheduleScrollCorrection` entirely**, along with:
- `onChange(of: containerHeight)`
- `contentFillsContainer` computed property
- `contentHeight`, `containerHeight`, `scrollCorrectionTask` @State variables
- The short-content forced scroll in `onChange(of: messages.count)`

This eliminates the async feedback loop that causes the worst bounce. `defaultScrollAnchor(.bottom)` handles short-content and Composer-resize cases natively on macOS 15+.

### Priority 2 — Fix the white space (High confidence: 85%)

**Reduce bottom-anchor from 8px to 4px** as the DIAGNOSIS recommended:

```swift
Color.clear
    .frame(height: 4)
    .id("bottom-anchor")
```

The 8px is visibly too tall and directly creates the white space Adam reports.

### Priority 3 — Fix the hysteresis reading @State in transform (Moderate confidence: 70%)

The `isAtBottom` read inside the transform closure creates a cross-invocation dependency. Simplify to a single threshold:

```swift
transform: { geo in
    guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
        return ScrollGeometryResult(isAtBottom: true, contentHeight: geo.contentSize.height, containerHeight: geo.containerSize.height)
    }
    let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
    return ScrollGeometryResult(
        isAtBottom: distanceFromBottom < 80,  // Single threshold, no hysteresis needed for Jump button
        contentHeight: geo.contentSize.height,
        containerHeight: geo.containerSize.height
    )
}
```

The hysteresis (50/120px split) was designed for the scroll correction guard, which is being removed. A single 80px threshold is fine for the Jump button UX.

### Priority 4 — Clean up dead code (High confidence: 95%)

- Remove the empty `onChange(of: thinkingState)` handler (or keep just the log if useful for debugging)
- Remove the `ScrollGeometryResult` struct and simplify the transform to return a single `Bool` (only `isAtBottom` is needed after removing the geometry tracking)
- Simplify `onScrollGeometryChangeCompat` to return `Bool` directly

### Priority 5 — Add back `onChange(of: showStreamingBubble)` if macOS 14 support matters (Moderate confidence: 60%)

If the app supports macOS 14, the streaming bubble's initial appearance needs an explicit scroll trigger. On macOS 15+, `defaultScrollAnchor(.bottom)` handles this.

```swift
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing {
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```

**Confidence is lower** because I don't know the macOS version deployment target. If it's macOS 15+ only, skip this.

---

## 6. What the code should look like after changes (sketch)

```swift
// In body, inside ScrollView:
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(anchorId, anchor: .top)
        }
        anchorMessageId = nil
    } else if pendingTopicScroll {
        pendingTopicScroll = false
        scrollToBottom(proxy: proxy, animated: true)
    } else {
        scrollToBottom(proxy: proxy, animated: isStreaming ? false : false)
        // Note: always non-animated here because messages.count changes
        // during streaming (committed message). Animation is for
        // user-initiated actions only (topic switch, onAppear).
    }
}

// Optional: macOS 14 support
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing {
        scrollToBottom(proxy: proxy, animated: false)
    }
}

// Bottom anchor:
Color.clear
    .frame(height: 4)
    .id("bottom-anchor")

// scrollToBottom:
private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = false) {
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
```

Key simplifications:
- No `scheduleScrollCorrection`
- No `contentFillsContainer`
- No `onChange(of: containerHeight)`
- Bottom anchor is 4px
- `scrollToBottom` is always called but always non-animated for `messages.count` changes

---

## 7. Confidence Assessment

| Recommendation | Confidence | Rationale |
|---|---|---|
| Remove `scheduleScrollCorrection` and related machinery | 90% | It's a feedback loop that demonstrably fights with the debounce; `defaultScrollAnchor(.bottom)` handles the cases it was meant to cover |
| Reduce bottom-anchor from 8px to 4px | 85% | 8px is visibly too tall and directly creates the reported white space; 4px was the DIAGNOSIS recommendation with reasoning |
| Simplify hysteresis to single threshold | 70% | The hysteresis was designed for scroll correction guard; without that, it's unnecessary complexity. But the current hysteresis isn't harmful, just confusing |
| Remove empty `onChange(of: thinkingState)` | 95% | It does nothing. Dead code. |
| Add back `onChange(of: showStreamingBubble)` | 60% | Depends on macOS deployment target. Harmless if added, but may be unnecessary on macOS 15+ |

---

## 8. Why the previous fixes kept making things worse

The pattern is clear: each fix identified a *symptom* (bounce, white space, CPU hang) and added a *mechanism* to suppress it. But the mechanisms interacted:

1. Added debounce → masked the real problem (animation during streaming)
2. Added conditional scroll targets → created target instability
3. Added `scheduleScrollCorrection` → created async feedback loop
4. Added geometry tracking → created transform/action coupling
5. Added hysteresis → made the geometry tracking harder to reason about

Each mechanism was individually defensible. Together, they created a system where **the scroll behavior was determined by the interaction of 6+ independent triggers, each with their own timing, conditions, and side effects**. That's not fixable by adding a 7th mechanism.

The fix is removal, not addition.

---

*Review complete. Recommend Adam approve Priority 1 + 2 as the minimum viable fix. Priority 3-5 are cleanup that should follow.*
