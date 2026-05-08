# Mel's Final Review: BC5-SPEC-005 v2 (Jump to Latest Message)

**Reviewer:** Mel (UX)  
**Date:** 2026-05-08  
**Spec:** BC5-SPEC-005 v2  
**Source reviewed:** `MessageCanvas.swift`  

---

## Question 1: Will removing `autoScroll` affect existing behaviour?

**No.** `@State private var autoScroll = true` is declared on line 30 but never read anywhere in the view body. No conditional, no binding, no `.onChange` references it. It's dead state. Safe to remove with zero UX impact.

---

## Question 2: Will the new scroll detection change how auto-scroll works when at the bottom?

**No visible change.** Currently, when a user is at the bottom and a new message arrives, `onChange(of: messages.count)` calls `scrollToBottom` unconditionally. Under the spec, `isAtBottom` will be `true` (within the 50px enter threshold), so the same `scrollToBottom` fires. Same animation, same timing, same result.

The only scenario where behaviour *intentionally* changes is when the user has scrolled up — currently they get force-scrolled down (annoying), and under the spec they stay put with a Jump button instead. That's an improvement, not a regression.

---

## Question 3: Will the Jump button overlay obscure existing UI elements?

**No overlap risk.** Here's what lives where:

| Element | Location | Overlap risk |
|---------|----------|-------------|
| Composer | Outside `MessageCanvas` entirely (sibling in parent) | None — button is inside the canvas |
| Streaming bubble | Inside `LazyVStack`, scrolls with content | None — button is an overlay on top, positioned bottom-right |
| Thinking indicator | Inside `LazyVStack`, scrolls with content | None — same as above |
| "Load earlier messages" | Inside `LazyVStack`, at the **top** | None — button is at the **bottom** |

The button is 36×36pt with 12pt padding, bottom-trailing. Standard chat-app pattern (iMessage, Telegram, WhatsApp all do this). It sits in the clear zone above the composer. ✅

---

## Question 4: Will the hysteresis thresholds (50px/120px) make existing auto-scroll feel different or slower?

**No.** The hysteresis only affects *whether* `isAtBottom` is true, not *how fast* the scroll animation runs. The thresholds:

- **50px enter:** User must be within 50px of the bottom to be considered "at bottom." This is generous — on a typical message list, that's less than one message height. If you're close enough to see the bottom, you're "at bottom."
- **120px leave:** User must scroll more than 120px away before we stop considering them "at bottom." This prevents the Jump button from flickering during momentum scrolling near the boundary.

The scroll animation itself (`.easeInOut(duration: 0.2)`) is unchanged. When a user is pinned to the bottom and a message arrives, the experience is identical to today. The hysteresis only affects the *transition* between states, and 50/120px are well-chosen values that prevent flicker without making the state feel sticky. ✅

---

## Question 5: Will the streaming override feel natural?

**Yes, with one implementation note.** The spec's `onChange(of: messages.count)` gates auto-scroll on `isActiveTopicStreaming`, but the **existing** `.onChange(of: isStreaming)` and `.onChange(of: showStreamingBubble)` handlers (lines 83–91) *still unconditionally* call `scrollToBottom`. This means:

- **Streaming starts while at bottom:** Already scrolls via the `isStreaming` handler → same as today. ✅
- **Streaming starts while scrolled up:** The `isStreaming` handler fires and forces a scroll down. This is *current* behaviour and the spec doesn't remove these handlers.

**UX impact:** If you want the "streaming while scrolled up shows Jump button instead" behaviour from test case 8, Q must **also gate the `isStreaming` and `showStreamingBubble` handlers on `isAtBottom`**. The spec's section 2 only shows the `messages.count` handler change, but these other handlers also trigger unconditional scrolls during streaming. If they're left untouched, streaming will *always* force-scroll, which matches current behaviour but contradicts test case 8.

**Recommendation:** Q should gate all three scroll-triggering handlers consistently, or document that streaming always auto-scrolls (which is actually fine UX — users expect streaming text to scroll into view). Flag this in the build notes.

---

## Question 6: Will the `scrollToBottom` retry cause visible double-scroll or animation glitch?

**No visible glitch.** The retry mechanism works like this:

1. **First attempt** (next run loop): `withAnimation(.easeInOut(duration: 0.2))` scrolls to bottom-anchor.
2. **Second attempt** (200ms later): Plain `scrollTo` without animation.

If the first attempt succeeds (LazyVStack has already laid out the bottom-anchor), the view is at the bottom. The second attempt scrolls to the same position — a no-op. No double-scroll, no animation glitch.

If the first attempt fails (bottom-anchor doesn't exist yet), the view stays put. The second attempt then succeeds 200ms later. The user sees a brief delay, then a snap to bottom. This is better than the current behaviour where `scrollTo` silently fails and the user is stuck at the top.

**One subtlety:** The current `scrollToBottom(proxy:)` is called from `onAppear` with animation. Under the new mechanism, `onAppear` stores the proxy and calls the parameterless `scrollToBottom()`. Q needs to ensure the `onAppear` proxy-capture happens correctly, but this is an implementation detail, not a UX risk. ✅

---

## Question 7: Are there UX scenarios that currently work smoothly that this change could break?

I reviewed every scroll-triggering path in the current code:

| Scenario | Current | Proposed | Regress risk |
|----------|---------|----------|-------------|
| Topic switch → scroll to latest | `onAppear` → `scrollToBottom` | Same (proxy stored on appear, retry mechanism) | None — retry actually *fixes* the top-of-chat bug |
| Send message while at bottom | `onChange(messages.count)` → `scrollToBottom` | `isAtBottom=true` → `scrollToBottom` | None |
| Scroll up, new message arrives | Forced scroll down (annoying) | Stay put, Jump button appears | **Improvement** |
| Stream starts while at bottom | `onChange(isStreaming)` → `scrollToBottom` | Same (handler unchanged) | None |
| Load earlier messages | Anchor + scroll to anchor | Same | None |
| Momentum scroll near bottom | No button (no detection) | Button may flicker | None — hysteresis prevents this |

**The only scenario that could differ:** If Q removes the `isStreaming`/`showStreamingBubble` onChange handlers (which the spec doesn't say to do), streaming would stop auto-scrolling. But those handlers should remain, so this is a non-issue if implemented correctly.

**Edge case — `isAtBottom` initial state:** The spec sets `isAtBottom = true` initially. This is correct — on first render, before any scroll geometry is calculated, we want auto-scroll. The `onScrollGeometryChange` will update it once layout happens. ✅

---

## Verdict

### 🟢 GREEN LIGHT — Safe to Build

The spec is clean, the hysteresis values are well-chosen, the retry mechanism fixes a real bug, and no current UX flows regress. The Jump button follows established chat-app patterns.

### Build Notes for Q

1. **Gate all scroll handlers consistently.** The spec only shows the `messages.count` handler, but `isStreaming` and `showStreamingBubble` handlers also call `scrollToBottom` unconditionally. Decide: gate them on `isAtBottom` too (test case 8: streaming while scrolled up shows Jump button), or leave them as-is (streaming always auto-scrolls, which is also fine UX). Document the choice.

2. **Store `ScrollViewProxy` in `onAppear`.** The current code passes `proxy` as a parameter. The new mechanism stores it in `@State`. Make sure `onAppear` captures and stores it before any `scrollToBottom()` calls.

3. **Don't remove the `anchorMessageId` path.** The spec keeps it — just make sure the "else if" chain preserves the anchor-first priority.

4. **Accessibility labels are good.** Keep them.

---

*Mel — UX review complete. Safe to build.*