# Kieran Review: Scroll Bounce & White Space Evaluation

**Date:** 2026-05-10  
**Reviewer:** Kieran (Independent Code Reviewer)  
**Reviewing:** `EVALUATION-scroll-bounce-2026-05-10.md`  
**Verdict:** Root cause analysis is **mostly sound** but misses one critical contributor. Fixes D and E are **directionally correct but over-engineered** — simpler solutions exist. Fix F is correctly deferred.

---

## 1. Root Cause Analysis — Challenge

### What the evaluation gets right

- **The `asyncAfter(0.15)` re-scroll IS a major bounce contributor.** Double-scrolling 150ms apart during a continuous content stream is visible and jarring. This is the single highest-signal finding in the evaluation.
- **The `bottom-anchor` spacer causing white space is correct.** When `messages.last` is a user message during streaming, the fallback to `"bottom-anchor"` scrolls a 2px clear spacer into view, creating the empty gap.
- **The 0.3s deduplication gap is real.** State changes (`isStreaming`, `showStreamingBubble`) can fire within the dedup window, and the `asyncAfter` adds a second scroll outside the guard entirely.
- **LazyVStack async layout fighting scroll position is the right mechanism.** SwiftUI's lazy rendering means the scroll target may not have its final size when `scrollTo` fires.

### What the evaluation misses

**Critical miss: `scrollToBottom()` is called with `animated: false` during streaming, but the `asyncAfter` re-scroll is ALWAYS executed regardless of the `animated` flag.**

Look at the code:

```swift
private func scrollToBottom(animated: Bool = false) {
    // ...dedup guard...
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
}
```

The `asyncAfter` is inside the `if animated` branch. All three streaming-era `onChange` handlers call `scrollToBottom(animated: false)`. So **the `asyncAfter` is NOT firing during streaming** — it only fires for animated scrolls (topic switch, "Jump to latest" button, initial `onAppear`).

This means the evaluation's claim that "the `asyncAfter(0.15)` re-scroll adds a second scroll 150ms after the first" during streaming is **incorrect**. The bounce during streaming comes from a different source.

**The actual primary cause during streaming:**

The `onChange(of: messages.count)` handler fires when the assistant message is committed to the `messages` array (when streaming completes and the message is saved). At that moment:
1. `messages.count` changes → triggers `scrollToBottom(animated: false)`
2. But the `showStreamingBubble` condition may still be true (content hasn't synced yet)
3. So both the streaming bubble AND the newly-committed message exist in the LazyVStack
4. The scroll target is `messages.last?.id` (the committed message), not the streaming bubble
5. This creates a jump from the streaming bubble to the committed message

**Secondary cause during streaming:** The `showStreamingBubble` computed property. Every 50ms when `streamingContent` changes, SwiftUI re-evaluates the body. If `showStreamingBubble` transitions from `false` → `true` (first content arrival), the `onChange(of: showStreamingBubble)` fires and calls `scrollToBottom(animated: false)`. But after that, content growth doesn't trigger any scroll handler — the bounce comes purely from SwiftUI's `defaultScrollAnchor(.bottom)` trying to keep the bottom visible as the LazyVStack content height changes.

**Is `ThinkingBeeIndicator` bounce animation involved?** The evaluation correctly concludes it's not. The 2pt vertical translation is visual-only (`.offset`) and doesn't affect layout bounds.

**Missing factor: `.scrollBounceBehavior(.basedOnSize, axes: .vertical)`.** This modifier tells SwiftUI to allow bounce when the content fits within the viewport. During streaming, if the content is still short, this allows the scroll view to bounce past its content edges. Combined with `defaultScrollAnchor(.bottom)`, this creates the visible bounce — the scroll view bounces at the bottom edge while content is still being added. This is a macOS-native behavior that may be the primary contributor.

---

## 2. Challenge Each Proposed Fix

### Fix D: Eliminate Scroll Bounce During Streaming

**Proposed:** Remove `onChange(of: showStreamingBubble)`, replace `onChange(of: isStreaming)` with a pinned mode, remove `asyncAfter`, rely on `defaultScrollAnchor(.bottom)`.

**Assessment: Over-engineered. Simpler path exists.**

- **Removing `onChange(of: showStreamingBubble)` — SAFE and CORRECT.** This handler only fires once when the streaming bubble first appears. It doesn't contribute to ongoing bounce. Removing it eliminates one unnecessary scroll call. No risk.

- **Replacing `onChange(of: isStreaming)` — NEEDS REFINEMENT.** The current handler calls `scrollToBottom(animated: false)` when streaming starts. This is actually useful — it ensures the view is at the bottom before content starts arriving. The issue isn't this handler itself, it's that it scrolls to `messages.last?.id` (the user's message) rather than the streaming bubble. A simpler fix: change the scroll target during streaming to `"streaming-bubble"` instead of removing the handler entirely.

- **Removing `asyncAfter` — SAFE but LOW IMPACT for streaming.** As established, the `asyncAfter` only fires for animated scrolls. It contributes to bounce on topic switches and "Jump to latest" clicks, but NOT during streaming. Removing it is still a good idea (eliminates a visible double-scroll in those cases), but it won't fix the streaming bounce.

- **Relying solely on `defaultScrollAnchor(.bottom)` — RISKY.** This modifier tells SwiftUI to *prefer* the bottom, but it doesn't *anchor* to it. When content height changes, SwiftUI will try to keep the bottom visible, but it will fight with `.scrollBounceBehavior(.basedOnSize)`. On macOS, this can still produce visible bounce. The evaluation's risk assessment correctly flags this as "Medium" likelihood.

**Simpler alternative for Fix D:**

1. Remove `onChange(of: showStreamingBubble)` (safe, low effort)
2. Change `scrollToBottom()` target during streaming to `"streaming-bubble"` instead of `messages.last?.id`
3. Remove the `asyncAfter` (clean up, even if low impact for streaming)
4. Consider changing `.scrollBounceBehavior(.basedOnSize)` to `.scrollBounceBehavior(.never)` during streaming only — this is a single-line conditional modifier

This achieves the same goal with ~10 lines of changes instead of rewriting the scroll architecture.

### Fix E: Remove White Space at Bottom

**Proposed:** Replace `bottom-anchor` spacer with `scrollPosition(id:)` binding, change scroll target to streaming bubble during streaming.

**Assessment: Directionally correct but the spacer removal is more complex than stated.**

- **Changing scroll target to `"streaming-bubble"` during streaming — SAFE and HIGH IMPACT.** This directly fixes the white space issue. When streaming, `messages.last` is the user's message, so the scroll falls back to `"bottom-anchor"`. Targeting `"streaming-bubble"` instead means the scroll position is always on visible content.

- **Removing the `bottom-anchor` spacer entirely — RISKY.** The spacer serves two purposes:
  1. Scroll target fallback (fixable by targeting streaming bubble / last message)
  2. `isAtBottom` detection via `onAppear`/`onDisappear`

  The `isAtBottom` state controls the "Jump to latest" button visibility. If you remove the spacer without replacing this detection, the button either always shows or never shows.

  The evaluation suggests `scrollPosition(id:)` or `onScrollGeometryChange` as replacements. Let me check viability:
  - `scrollPosition(id:)` — Available iOS 17 / macOS 14+. BeeChat targets macOS 14. **This is viable.**
  - `onScrollGeometryChange` — iOS 18 / macOS 15+. **Not viable** for the minimum target.

  Using `scrollPosition(id:)` with a binding is the cleanest path:
  ```swift
  @State private var scrollPosition: String?
  // ...
  ScrollView { ... }
      .scrollPosition(id: $scrollPosition)
  ```
  Then `isAtBottom` can be derived from whether `scrollPosition == "streaming-bubble"` or `scrollPosition == messages.last?.id`.

- **But here's the catch:** `scrollPosition(id:)` tracks which *element* is at the scroll position, not whether the user is at the bottom. You'd need to set the ID on the last element and check if it matches. This is roughly equivalent complexity to the current spacer approach, just with a different mechanism.

**Simpler alternative for Fix E:**

Don't remove the spacer. Just change the scroll target:
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

This eliminates the white space (scrolling to visible content, not the invisible spacer) while keeping the `isAtBottom` detection intact. The spacer stays as a fallback for empty conversations.

### Fix F: StreamingBubble Layout Stability

**Proposed:** Cache max height, or use `TextEditor`, or defer.

**Assessment: Correctly deferred.** The evaluation is right that this is cosmetic. Fixes D and E address the scroll mechanics; the content height fluctuation is secondary. The `fixedSize(horizontal: false, vertical: true)` on `StreamingBubble` is standard SwiftUI text layout — fighting it with height caching adds complexity for marginal visual gain. Defer to P2.

---

## 3. Specific Safety Evaluations

### Is removing `asyncAfter` safe?

**Yes, but with caveats.** The `asyncAfter` was added to handle LazyVStack rendering delays — the idea being that the first `scrollTo` fires before the new content has been laid out, so a second scroll 150ms later catches up. In practice:

- For **non-streaming animated scrolls** (topic switch, Jump to latest), the `asyncAfter` creates a visible double-scroll. Removing it means the animated scroll might land slightly short if the LazyVStack hasn't finished rendering. However, `defaultScrollAnchor(.bottom)` handles this natively for new content. The risk is low for typical message counts.
- For **very long conversations** (100+ messages), the LazyVStack rendering delay could be longer than 150ms, making the `asyncAfter` less effective anyway. In this case, removing it has no negative impact.
- **Edge case:** If a user rapidly sends multiple messages, the animated scroll from "Jump to latest" might not reach the very last message. This is cosmetic and self-correcting on the next scroll trigger.

**Recommendation:** Remove it. The visible double-scroll is worse than a 1-2 pixel shortfall that self-corrects.

### Is removing the `bottom-anchor` spacer safe?

**No, not without replacing `isAtBottom` detection.** The spacer's `onAppear`/`onDisappear` is the sole mechanism for tracking whether the user is scrolled to the bottom. This controls:
1. "Jump to latest" button visibility
2. The `onChange(of: messages.count)` logic (only auto-scrolls if `isAtBottom` or user message or streaming)

If you remove the spacer without replacement, the "Jump to latest" button breaks and auto-scroll decisions become unreliable.

**Recommendation:** Keep the spacer for now. The white space issue is better fixed by changing the scroll *target*, not removing the spacer. If you want to modernize later, migrate to `scrollPosition(id:)` as a separate change.

### What if `defaultScrollAnchor(.bottom)` doesn't work on all macOS versions?

The project targets macOS 14 (Sonoma). `defaultScrollAnchor(_:)` was introduced in iOS 17 / macOS 14. **It is available on the minimum target.** No fallback needed.

However, `defaultScrollAnchor` behavior differs between platforms:
- On **iOS**, it actively anchors the scroll position to the specified edge when content changes.
- On **macOS**, it's more of a preference — SwiftUI tries to keep that edge visible but doesn't guarantee it, especially with `.scrollBounceBehavior(.basedOnSize)` active.

This means relying solely on `defaultScrollAnchor(.bottom)` on macOS may not be sufficient to prevent all bounce. The evaluation's risk assessment correctly flags this.

**Recommendation:** Keep explicit `scrollTo` calls for key transitions (streaming start, message commit, topic switch). Use `defaultScrollAnchor(.bottom)` as a safety net, not the primary mechanism.

---

## 4. Edge Cases

### Empty conversation
- Current: `messages.last?.id` is nil → falls back to `"bottom-anchor"`. The spacer is the only element, so scroll lands on it. No white space issue (nothing to scroll past).
- After Fix E (target streaming bubble): If streaming starts on an empty conversation, `"streaming-bubble"` exists and is the scroll target. No issue.
- **Risk:** If `showStreamingBubble` is false and there are no messages, `scrollToBottom` targets `"bottom-anchor"` — the only element. This is fine.
- **Verdict:** No new edge case introduced.

### Rapid topic switching
- Current: `pendingTopicScroll` flag defers scroll until messages render. `onChange(of: topicId)` resets `isAtBottom = true` and `lastScrollTime = .distantPast`.
- After removing `onChange(of: showStreamingBubble)`: No impact — topic switch uses `onChange(of: messages.count)` with `pendingTopicScroll`.
- **Risk:** If a topic switch happens while the previous topic was streaming, the old streaming bubble might briefly appear in the new topic's view if state hasn't reset. This is a state management issue in `SyncBridgeObserver`, not in `MessageCanvas`.
- **Verdict:** No new risk from the proposed fixes. Existing `pendingTopicScroll` mechanism handles this.

### Very long messages (1000+ words)
- Current: `StreamingBubble` grows continuously. Every 50ms the content changes, triggering SwiftUI re-render. The scroll view content height increases. `defaultScrollAnchor(.bottom)` tries to keep bottom visible.
- After fixes: Same behavior, but without the `asyncAfter` double-scroll. The bounce should be reduced.
- **Risk:** On older Macs (M1 or Intel), the 50ms poll + SwiftUI re-render may cause frame drops, making the scroll appear jittery even without bounce. This is a performance issue, not a scroll logic issue.
- **Verdict:** No new risk. Performance on older hardware is a separate concern.

### Streaming starting immediately after sending
- Current: User sends message → `messages.count` increases → `scrollToBottom(animated: false)` fires → `isStreaming` becomes true → `scrollToBottom(animated: false)` fires again → `showStreamingBubble` becomes true → `scrollToBottom(animated: false)` fires a third time.
- The 0.3s deduplication guard prevents all but the first call. So in practice, only one scroll fires.
- After removing `onChange(of: showStreamingBubble)`: One fewer scroll trigger. The dedup guard still prevents the others.
- **Verdict:** No new risk. Actually slightly better (fewer scroll calls).

---

## 5. Testing Checklist — Missing Cases

The evaluation's testing checklist is solid but missing:

- [ ] **Send message while assistant is mid-stream** — User interrupts by sending a message. Does the scroll jump to the user message correctly? Does streaming resume below it?
- [ ] **Streaming bubble flicker** — If `streamingContent` is briefly empty (network hiccup), `showStreamingBubble` flips to false, then back to true. Does this cause a scroll jump?
- [ ] **Window resize during streaming** — Resizing the window changes `measuredWidth`, which affects bubble width via `BubbleWidthModifier`. This triggers re-layout. Does the scroll position stay stable?
- [ ] **Dark mode toggle during streaming** — Theme change triggers full re-render. Does the scroll position survive?
- [ ] **Multiple rapid topic switches during streaming** — Switch A→B→C→A while A is streaming. Does the `pendingTopicScroll` flag get confused?
- [ ] **`isAtBottom` button visibility** — Scroll up during streaming, verify "Jump to latest" appears. Scroll back down, verify it disappears.

---

## Summary

| Area | Evaluation | Kieran's Assessment |
|---|---|---|
| Root cause — `asyncAfter` | Primary cause of streaming bounce | **Incorrect** — only fires for animated scrolls, not during streaming |
| Root cause — `bottom-anchor` spacer | Primary cause of white space | **Correct** |
| Root cause — LazyVStack layout fight | Contributing factor | **Correct, but incomplete** — `.scrollBounceBehavior(.basedOnSize)` is the missing piece |
| Fix D — remove `onChange(showStreamingBubble)` | Good | **Agree** — safe, low risk |
| Fix D — remove `asyncAfter` | Good | **Agree** — safe, but low impact for streaming |
| Fix D — rely on `defaultScrollAnchor` alone | Recommended | **Disagree** — macOS behavior is weaker than iOS; keep explicit scrolls |
| Fix E — change scroll target to streaming bubble | Good | **Agree** — highest-impact single change |
| Fix E — remove bottom-anchor spacer | Recommended | **Disagree** — breaks `isAtBottom` detection; keep spacer, change target instead |
| Fix F — height caching | Deferred to P2 | **Agree** — cosmetic, defer |
| macOS compatibility | Flagged as open question | **Resolved** — `defaultScrollAnchor` available on macOS 14+ |

### Recommended minimal fix set:

1. **Remove `onChange(of: showStreamingBubble)`** — eliminates unnecessary scroll trigger
2. **Change `scrollToBottom()` target during streaming to `"streaming-bubble"`** — eliminates white space
3. **Remove the `asyncAfter(0.15)` re-scroll** — eliminates visible double-scroll on animated scrolls
4. **Consider `.scrollBounceBehavior(.never)` during streaming** — single-line conditional modifier to reduce bounce

This achieves the same goals as the evaluation's proposed fixes with ~15 lines of changes instead of a scroll architecture rewrite.
