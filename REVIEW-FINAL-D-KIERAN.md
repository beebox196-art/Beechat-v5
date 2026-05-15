# Independent Review: Fix D (Scroll Bounce + White Space) — Final Spec

**Reviewer:** Kieran  
**Date:** 2026-05-10  
**Spec reviewed:** `CONSENSUS-scroll-bounce-2026-05-10.md`  
**Source reviewed:** `MessageCanvas.swift`

---

## Overall Verdict: **APPROVE WITH CHANGES**

The consensus spec is strong — the root cause analysis is correct, the fix set is appropriate, and removing `onChange(of: showStreamingBubble)` and `asyncAfter` are the right calls. However, I've found two concrete issues in the target logic and one edge case that need addressing before implementation.

---

## Detailed Findings

### 1. Will removing `onChange(of: showStreamingBubble)` cause regression?

**Partial risk — depends on `defaultScrollAnchor(.bottom)` behavior.**

Currently, `onChange(of: showStreamingBubble)` is the *only* explicit scroll trigger for the moment the streaming bubble first appears. After removal, we rely entirely on `defaultScrollAnchor(.bottom)` to auto-anchor when the `StreamingBubble` view enters the LazyVStack.

The consensus acknowledges this risk and defers a fallback (Fix D2) to P2. I agree with the deferral, but with one caveat: **if `defaultScrollAnchor(.bottom)` proves unreliable on macOS for new-view insertion (not just content growth), we need to re-add this handler immediately, not wait for P2.** The streaming UX hinges on the bubble being visible from its first token.

**Recommendation:** Accept the removal, but add an explicit test case: *"Streaming bubble first appears — scroll anchors to bottom without manual scroll call."* If this fails on macOS, reinstate `onChange(of: showStreamingBubble)` with the new target logic.

### 2. Is the conditional `.scrollBounceBehavior` correct?

**Yes, syntactically and semantically correct.**

`.scrollBounceBehavior` accepts a `ScrollBounceBehavior` enum value. The ternary expression:
```swift
.scrollBounceBehavior(isStreaming || thinkingState != .idle ? .never : .basedOnSize, axes: .vertical)
```
produces a concrete enum value at render time. This is valid SwiftUI.

**One concern:** `.scrollBounceBehavior` is not animatable. When it switches from `.never` (during streaming) back to `.basedOnSize` (after streaming ends), there could be a visual jump if the scroll position is near the edge. This is cosmetic and unlikely to be noticeable, but should be on the test checklist.

**Recommendation:** Add to test checklist: *"Streaming ends — no visible jump when bounce behavior switches back to `.basedOnSize`."*

### 3. Target logic — state transitions (MAIN ISSUE)

The proposed target logic:
```swift
let targetId: String
if isStreaming {
    targetId = "streaming-bubble"
} else if thinkingState == .thinking {
    targetId = "thinking-bee"
} else {
    targetId = messages.last?.id ?? "bottom-anchor"
}
```

**Problem identified:** When `isStreaming` is true but `streamingContent` is empty (the "pre-streaming" phase between thinking→streaming), the target is `"streaming-bubble"` — but `StreamingBubble` is only rendered when `showStreamingBubble` is true, which requires non-empty content. The target ID doesn't exist in the view hierarchy.

This creates a no-op scroll at a critical moment:

1. `thinkingState` changes from `.thinking` to `.streaming`, `isStreaming` becomes true
2. `onChange(of: isStreaming)` fires → `scrollToBottom()` → target `"streaming-bubble"` → **doesn't exist yet**
3. `thinking-bee` view has already disappeared
4. No visible indicator is on-screen (typing indicator is suppressed when `thinkingState == .streaming`)
5. Streaming content arrives → `StreamingBubble` renders → relies on `defaultScrollAnchor(.bottom)` to scroll

**This is the weakest link.** Steps 2-4 mean there's a brief window with no scroll target and no on-screen indicator, relying entirely on `defaultScrollAnchor` for recovery.

**Recommended fix — adjust target logic:**

```swift
let targetId: String
if isStreaming && showStreamingBubble {
    targetId = "streaming-bubble"
} else if thinkingState == .thinking {
    targetId = "thinking-bee"
} else {
    targetId = messages.last?.id ?? "bottom-anchor"
}
```

Using `showStreamingBubble` (which already checks non-empty content) ensures we only target `"streaming-bubble"` when it's actually rendered. During the pre-streaming gap, we fall through to `messages.last?.id ?? "bottom-anchor"`, which always resolves to something valid.

### 4. `isStreaming` true + empty `streamingContent` (thinking state)

**This is the same issue as #3, viewed from a different angle.** The current rendering logic:

```swift
if thinkingState == .thinking {
    ThinkingBeeIndicator(...)     // visible
} else if isStreaming && streamingContent.isEmpty {
    if thinkingState != .streaming {
        TypingIndicator()         // visible for non-.streaming
    }
    // thinkingState == .streaming → nothing visible
} else if showStreamingBubble {
    StreamingBubble(...)          // visible
}
```

When `isStreaming == true`, `streamingContent.isEmpty`, and `thinkingState == .streaming`: **nothing is rendered.** No indicator, no bubble. The user sees a brief blank where the thinking indicator was. This is pre-existing behavior, not introduced by Fix D, but it means the scroll target must not point to a non-existent view.

**Recommendation:** Same fix as #3 — use `showStreamingBubble` in the target logic. The blank-state rendering gap is a separate UX issue (Fix F territory) but doesn't block this spec.

### 5. Race conditions between state changes and scroll calls

**Low risk, but worth noting.**

The 0.3s dedup guard in `scrollToBottom()` prevents rapid-fire calls. The potential race is:

- `onChange(of: isStreaming)` fires → scrolls to (currently invalid) `"streaming-bubble"` → no-op, but `lastScrollTime` is updated
- Within 0.3s, another scroll trigger fires (e.g., `onChange(of: messages.count)`) → suppressed by dedup
- After 0.3s, a legitimate trigger could scroll to the correct target

With the recommended target logic fix (using `showStreamingBubble`), this race is mitigated because the fallback target (`messages.last?.id ?? "bottom-anchor"`) always resolves. The 0.3s dedup window might suppress a legitimate scroll, but the next `onChange` or `defaultScrollAnchor` will recover.

**Recommendation:** Keep the 0.3s dedup as-is. If timing issues surface in testing, consider shortening to 0.15s for streaming state only.

---

## Summary of Required Changes Before Implementation

| # | Issue | Fix |
|---|---|---|
| 1 | Target `"streaming-bubble"` may not exist during pre-streaming phase | Use `showStreamingBubble` in the target condition: `if isStreaming && showStreamingBubble` |
| 2 | Test gap: `defaultScrollAnchor(.bottom)` may not handle streaming-bubble insertion on macOS | Add explicit test case; have Fix D2 ready as backup |
| 3 | Test gap: bounce behavior switch may cause visual jump | Add to test checklist |

## Items I Agree With (No Changes Needed)

- ✅ Remove `onChange(of: showStreamingBubble)` — correct, with the target logic fix above
- ✅ Remove `asyncAfter(0.15)` — Kieran was right that it doesn't fire during streaming, but it causes visible double-scroll on animated transitions; removing it is correct
- ✅ Keep `bottom-anchor` spacer — needed for `isAtBottom` detection
- ✅ `.scrollBounceBehavior(.never)` during streaming — correct approach
- ✅ Defer Fix F (height stability) to P2 — cosmetic, not blocking
- ✅ Testing checklist is comprehensive

---

**Verdict: APPROVE WITH CHANGES** — Apply the target logic fix (use `showStreamingBubble` instead of bare `isStreaming`), add the two test cases, and this is ready to implement.