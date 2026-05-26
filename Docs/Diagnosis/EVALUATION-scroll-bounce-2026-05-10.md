# Evaluation: Scroll Bounce & White Space During Streaming

**Date:** 2026-05-10  
**Author:** Bee (Coordinator)  
**Status:** Pending Review  

## Symptom Description

Two related UI bugs observed during streaming (while Bee is thinking/responding):

1. **Scroll Bounce** — The chat view "bounces" repeatedly while content is being streamed. It appears to try to scroll to the bottom of a message that hasn't finished rendering, then re-adjusts when the layout settles. Visible as a jittering/bouncing scroll position.

2. **White Space at Bottom** — During streaming, the view scrolls past the last message bubble into a large empty white area at the bottom of the chat. The empty area persists until the streaming content catches up.

Both symptoms occur only during active streaming. Once the message completes, the view settles correctly.

## Root Cause Analysis

### Code Location

`MessageCanvas.swift` — the scrollable message list view.

### How Scroll Works Currently

The canvas uses `ScrollViewReader` + `ScrollView` + `LazyVStack` with a `bottom-anchor` spacer (`Color.clear.frame(height: 2).id("bottom-anchor")`). Scroll-to-bottom is triggered by three `onChange` handlers:

| Handler | Trigger | Behaviour |
|---|---|---|
| `onChange(of: messages.count)` | New message added | Scrolls to bottom if at-bottom, user message, or streaming |
| `onChange(of: isStreaming)` | Streaming starts/stops | Scrolls to bottom when streaming begins |
| `onChange(of: showStreamingBubble)` | Streaming bubble appears/disappears | Scrolls to bottom when streaming bubble first shown |

Additionally, `scrollToBottom()` has:
- A **0.3s deduplication guard** during streaming/thinking (skips scroll if last scroll was <0.3s ago)
- An **animated mode** that does `scrollTo` inside `withAnimation`, plus a `DispatchQueue.main.asyncAfter(0.15)` re-scroll for "LazyVStack settling"

### Why It Bounces

During streaming, the `StreamingBubble` content updates every ~50ms (the poll interval). Each update changes `streamingContent`, which SwiftUI re-renders as a taller `Text(content)`. This height change triggers `onChange(of: showStreamingBubble)` on the **first** content arrival, but subsequent content growth doesn't directly trigger a scroll handler.

However, SwiftUI's `LazyVStack` recalculates layout when children change size. The `bottom-anchor` spacer sits after the `StreamingBubble` in the `LazyVStack`. As the streaming bubble grows:
1. SwiftUI re-layouts the `LazyVStack`
2. The scroll view's content size increases
3. The scroll position becomes stale — the viewport is now higher than the actual bottom
4. Any `scrollToBottom` call (from any trigger) jumps to the new bottom
5. But the `LazyVStack` may not have finished rendering the new content height yet
6. So the scroll overshoots, then settles back — **bounce**

The 0.3s deduplication doesn't fully prevent this because:
- The `asyncAfter(0.15)` re-scroll in animated mode adds a second scroll 150ms after the first
- State changes (`thinkingState`, `isStreaming`) can trigger additional scroll calls within the 0.3s window
- The `bottom-anchor` approach means the scroll target can be a tiny invisible spacer below the content, which SwiftUI treats as valid scroll destination even when there's nothing visible there

### Why White Space Appears

The `bottom-anchor` is `Color.clear.frame(height: 2)`. When `scrollTo(targetId, anchor: .bottom)` targets `messages.last?.id ?? "bottom-anchor"`:
- During streaming, `messages.last` is the user's message (the assistant message hasn't been committed to the message list yet)
- So the scroll target falls back to `"bottom-anchor"` — the invisible spacer
- The scroll view scrolls so this spacer's bottom edge aligns with the viewport bottom
- But the streaming bubble above it may not have finished laying out
- Result: scroll overshoots past the streaming content into the clear spacer area — **white space**

### The ThinkingBee Factor

The `ThinkingBeeIndicator` has a `.bounce` animation (`easeInOut(duration: 1.5).repeatForever`) that moves the bee up 2pts. This is visual-only and shouldn't affect scroll, but when the state transitions from `.thinking` → `.streaming`:
1. `ThinkingBeeIndicator` disappears
2. `TypingIndicator` appears briefly (suppressed if `thinkingState == .streaming`)
3. `StreamingBubble` appears

Each transition triggers layout recalculation + potential scroll adjustment. The `thinkingState` change also triggers an `onChange` handler (currently just logging), but doesn't trigger a scroll. The scroll bounce comes from the content height changes, not the animation.

## Proposed Fixes

### Fix D: Eliminate Scroll Bounce During Streaming

**Problem:** `scrollToBottom()` is called reactively on state changes, but streaming content grows continuously. Each reactive scroll fights the LazyVStack's asynchronous layout.

**Solution:** Replace reactive `onChange(of: showStreamingBubble)` scrolling with a **continuous scroll-anchoring mode** during streaming. While streaming is active, pin the scroll to the bottom using SwiftUI's `scrollPosition` API (iOS 17+) or `defaultScrollAnchor(.bottom)` combined with content-anchoring.

**Specific changes in `MessageCanvas.swift`:**

1. **Remove `onChange(of: showStreamingBubble)`** — this fires once when the streaming bubble appears, but the bounce comes from ongoing layout changes, not this single event.

2. **Replace the `onChange(of: isStreaming)` handler** — instead of a one-shot `scrollToBottom`, set a flag that keeps the view pinned to bottom for the entire streaming duration.

3. **Replace deduplication + asyncAfter with `scrollPosition` anchoring** — use `.defaultScrollAnchor(.bottom)` (already present) combined with removing the reactive `scrollToBottom` calls during streaming. The `defaultScrollAnchor(.bottom)` already tells SwiftUI to prefer the bottom; the manual scrolls are fighting it.

4. **Remove the `asyncAfter(0.15)` re-scroll** — this is the single biggest cause of bounce. It was added to handle `LazyVStack` rendering delays, but it creates a visible double-scroll (original + 150ms later). `defaultScrollAnchor(.bottom)` handles this natively.

5. **Keep `onChange(of: messages.count)` for non-streaming cases** — new user messages and completed assistant messages should still auto-scroll. But during streaming, let `defaultScrollAnchor(.bottom)` handle it.

### Fix E: Remove White Space at Bottom

**Problem:** The `bottom-anchor` spacer (`Color.clear.frame(height: 2)`) is used as a scroll target and for `isAtBottom` detection. But it allows the scroll to overshoot into empty space.

**Solution:** Two changes:

1. **Move `isAtBottom` detection from `onAppear`/`onDisappear` to a `ScrollView` position observer** — Use `.onScrollGeometryChange` (iOS 18+) or `onScrollVisibilityChange` to detect whether the last message is visible, rather than relying on a spacer's `onAppear`/`onDisappear`. This eliminates the need for the `bottom-anchor` spacer entirely for scroll-position detection.

   If targeting older macOS (the project targets macOS 14 / iOS 17), use the `scrollPosition(id:)` API instead, which gives direct scroll position without needing a sentinel element.

2. **Change scroll target from `"bottom-anchor"` to the last message or streaming bubble ID** — `scrollToBottom()` currently uses `messages.last?.id ?? "bottom-anchor"`. During streaming, `messages.last` is the user's message, so it falls back to the invisible spacer. Change to target `"streaming-bubble"` when streaming, `"typing-indicator"` or `"thinking-bee"` when thinking, and `messages.last?.id` otherwise. Never target the bottom-anchor spacer for scrolling.

**Combined effect:** No invisible spacer can be scrolled to, and scroll position detection doesn't depend on an element that lives in the scroll content.

### Fix F (P2): StreamingBubble Layout Stability

**Problem:** `StreamingBubble` uses `.fixedSize(horizontal: false, vertical: true)` with `Text(content)`. Every content change causes the text to re-wrap, potentially changing the bubble height. SwiftUI recalculates layout on each change, causing the scroll view to adjust.

**Solution:** This is lower priority but worth noting. Options:
- Cache the _maximum_ height seen and prevent the bubble from shrinking (only grows). This eliminates height decreases that cause bounce.
- Use `TextEditor` or a fixed-height container that doesn't resize per-character.
- Accept this as cosmetic — Fixes D and E should eliminate the visible bounce regardless.

## Testing Checklist

- [ ] **Stream a long message** — no bounce/jitter during streaming
- [ ] **Stream a short message** — no white space at bottom
- [ ] **Send a message while streaming** — auto-scrolls to user message, then back to streaming
- [ ] **Scroll up during streaming** — stops auto-scrolling (user is reading history)
- [ ] **Scroll to bottom during streaming** — "Jump to latest" button works
- [ ] **Thinking → Streaming transition** — no bounce during state change
- [ ] **Streaming completes** — view settles at bottom, no white space
- [ ] **Topic switch while streaming** — scrolls to bottom of new topic
- [ ] **Empty conversation** — no crash, no white space
- [ ] **Long conversation (>100 messages)** — scroll performance acceptable
- [ ] **macOS 14 compatibility** — no use of iOS 18+ only APIs without fallback

## Files Affected

| File | Changes |
|---|---|
| `MessageCanvas.swift` | Scroll logic rewrite: remove reactive onChange scroll during streaming, remove asyncAfter, target streaming bubble instead of bottom-anchor |
| `StreamingBubble.swift` | No changes required for Fixes D+E (Fix F is P2) |
| `SyncBridgeObserver.swift` | No changes — state machine is correct after Fix B |

## Risk Assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| `defaultScrollAnchor(.bottom)` not sufficient on its own | Medium | Test on macOS 14 and 15; add explicit `scrollTo` for user messages only |
| Scroll position detection without bottom-anchor spacer | Medium | Use `scrollPosition(id:)` with `Binding` if available; fall back to GeometryReader-based detection |
| Removing `asyncAfter` re-scroll causes lazy layout not settling | Low | `defaultScrollAnchor(.bottom)` handles this; test with long messages |
| Topic switching scroll timing | Low | `pendingTopicScroll` flag already handles this case |

## Open Questions

1. **macOS version targeting** — Does BeeChat target macOS 14 only, or also macOS 15+? `scrollPosition(id:)` requires iOS 17 / macOS 14+. `.onScrollGeometryChange` requires iOS 18 / macOS 15. This affects whether we can use modern scroll APIs or need fallbacks.
2. **StreamingBubble height stability** — Should we address Fix F (height caching) now or defer to P2?