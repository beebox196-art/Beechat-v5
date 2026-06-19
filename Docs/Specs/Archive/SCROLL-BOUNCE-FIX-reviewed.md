# SCROLL-BOUNCE-FIX: Streaming Bounce & White Space Fix

**Date:** 2026-05-28
**Status:** REVIEWED — Kieran conditional pass, all blockers addressed
**Risk:** MEDIUM — touches the primary message scroll view, but changes are removal-focused
**Scope:** Mac app ONLY — `MessageCanvas.swift`

---

## 1. Problem

Two related UI bugs in the BeeChat macOS app message canvas:

1. **Scroll bounce during streaming** — The message list visibly bounces/oscillates while waiting for or receiving a streaming response. This is the primary bug.

2. **White space gap** — A white space gap appears below message content when typing 2-3 lines in the composer, propagating across topic switches.

Both bugs share a root cause: competing scroll mechanisms fighting SwiftUI's layout engine.

## 2. Root Cause Analysis

### The bouncing during streaming

The `StreamingBubble` grows every 50ms (streaming poll interval) as new content arrives. Each growth causes:
1. `LazyVStack` recalculates the content height
2. `defaultScrollAnchor(.bottom)` tries to keep the view pinned to the bottom
3. SwiftUI recalculates scroll position
4. The content height changes again on the next poll
5. Steps 1-4 repeat, creating visible bounce

This is compounded by the fact that `StreamingBubble` uses `.fixedSize(horizontal: false, vertical: true)`, meaning every text change triggers a full height recalculation.

### The white space gap

Previously caused by the Jump-to-Latest button's `.offset(y: isAtBottom ? 8 : 0)` + `.animation(.easeInOut(duration: 0.2), value: isAtBottom)`. When the composer grew (lines 2-3), the container height changed, scroll geometry changed, `isAtBottom` toggled, the button offset animated, creating a layout feedback loop.

## 3. Changes Made (3 commits)

### Commit 1: `64b150f` — Initial scroll fix
- Added `.scrollBounceBehaviorCompat(axes: .vertical)` to disable rubber-band overscroll
- Removed `.offset` + `.animation` from Jump-to-Latest button

### Commit 2: `2c507d5` — Strip auto-scroll code
**Removed entirely:**
- `scrollToBottom()` function and debounce state (`lastScrollTime`)
- `pendingTopicScroll` state
- `onChange(of: messages.count)` — manual auto-scroll on new messages
- `onChange(of: showStreamingBubble)` — manual auto-scroll on streaming
- `onChange(of: thinkingState)` — manual auto-scroll on thinking
- `onChange(of: topicId)` — manual auto-scroll on topic switch
- `onAppear` — manual initial scroll

**Simplified:**
- `isAtBottom` hysteresis (was 50px/120px enter/leave thresholds) → single 80px threshold
- Only manual scroll remaining: Load Earlier anchor (user-initiated) and Jump to Latest button

**Rationale:** `defaultScrollAnchor(.bottom)` handles all auto-scroll natively. Manual `scrollToBottom` calls fought with it, causing bounce.

### Commit 3: `16b0130` — Streaming bubble height tracking
**Added:**
- `@State private var streamingMinHeight: CGFloat = 0`
- `StreamingHeightKey` PreferenceKey
- `GeometryReader` on `StreamingBubble` that reports height via preference key
- `.frame(minHeight: streamingMinHeight, alignment: .top)` on `StreamingBubble`
- `.onPreferenceChange(StreamingHeightKey.self)` that only grows `streamingMinHeight` (never shrinks)
- `.onChange(of: isStreaming)` that resets `streamingMinHeight = 0` when streaming ends

**How it works:** The streaming bubble's `minHeight` only ever increases during a streaming session. This means the `LazyVStack` sees the content only expanding downward — never resizing. `defaultScrollAnchor(.bottom)` handles downward expansion smoothly. When streaming ends, the min-height resets so the final message (now in the `messages` array) renders at its natural height.

## 4. Kieran Review (addressed)

### BLOCKER: `scrollProxy` never assigned — FIXED
The Jump-to-Latest button referenced `@State scrollProxy` which was never assigned after `onAppear` was stripped. **Fix:** Changed `jumpToLatestButton` from a computed property to a function `jumpToLatestButton(proxy:)` that takes the `ScrollViewProxy` directly from the `ScrollViewReader` closure. Removed `@State scrollProxy` entirely.

### CONCERN 1: Topic switch with incremental loading — FIXED
Added `onChange(of: topicId)` that sets `isAtBottom = true` and does a delayed `scrollTo("bottom-anchor")` after 50ms. `defaultScrollAnchor(.bottom)` handles initial position, the manual nudge catches incremental message loading.

### CONCERN 2: `streamingMinHeight` reset on flicker — FIXED
Changed reset condition from `!isStreaming` to `!isStreaming && streamingContent.isEmpty`. Added belt-and-braces `onChange(of: streamingContent)` that also checks both conditions. This prevents reset during brief `isStreaming=false` flickers between poll cycles.

## 5. Verification Checklist

- [ ] Scroll canvas does NOT bounce during streaming
- [ ] Scroll canvas does NOT bounce when receiving a new message
- [ ] No white space gap appears when typing multi-line messages
- [ ] Jump-to-Latest button works (scrolls to bottom when tapped)
- [ ] Jump-to-Latest button appears when scrolled up, disappears when at bottom
- [ ] Topics switch correctly (scrolls to bottom after switch)
- [ ] Load Earlier messages scrolls to correct anchor position
- [ ] Streaming content appears smoothly without jank
- [ ] After streaming ends, final message renders at correct height (no tall gap)
- [ ] No bounce on macOS 14 (fallback: no scrollBounceBehavior, no onScrollGeometryChange)

## 6. Files Changed

| File | Change |
|------|--------|
| `Sources/App/UI/Components/MessageCanvas.swift` | All 4 commits — removed auto-scroll, added streaming height tracking, fixed proxy/topic/minHeight |

## 7. Risk Assessment

- **Low risk:** No changes to message data flow, streaming pipeline, or observer logic
- **Low risk:** `StreamingBubble` unchanged — only wrapped with a height-tracking frame
- **Low risk:** Jump-to-Latest button now takes proxy directly — always functional
- **Medium risk:** `defaultScrollAnchor(.bottom)` is the primary auto-scroll mechanism, supplemented by `onChange(of: topicId)` for topic switches
- **Low risk:** `streamingMinHeight` reset now requires both `!isStreaming && streamingContent.isEmpty` — hardened against flicker
- **Low risk:** macOS 14 fallback: `isAtBottom` stays true, Jump button hidden, `defaultScrollAnchor(.bottom)` still works