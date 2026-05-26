# Q Review: Scroll Bounce Fix (BC5-SPEC-005)

**Reviewer:** Q  
**Date:** 2026-05-08  
**Status:** GREEN LIGHT

---

## 1. Root Cause Confirmation ✅

The spec's root cause analysis is **correct**. Here's the precise breakdown:

**Current `scrollToBottom()` produces 2 scrollTo calls every invocation:**
1. Immediate `withAnimation(.easeInOut(duration: 0.2))` via `DispatchQueue.main.async`
2. Unconditional 200ms fallback via `DispatchQueue.main.asyncAfter`

**During a streaming response, these onChange handlers fire:**

| Trigger | When | Calls scrollToBottom? | ScrollTo calls generated |
|---|---|---|---|
| `onChange(of: isStreaming)` | Streaming starts | Yes (unconditional) | 2 (animated + fallback) |
| `onChange(of: showStreamingBubble)` | Bubble first appears | Yes (unconditional) | 2 (animated + fallback) |
| `onChange(of: messages.count)` | Final message committed | Yes (if at bottom) | 2 (animated + fallback) |

That's **6 scrollTo calls minimum**, each animated, for a single streaming response. During streaming, the `StreamingBubble` is also growing in height, which causes SwiftUI to adjust scroll position naturally. The animated `scrollTo` calls fight with these layout-driven adjustments → visible bounce.

**Additional subtlety the spec doesn't mention:** The `onAppear`/`onDisappear` handlers on "bottom-anchor" track `isAtBottom`. During streaming, as content grows, this 120pt anchor's visibility can flicker, causing `isAtBottom` to oscillate → Jump button flicker. This isn't the bounce cause but is a related UX issue.

---

## 2. Evaluation of Proposed Fixes

### Fix 1: Remove animation from `scrollToBottom` ✅

**Correct.** The animated scroll is the primary bounce cause. During streaming, SwiftUI is already adjusting scroll position for layout changes. An explicit animated `scrollTo` on top of that creates conflicting animations.

**One concern with the spec's implementation:** Using `DispatchQueue.main.async` even for non-animated scrolls still introduces a one-run-loop delay. During rapid streaming updates, this delay means the scroll fires *after* SwiftUI has already adjusted, causing a visible jump. For non-animated scrolls during streaming, we should use *synchronous* scrolling — call `proxy.scrollTo` directly inside the `onChange` handler, not via dispatch.

### Fix 2: Deduplicate streaming scroll calls ✅ (with refinement)

**Correct approach, but the implementation can be simpler.** Rather than a separate `scrollToBottomIfNeeded()` function with timestamp tracking, I recommend:

1. Make `scrollToBottom(animated:)` handle everything
2. Use `@State private var lastScrollTime` for deduplication
3. Apply deduplication only when `isStreaming` is true (or `thinkingState != .idle`)

The 0.3s window is reasonable. During streaming, we want at most one scroll every 300ms. Outside streaming, no deduplication needed — user actions and topic switches should be immediate.

### Fix 3: Remove 200ms fallback during streaming ✅

**Correct.** The fallback exists for LazyVStack layout timing on topic switch, where items haven't rendered yet. During streaming, content is already rendered — the bubble grows incrementally. The fallback just adds an extra scroll that's both unnecessary and contributes to bouncing.

---

## 3. Implementation Plan

### Change 1: Rewrite `scrollToBottom` with `animated` parameter

Replace the current function entirely:

```swift
@State private var lastScrollTime: Date = .distantPast

private func scrollToBottom(animated: Bool = false) {
    guard let proxy = scrollProxy else { return }
    
    // During streaming, deduplicate: skip if scrolled recently
    if isStreaming || thinkingState != .idle {
        let now = Date()
        guard now.timeIntervalSince(lastScrollTime) > 0.3 else { return }
        lastScrollTime = now
    }
    
    if animated {
        DispatchQueue.main.async { [proxy] in
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
        // Fallback for LazyVStack layout timing on topic switch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [proxy] in
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    } else {
        // Synchronous, no animation, no fallback — immediate scroll
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
}
```

**Key differences from current code:**
- Non-animated scrolls are **synchronous** — no `DispatchQueue.main.async` wrapper. This prevents the one-run-loop delay that causes jumps during streaming.
- Fallback only fires when `animated: true`.
- Deduplication built in, scoped to streaming/thinking state only.

### Change 2: Update onChange handlers

```swift
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(anchorId, anchor: .top)
        }
        anchorMessageId = nil
    } else if isAtBottom || isUserMessage || isStreaming {
        scrollToBottom(animated: false)
    }
}
.onChange(of: isStreaming) { _, isNowStreaming in
    if isNowStreaming {
        scrollToBottom(animated: false)
    }
}
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing {
        scrollToBottom(animated: false)
    }
}
.onChange(of: topicId) { _, newId in
    if newId != nil {
        isAtBottom = true
        scrollToBottom(animated: true)  // Animated only on topic switch
    }
}
.onAppear {
    scrollProxy = proxy
    scrollToBottom(animated: true)  // Animated on initial load
}
```

### Change 3: Update Jump button action

```swift
Button(action: {
    scrollToBottom(animated: true)  // User explicitly tapped — animate
    isAtBottom = true
}) { ... }
```

### Change 4: Reset deduplication timer on topic switch

The `topicId` onChange should reset `lastScrollTime` so the topic-switch scroll isn't blocked:

```swift
.onChange(of: topicId) { _, newId in
    if newId != nil {
        isAtBottom = true
        lastScrollTime = .distantPast  // Reset dedup so next scroll is immediate
        scrollToBottom(animated: true)
    }
}
```

---

## 4. Risks & Edge Cases

| Risk | Mitigation |
|---|---|
| Synchronous `scrollTo` might fire before layout completes on cold start | `onAppear` uses `animated: true` which includes the 200ms fallback. Topic switch also animated. Only streaming updates are synchronous. |
| Deduplication window too long (misses a scroll) | 0.3s is conservative. The streaming bubble grows continuously; a missed scroll just means the next one in ≤0.3s catches up. No visible issue. |
| `isAtBottom` flickering during streaming causes Jump button flash | Not addressed in this fix. Recommend a follow-up: debounce `isAtBottom` changes during streaming (e.g., require `!isAtBottom` for ≥500ms before showing the button). Out of scope here. |
| `anchorMessageId` scroll uses `withAnimation` but calls `scrollTo` directly (not `scrollToBottom`) | This is fine — it's for "load earlier messages" anchor positioning, not bottom-scrolling. Leave as-is. |
| What if `scrollProxy` is nil on first `onChange`? | Current code has the same issue. `scrollProxy` is set in `onAppear`. If `onChange` fires before `onAppear`, the guard returns. No regression. |

---

## 5. Should `scrollToBottom` Ever Be Animated?

**Yes, but only in two cases:**

1. **Topic switch** — User switches conversation. Animated scroll gives a smooth "arriving" feel. The 200ms fallback ensures LazyVStack has rendered.
2. **Jump button tap** — User explicitly taps "jump to latest." Animated scroll feels intentional and responsive.

**Never during streaming.** During streaming, SwiftUI's own layout animation handles the visual. Adding `withAnimation` on top creates the bounce. The content is already visible and growing — an animated `scrollTo` is redundant and harmful.

---

## Verdict: 🟢 GREEN LIGHT

The spec correctly identifies the root cause. The proposed fixes are sound with minor refinements needed (synchronous non-animated scrolls, deduplication scoped to streaming state, reset timer on topic switch). Implementation is straightforward — 4 changes to `MessageCanvas.swift`, no new files, no architectural changes.

**Estimated diff:** ~40 lines changed. Low risk, high impact on UX.