# Consensus: Scroll Bounce & White Space

**Date:** 2026-05-10  
**Reconciling:** Q review, Kieran review, Bee evaluation  

## Disagreements Resolved

### 1. Is `asyncAfter` the primary cause of streaming bounce?

**Evaluation says:** Yes, the `asyncAfter(0.15)` re-scroll is the biggest contributor.  
**Q says:** Yes, and it bypasses the 0.3s dedup guard.  
**Kieran says:** No — `asyncAfter` is inside the `if animated` branch. During streaming, all calls use `animated: false`, so `asyncAfter` never fires.

**Resolution: Kieran is correct.** The code is:
```swift
if animated {
    withAnimation { proxy.scrollTo(...) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        proxy.scrollTo(...)
    }
} else {
    proxy.scrollTo(...)
}
```
All streaming-era `onChange` handlers call `scrollToBottom(animated: false)`. The `asyncAfter` only fires for topic switches and "Jump to latest" clicks. It contributes to bounce on those transitions, but **not during streaming**.

**Action:** Still remove `asyncAfter`. It causes visible double-scroll on animated transitions. But don't expect it to fix streaming bounce.

### 2. What IS the primary cause of streaming bounce?

**Evaluation says:** Reactive `scrollTo` calls + `asyncAfter` + LazyVStack layout.  
**Q adds:** `defaultScrollAnchor(.bottom)` doesn't re-anchor on content *growth*, only content *addition*.  
**Kieran adds:** `.scrollBounceBehavior(.basedOnSize)` is a missing factor — it allows bounce when content fits within the viewport, which happens early in streaming.

**Resolution: Three factors combine:**
1. `.scrollBounceBehavior(.basedOnSize)` — allows elastic bounce when content is shorter than the viewport
2. SwiftUI's scroll position doesn't actively track the bottom edge of growing content on macOS
3. `onChange(of: messages.count)` at stream end causes a scroll jump from streaming bubble to committed message

### 3. Should we remove the `bottom-anchor` spacer?

**Evaluation says:** Yes, replace with `scrollPosition(id:)`.  
**Q says:** Keep it but increase height to 50pt.  
**Kieran says:** Keep it as-is. Change scroll target instead.

**Resolution: Keep it.** Both reviewers agree: removing the spacer breaks `isAtBottom` detection (the "Jump to Latest" button). The white space is fixed by changing the scroll *target* to content IDs, not by removing the spacer. Keep `bottom-anchor` as a last-resort fallback for empty conversations.

### 4. Should we add `onChange(of: streamingContent)` for continuous scroll?

**Q recommends:** Throttled `onChange(of: streamingContent)` scrolling to bottom during streaming (~100ms).  
**Kieran doesn't recommend:** Prefers `.scrollBounceBehavior(.never)` during streaming.

**Resolution: Don't add `onChange(of: streamingContent)`.** Adding another reactive scroll handler is what caused the bounce in the first place. The 50ms poll means content changes every ~50ms — even throttled to 100ms, that's 10 scroll calls per second. Instead, let `defaultScrollAnchor(.bottom)` handle content growth, and suppress bounce with `.scrollBounceBehavior(.never)` during streaming. If `defaultScrollAnchor` proves insufficient on macOS, we can add a throttled scroll later as Fix D2.

---

## Agreed Fix Set

### Fix D: Scroll Bounce Elimination

**Changes in `MessageCanvas.swift`:**

1. **Remove `onChange(of: showStreamingBubble)`** — fires once on first content, unnecessary scroll trigger
2. **Remove `asyncAfter(0.15)` re-scroll** — causes visible double-scroll on animated transitions, not needed
3. **Change `scrollToBottom()` target logic** — during streaming, target `"streaming-bubble"`; during thinking, target `"thinking-bee"`; otherwise target `messages.last?.id ?? "bottom-anchor"`
4. **Add `.scrollBounceBehavior(.never)` during streaming** — suppresses elastic bounce when content is shorter than viewport

### Fix E: White Space Elimination

**Changes in `MessageCanvas.swift`:**

1. **Same as Fix D item 3** — never target `"bottom-anchor"` when there's visible content to scroll to. The white space comes from scrolling to the 2px spacer instead of the streaming bubble.
2. **Keep `bottom-anchor` spacer** — needed for `isAtBottom` detection and empty-conversation fallback

Fix E is effectively a subset of Fix D. No separate changes needed.

### Fix F: StreamingBubble Height Stability — DEFERRED

Both reviewers agree: cosmetic, defer to P2. Fixes D+E should eliminate visible bounce.

---

## Implementation Spec: Fix D

**File:** `MessageCanvas.swift`

### Change 1: Scroll target logic

Replace the current `scrollToBottom()` method's target selection:

```swift
// Before:
let targetId = messages.last?.id ?? "bottom-anchor"

// After:
let targetId: String
if isStreaming {
    targetId = "streaming-bubble"
} else if thinkingState == .thinking {
    targetId = "thinking-bee"
} else {
    targetId = messages.last?.id ?? "bottom-anchor"
}
```

### Change 2: Remove `onChange(of: showStreamingBubble)`

Delete the entire `onChange` handler:

```swift
// DELETE:
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing {
        scrollToBottom(animated: false)
    }
}
```

### Change 3: Remove `asyncAfter` re-scroll

In `scrollToBottom()`, remove the `asyncAfter` call:

```swift
// Before:
if animated {
    withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo(targetId, anchor: .bottom)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        proxy.scrollTo(targetId, anchor: .bottom)
    }
} else {
    proxy.scrollTo(targetId, anchor: .bottom)
}

// After:
if animated {
    withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo(targetId, anchor: .bottom)
    }
} else {
    proxy.scrollTo(targetId, anchor: .bottom)
}
```

### Change 4: Suppress bounce during streaming

Add a conditional modifier to the `ScrollView`:

```swift
// After .defaultScrollAnchor(.bottom):
.scrollBounceBehavior(isStreaming || thinkingState != .idle ? .never : .basedOnSize, axes: .vertical)
```

This replaces the existing `.scrollBounceBehavior(.basedOnSize, axes: .vertical)`.

---

## Testing Checklist

- [ ] Stream a long message — no bounce/jitter during streaming
- [ ] Stream a short message — no white space at bottom
- [ ] Send a message while assistant is mid-stream — auto-scrolls correctly
- [ ] Scroll up during streaming — stops auto-scrolling (user reading history)
- [ ] Scroll back down during streaming — "Jump to latest" button works
- [ ] Thinking → Streaming transition — no bounce during state change
- [ ] Streaming completes — view settles at bottom, no white space
- [ ] Topic switch while streaming — scrolls to bottom of new topic
- [ ] Empty conversation — no crash, no white space
- [ ] Long conversation (>100 messages) — scroll performance acceptable
- [ ] Streaming bubble flicker (brief empty content) — no scroll jump
- [ ] Window resize during streaming — scroll position stable
- [ ] Multiple rapid topic switches — no confusion
- [ ] "Jump to latest" button appears when scrolled up, disappears at bottom
- [ ] Animated scroll on topic switch — no visible double-scroll (asyncAfter removed)

---

## P2 / Deferred Items

- Fix D2: If `defaultScrollAnchor(.bottom)` proves insufficient for streaming content growth on macOS, add throttled `onChange(of: streamingContent)` handler
- Fix F: StreamingBubble height caching / max-height stabilization
- Migrate `isAtBottom` detection from spacer `onAppear`/`onDisappear` to `scrollPosition(id:)` binding
- 6 missing test cases from Kieran (interruption mid-stream, rapid topic switches, etc.)