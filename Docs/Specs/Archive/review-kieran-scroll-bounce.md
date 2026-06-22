# Review: BC5-SPEC-005 Scroll Bounce Fix

**Reviewer:** Kieran (Independent Safety Review)  
**Date:** 2026-05-08  
**Spec:** BC5-SPEC-005  
**Code reviewed:** `MessageCanvas.swift`

---

## 1. Will removing animation from `scrollToBottom` make topic switches feel jarring?

**Verdict: No — the spec preserves animation for topic switch.**

The spec explicitly keeps `scrollToBottom(animated: true)` for topic switch (`onChange(of: topicId)`) and `onAppear`. The unanimated path only applies to streaming-related triggers. This is the right split.

**One gap:** The current `onChange(of: topicId)` handler doesn't call `scrollToBottom()` at all — it just sets `isAtBottom = true`. The actual scroll to bottom on topic switch comes from the view re-rendering and `onAppear` firing. The spec assumes topic switch will call `scrollToBottom(animated: true)`, but the current code doesn't wire it that way. **Implementation must add the animated scroll call inside `onChange(of: topicId)`**, or confirm `onAppear` reliably fires on topic switch (it should, since the view is recreated, but this needs verification).

**Risk level:** Low. Just needs the implementation to actually add the call.

---

## 2. Will the deduplication window (0.3s) miss any legitimate scroll events?

**Verdict: Unlikely, but edge case exists for fast multi-message bursts.**

During streaming, message content updates arrive at roughly 20-50ms intervals (typical LLM token rates). A 300ms window means we scroll once, then ignore all updates for 300ms. The last update in a streaming burst is what matters — and since `messages.count` doesn't change mid-token (only when a new message object is appended), the actual scroll triggers from `messages.count` are per-message, not per-token.

The real risk: if a user sends a message and the assistant reply starts within 300ms of the user message scroll, the assistant-triggered scroll could be suppressed. In practice, LLM response time is >>300ms, so this is safe.

**The streaming bubble (`showStreamingBubble`) updates don't use `messages.count`** — they're driven by the computed property changing as `streamingContent` grows. But the spec only deduplicates through `scrollToBottomIfNeeded()`, which `onChange(of: showStreamingBubble)` will call. The first bubble appearance scrolls; subsequent content growth within 300ms is suppressed. This is correct — the bubble grows in place, so no scroll is needed until it pushes content past the viewport.

**Risk level:** Low.

---

## 3. Could `lastScrollTime` state get stale and prevent scrolling when it should happen?

**Verdict: Minor risk — state not reset on topic switch.**

`lastScrollTime` is `@State`, so it persists across re-renders but resets when the view is recreated (topic switch). Within a single topic session:

- If the user manually scrolls down (tapping Jump button), `lastScrollTime` isn't updated, so the next `scrollToBottomIfNeeded()` call could be suppressed if it falls within 300ms. But the Jump button calls `scrollToBottom()` directly (not the deduplicated path), so this is fine.

- If a streaming response ends and a new one starts within 300ms (unlikely but possible if user spams), the second stream's initial scroll could be suppressed. This is a genuine but extremely rare edge case.

**Recommendation:** Reset `lastScrollTime = .distantPast` inside `onChange(of: topicId)` as a safety measure.

**Risk level:** Low.

---

## 4. Will removing the 200ms fallback during streaming cause the "stuck at top" bug to return?

**Verdict: No — the fallback exists for LazyVStack layout timing on initial render.**

The 200ms fallback is needed because when a new topic's LazyVStack first renders, the content may not have its final height yet. `ScrollViewReader.scrollTo` fires before layout completes, so it scrolls to where the bottom *will be*, but the content hasn't expanded — resulting in being stuck ~1-2 messages from the actual bottom. The 200ms retry catches this.

During streaming, content is already rendered and growing incrementally. The LazyVStack items exist; the scroll target ("bottom-anchor") is in view. No layout race exists. Removing the fallback for streaming-only is safe.

**The spec correctly preserves the fallback for `animated: true` (topic switch).** This is the correct boundary.

**Risk level:** None.

---

## 5. Edge cases where the fix could break existing behaviour

### Topic switch
- **Current:** No explicit scroll on topic switch — relies on `onAppear`.  
- **Spec:** Adds animated scroll on topic switch. This is an improvement, not a regression. But as noted in §1, implementation must wire it correctly.

### Streaming
- **Current:** Bouncing from over-scrolling.  
- **Spec:** Deduplicated, unanimated scrolling. Should eliminate the bounce. The first scroll (when streaming starts) is immediate and unanimated, which is fine — users expect the view to snap to the streaming content, not ease into it.

### Manual scroll / "user scrolled up" behaviour
- **Current:** `isAtBottom` gate prevents forced scroll when user is reading history. `messages.count` change checks `isAtBottom || isUserMessage || isStreaming`.  
- **Spec:** Doesn't change this gate. `scrollToBottomIfNeeded()` is just a deduplication wrapper — it still respects the existing `isAtBottom` logic from the `onChange(of: messages.count)` handler.  
- **Concern:** The spec shows `scrollToBottomIfNeeded()` being used in `onChange(of: isStreaming)` and `onChange(of: showStreamingBubble)`, but the current code doesn't check `isAtBottom` in those handlers — it always scrolls when streaming starts. This is intentional (you always want to follow the live stream). The deduplication wrapper preserves this behaviour. No regression.

### Jump button
- Calls `scrollToBottom()` directly. Not affected by deduplication.  
- However, the Jump button also sets `isAtBottom = true` manually. If a streaming `scrollToBottomIfNeeded()` fires within 300ms of the Jump button press, it would be suppressed. But again, Jump uses the direct path, so this is fine.

### `anchorMessageId` / "Load earlier" flow
- Not touched by the spec. The existing `onChange(of: messages.count)` handler checks for `anchorMessageId` first and scrolls to the anchor with animation. This path is unaffected by the deduplication because `scrollToBottomIfNeeded()` isn't used here.

---

## Summary

| Question | Risk | Notes |
|---|---|---|
| Animation removal jarring? | Low | Spec preserves animation for topic switch; implementation must wire it |
| Dedup window too aggressive? | Low | 300ms is conservative for streaming; edge case is rare |
| `lastScrollTime` stale? | Low | Reset on topic switch recommended |
| Fallback removal = stuck bug? | None | Fallback only needed for initial LazyVStack render |
| Edge case regressions? | None found | All existing gates and paths preserved |

**Required implementation fix:** Add `lastScrollTime = .distantPast` reset in `onChange(of: topicId)`.

**Recommended implementation fix:** Add explicit `scrollToBottom(animated: true)` call in `onChange(of: topicId)` to match the spec's intent.

---

## Verdict: 🟢 GREEN LIGHT

The fix is well-targeted, correctly scopes animation and fallback removal to streaming-only paths, and preserves all existing user-scroll guards. Two minor implementation notes above, but no regression risk that would block merge.