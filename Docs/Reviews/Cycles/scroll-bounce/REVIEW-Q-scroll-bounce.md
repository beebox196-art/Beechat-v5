# Review: Scroll Bounce & White Space Evaluation

**Reviewer:** Q (Code Implementation Specialist)  
**Date:** 2026-05-10  
**Reviewing:** `EVALUATION-scroll-bounce-2026-05-10.md`  
**Status:** Approved with caveats  

---

## 1. Root Cause Analysis — CONFIRMED with one correction

### Scroll Bounce — Root cause is correct

The evaluation correctly identifies that the bounce comes from reactive `scrollTo` calls fighting SwiftUI's async layout. I verified this by tracing the actual code paths:

**Three scroll triggers fire during streaming:**
- `onChange(of: messages.count)` — fires when assistant message is committed at stream end
- `onChange(of: isStreaming)` — fires once when streaming begins
- `onChange(of: showStreamingBubble)` — fires once when streaming bubble first appears

**The asyncAfter re-scroll is the biggest problem.** The evaluation is right, but I want to emphasise *why* it's worse than the evaluation states:

```swift
if animated {
    withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo(targetId, anchor: .bottom)
    }
    // This bypasses the 0.3s dedup guard entirely — it's a raw proxy.scrollTo
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        proxy.scrollTo(targetId, anchor: .bottom)
    }
}
```

The `asyncAfter` call goes directly to `proxy.scrollTo`, **bypassing the dedup guard** in `scrollToBottom()`. So even if the 0.3s guard prevents a second `scrollToBottom()` call, the asyncAfter re-scroll still fires. This means during topic switches or user message sends (which use `animated: true`), there's always a double-scroll: one at T+0, one at T+150ms. The second scroll can land after LazyVStack has partially re-laid out, causing visible bounce.

**Confidence: High.** This is a clear bug in the dedup logic — the asyncAfter should either respect the guard or be removed entirely.

### White Space — Root cause is correct

The evaluation correctly identifies that `messages.last?.id ?? "bottom-anchor"` falls back to the invisible spacer during streaming. I verified:

- During streaming, the assistant message is NOT in the `messages` array (it's rendered separately via `StreamingBubble`)
- `messages.last` is the user's message
- But `scrollTo("bottom-anchor", anchor: .bottom)` is called when the streaming bubble appears (via `onChange(of: showStreamingBubble)`)
- The spacer is `Color.clear.frame(height: 2)` — essentially nothing, but SwiftUI still scrolls to align its bottom edge with the viewport bottom
- This creates a gap between the last visible content and the viewport bottom

**Confidence: High.**

### ThinkingBee Factor — Mostly correct, minor correction

The evaluation says the ThinkingBee bounce animation (2pt offset) is "visual-only and shouldn't affect scroll." This is **mostly correct** but not entirely:

The `ThinkingBeeIndicator` has `.offset(y: bounceOffset)` with an animation. While the offset itself doesn't change the view's frame (offset is a visual transform, not layout), the **appearance/disappearance** of the ThinkingBee indicator DOES change the LazyVStack's content size. When `.thinking → .streaming` transitions:

1. `ThinkingBeeIndicator` (height ~60pt) disappears
2. `StreamingBubble` (initially very short, just "Bee" + cursor) appears
3. This is a net height *decrease* in the LazyVStack
4. The scroll position becomes invalid — it was scrolled to show the ThinkingBee, now that space is gone
5. `defaultScrollAnchor(.bottom)` tries to re-anchor, but the LazyVStack is mid-layout

This isn't the primary cause of bounce, but it's a contributing factor during the transition window. The evaluation underweights this.

**Confidence: Moderate.**

---

## 2. Proposed Fixes Evaluation

### Fix D: Eliminate Scroll Bounce During Streaming — SOUND, with implementation notes

| Recommendation | Assessment | Notes |
|---|---|---|
| Remove `onChange(of: showStreamingBubble)` | ✅ Correct | Fires once, not needed. The streaming bubble appears and stays — no need to scroll when it first shows. |
| Replace `onChange(of: isStreaming)` with pinned mode | ✅ Correct | One-shot scroll at stream start is fine, but keeping it pinned is better. |
| Remove `asyncAfter(0.15)` re-scroll | ✅✅ Essential | This is the single most impactful change. Remove it entirely. |
| Rely on `defaultScrollAnchor(.bottom)` | ⚠️ Partially correct | See caveat below. |
| Keep `onChange(of: messages.count)` for non-streaming | ✅ Correct | Needed for user messages and completed assistant messages. |

**Caveat on `defaultScrollAnchor(.bottom)`:** This modifier tells SwiftUI to prefer the bottom anchor when the scroll view first appears or when content is *added*. However, it does NOT actively scroll when existing content *grows*. During streaming, the `StreamingBubble` grows as content is appended. `defaultScrollAnchor(.bottom)` alone may not keep the viewport pinned to the growing content.

**What actually happens on macOS 14:** `defaultScrollAnchor(.bottom)` keeps the scroll position anchored when new items are inserted into the LazyVStack. But when an existing item's height changes (text grows), the scroll position stays fixed relative to the top, not the bottom. So during streaming, the viewport will slowly drift upward as the bubble grows.

**Recommendation:** Fix D's approach is sound, but `defaultScrollAnchor(.bottom)` alone is insufficient during streaming. You need one of:
1. **Option A (preferred):** Keep a lightweight `onChange(of: streamingContent)` that does a non-animated `scrollTo("streaming-bubble")` with a throttle (e.g., 100ms). This is a *continuous* scroll during streaming, not reactive to state changes.
2. **Option B:** Use `scrollPosition(id:)` binding to track scroll position and programmatically keep it at the bottom.

Option A is simpler and more predictable. The key difference from the current code: throttle to ~100ms, use non-animated scrollTo, target the streaming bubble directly (not bottom-anchor), and don't use asyncAfter.

### Fix E: Remove White Space at Bottom — SOUND

| Recommendation | Assessment | Notes |
|---|---|---|
| Move `isAtBottom` detection to `scrollPosition` | ✅ Correct | The current `onAppear`/`onDisappear` on a 2pt spacer is fragile. It fires based on whether the spacer is visible, which is essentially always in a scroll view that's scrolled to the bottom. |
| Change scroll target from `"bottom-anchor"` to content IDs | ✅ Correct | Target `"streaming-bubble"` when streaming, `"thinking-bee"` when thinking, `messages.last?.id` otherwise. |

**Implementation detail for `isAtBottom` detection:**

The current approach using `onAppear`/`onDisappear` on the bottom-anchor spacer actually works *okay* for the "Jump to Latest" button visibility, but it's fragile. The spacer is always at the bottom of the LazyVStack. When the user scrolls up, the spacer disappears → `isAtBottom = false`. When they scroll back down, the spacer appears → `isAtBottom = true`.

The problem is that during streaming, the LazyVStack content is growing, which can cause the spacer to briefly disappear/reappear as layout recalculates, causing `isAtBottom` to flicker. This would make the "Jump to Latest" button flash on/off during streaming.

**Recommended approach:** Use `scrollPosition(id:)` with a binding. Available macOS 14+:

```swift
@State private var scrollPosition: String?

ScrollView {
    // ... content with .id() modifiers
}
.scrollPosition(id: $scrollPosition)
```

Then `isAtBottom` can be derived: `scrollPosition == "streaming-bubble" || scrollPosition == "bottom-anchor" || scrollPosition == messages.last?.id`.

However, `scrollPosition` tracks which ID is at the scroll anchor point (controlled by `defaultScrollAnchor`), not which IDs are visible. For `isAtBottom` detection, you'd need to check if the scroll position is near the bottom. This is more nuanced than the evaluation suggests.

**Alternative (simpler):** Keep the bottom-anchor spacer for `isAtBottom` detection but add a small buffer. Instead of a 2pt spacer, use a 50pt spacer. This gives more room for the `onAppear`/`onDisappear` to fire reliably during layout changes. The spacer is invisible anyway.

**My recommendation:** For the scope of this fix, keep the bottom-anchor spacer for `isAtBottom` detection (it works well enough) but:
1. Increase its height to 50pt for more reliable onAppear/onDisappear firing
2. **Never use it as a scroll target** — this is the critical part of Fix E

### Fix F: StreamingBubble Layout Stability — Correctly deferred to P2

The evaluation correctly identifies this as lower priority. Fixes D and E should eliminate the visible bounce regardless of layout stability. The `.fixedSize(horizontal: false, vertical: true)` on the StreamingBubble is correct — the bubble needs to grow vertically as content arrives.

**One observation:** The `StreamingBubble` uses `Text(content)` which re-wraps on every content change. This is fine for the ~50ms poll interval. Caching max height would add complexity for minimal gain. Defer.

---

## 3. Alternative Approaches

### Alternative 1: Minimal Fix (Smallest Change)

If the goal is to fix the bugs with the fewest changes:

1. **Remove the `asyncAfter(0.15)` re-scroll** — eliminates the double-scroll bounce
2. **Change the scroll target logic** to never target `"bottom-anchor"`:
   ```swift
   let targetId: String
   if isStreaming { targetId = "streaming-bubble" }
   else if thinkingState == .thinking { targetId = "thinking-bee" }
   else { targetId = messages.last?.id ?? "bottom-anchor" }
   ```
3. **Remove `onChange(of: showStreamingBubble)`** — it's redundant with `onChange(of: isStreaming)`

This three-line change set would fix ~80% of the bounce and white space issues without rewriting the scroll architecture.

### Alternative 2: Full Rewrite (What Fix D proposes)

Replace the reactive scroll model with a continuous anchoring model during streaming. More robust but more invasive. Risk of introducing new bugs in edge cases (topic switching, empty conversations, etc.).

**My recommendation:** Start with Alternative 1, test thoroughly, and only pursue Alternative 2 if Alternative 1 doesn't fully resolve the issues. The evaluation jumps to the full rewrite without considering the minimal fix path.

---

## 4. macOS Version Compatibility

**Project targets: macOS 14** (confirmed in Package.swift: `.macOS(.v14)`)

| API | Availability | Safe? |
|---|---|---|
| `scrollPosition(id:)` | macOS 14+ | ✅ Yes |
| `defaultScrollAnchor(.bottom)` | macOS 14+ | ✅ Yes (already in use) |
| `scrollBounceBehavior(.basedOnSize, axes:)` | macOS 14+ | ✅ Yes (already in use) |
| `.onScrollGeometryChange` | macOS 15+ | ❌ No — not available |
| `.scrollTargetBehavior` | macOS 15+ | ❌ No — not available |

**The evaluation's open question #1 is answered:** Use `scrollPosition(id:)` for position tracking (macOS 14+). Do NOT use `.onScrollGeometryChange` — it requires macOS 15.

---

## 5. Side Effects & Interactions with Fix A/B/C

### Fix B (SyncBridgeObserver state machine)
- The `thinkingState` transitions (`.idle → .thinking → .streaming → .idle`) are correct
- The `onChange(of: thinkingState)` handler in MessageCanvas only logs — no scroll side effects
- **No conflicts** with proposed Fix D/E

### Topic Switching (`onChange(of: topicId)`)
- Resets `isAtBottom = true` and `lastScrollTime = .distantPast` — good
- Sets `pendingTopicScroll` flag if messages are empty — good
- **Potential issue:** If a topic switch happens while streaming on the previous topic, the `isStreaming` flag may still be true. The new topic's canvas would inherit `isStreaming = true` but have no streaming content for that topic. This is a pre-existing issue, not introduced by Fix D/E.

### "Jump to Latest" Button
- Visibility controlled by `!isAtBottom` — works with current `onAppear`/`onDisappear` detection
- Button action calls `scrollToBottom(animated: true)` — this would trigger the asyncAfter re-scroll
- **After Fix D:** The button action should use non-animated scroll or a different animation approach

### Empty Conversation
- `messages.isEmpty` → `messages.last?.id` is nil → falls back to `"bottom-anchor"`
- **After Fix E:** During empty conversation, there's no streaming bubble, no thinking bee, no messages. The only scroll target would be `"bottom-anchor"`. This is fine for the initial scroll, but Fix E says "never target bottom-anchor." Need a fallback for the empty case.

**Recommendation:** Keep `"bottom-anchor"` as the absolute last-resort fallback for empty conversations. The rule should be: "never target bottom-anchor when there's actual content to target."

---

## Summary

| Item | Verdict |
|---|---|
| Root cause: scroll bounce | ✅ Confirmed. asyncAfter re-scroll is the biggest contributor. |
| Root cause: white space | ✅ Confirmed. bottom-anchor as scroll target is the cause. |
| Fix D: remove reactive scroll, remove asyncAfter | ✅ Sound. But `defaultScrollAnchor` alone isn't enough during streaming — need a throttled continuous scroll. |
| Fix E: change scroll target to content IDs | ✅ Sound. Keep bottom-anchor as empty-conversation fallback. |
| Fix F: StreamingBubble layout stability | ✅ Correctly deferred to P2. |
| macOS 14 compatibility | ✅ All proposed APIs are available. No iOS 18/macOS 15 APIs needed. |
| Interactions with Fix A/B/C | ✅ No conflicts identified. |

**Recommended approach:** Start with the minimal fix (Alternative 3 above — remove asyncAfter, fix scroll target, remove showStreamingBubble onChange). Test. If bounce persists during streaming content growth, add a throttled `onChange(of: streamingContent)` handler.

**Estimated effort:** 30-60 minutes for the minimal fix, including testing.
