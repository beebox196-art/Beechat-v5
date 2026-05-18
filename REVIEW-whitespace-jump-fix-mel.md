# UX Review — White Space Jump Fix

**Reviewer:** Mel (UX)  
**Date:** 2026-05-15  
**Spec:** `SPEC-whitespace-jump-fix.md`  
**Code reviewed:** `MessageCanvas.swift` (post-fix implementation)

---

## TL;DR

The fix is correct and well-targeted. Removing `isUserMessage` from the scroll condition eliminates the root cause of the white-space jump, and the remaining `defaultScrollAnchor(.bottom)` + geometry-based `isAtBottom` policy matches how every mature chat app works. I have three recommendations (animation policy, "new messages" indicator, and multi-topic scroll independence) and one minor concern (debounce timing). None are blockers.

---

## 1. User Expectations: Telegram & iMessage Scroll Behaviour

### How they actually work

| Scenario | Telegram | iMessage |
|---|---|---|
| User at bottom, sends message | Stays pinned to bottom. No explicit scroll call — content grows downward and the anchor holds. | Same. Content grows, scroll position stays at bottom. |
| User at bottom, streaming response arrives | Stays pinned. The text grows in-place; the view scrolls with it. | Same (though iMessage doesn't stream; it arrives as a complete message). |
| User scrolled up, new message arrives | **No forced scroll.** A "↓ New messages" pill appears. User taps to jump down. | Same. A "tap to return to conversation" banner appears at the bottom. |
| Rapid content growth (streaming) | Smooth, continuous. The scroll tracks the growing bubble without visible jumps. | N/A (no streaming). |
| User scrolls up slightly during streaming | Streaming continues. View does NOT yank back to bottom. User stays where they scrolled. | N/A. |

**Key insight:** Neither app ever calls an explicit "scroll to bottom" on content arrival when the user is already at the bottom. They rely on natural scroll anchoring — the content grows downward, and the scroll position stays at the bottom because the content was already at the bottom. The only explicit scroll-to-bottom is when the user taps the "new messages" indicator.

### The proposed fix matches this exactly

The fix removes `isUserMessage` as a scroll trigger and relies on `defaultScrollAnchor(.bottom)` + `isAtBottom` geometry. This is the correct policy:

> **Only auto-scroll if already at the bottom. Otherwise, show an indicator.**

This is what users expect from every chat app they've ever used.

---

## 2. Is "Only Auto-Scroll if Already at Bottom" the Right Policy?

**Yes, absolutely.** This is the gold standard for chat scroll behaviour:

- **At bottom → stay at bottom.** Content grows, view stays pinned. No jumps.
- **Scrolled up → don't move.** Let me read. Show me a subtle indicator that new content arrived.

### Should there be a "New Messages" indicator?

**Yes, and BeeChat already has one** — the "Jump to latest" chevron button. It's shown when `isAtBottom == false`. This is the right mechanism.

However, the current implementation could be improved:

| Aspect | Current | Recommendation |
|---|---|---|
| Label | Chevron-down icon only | Add a small badge: "3 new" or just "New ↓" on first new message. Makes it discoverable. |
| Position | Bottom-right corner | ✅ Correct — matches Telegram/iMessage |
| Animation | Fades in/out | ✅ Correct — subtle |
| Action | Scrolls to bottom | ✅ Correct |

The chevron button is functional but **not very discoverable** for a new user. A small "New" label next to the chevron would help significantly. This is not a blocker — it's a polish item.

### The "scroll up slightly then response starts" edge case

The spec asks: *"What about when a user sends a message and scrolls up slightly before the response starts?"*

Current behaviour: `isAtBottom` tracks geometry. If the user scrolls up by even a small amount (>24pt threshold), `isAtBottom` becomes `false`. When the streaming content arrives, no forced scroll happens. The "Jump to latest" button appears.

**This is correct behaviour.** The user chose to scroll up. Respect that choice. The indicator is there if they want to come back down.

The 24pt threshold is reasonable — it's roughly 2 lines of text. Below that, you're still "at the bottom" in user perception. Above that, you intentionally scrolled up.

---

## 3. Animation & Timing Concerns

### `animated: false` for automatic scrolls — is this right?

**Mostly yes, with one refinement.**

The current code uses `animated: false` for all auto-scrolls during content changes (the `onChange(of: messages.count)` path). This is correct for streaming because:

- During streaming, content grows at 50ms intervals. An animated scroll on every content delta would create a constant, jittery animation.
- Telegram also does not animate during streaming — it snaps smoothly.

**However**, there's one case where animation would be better: when a new user message appears and the user is already at the bottom. Currently, the scroll snaps. A very short animation (100-150ms, easeOut) would feel more natural — like the content "settled" rather than "jumped."

But — and this is important — **adding animation here was exactly what caused the white-space bug** in the first version. The `scrollToBottom(animated: true)` during streaming fights with SwiftUI's layout engine. So the fix is correct to use `animated: false` during the streaming phase.

**Recommendation:** The current `animated: false` is the safe choice. If we want a subtle animation on initial user message send (before streaming starts), that could be a future polish item, but it needs careful testing to ensure it doesn't re-introduce the overshoot. Not worth the risk right now.

### 150ms debounce — is it noticeable?

**No, it's not noticeable.** Here's why:

- The debounce only affects explicit `scrollToBottom` calls, not `defaultScrollAnchor(.bottom)`.
- When the user is at the bottom, `defaultScrollAnchor(.bottom)` handles the pinning continuously — no debounce involved.
- The debounce only kicks in when the system tries to call `scrollToBottom` repeatedly within 150ms. This is a safety valve against layout feedback, not something the user sees.

The user will never perceive a 150ms gap because the scroll anchor is doing the work, not the explicit scroll call. The debounce is purely defensive. **150ms is fine. Could even be 200ms if we see further feedback loops.**

---

## 4. Multi-Topic Streaming

### Does each topic have independent scroll state?

**Yes, correctly.** Looking at the code:

```swift
struct MessageCanvas: View {
    @State private var isAtBottom: Bool = true
    @State private var scrollProxy: ScrollViewProxy?
    @State private var pendingTopicScroll: Bool = false
    @State private var lastScrollTime: Date = .distantPast
```

These are all `@State` inside `MessageCanvas`, which means each canvas instance has its own independent state. When switching topics, the previous `MessageCanvas` is removed from the view hierarchy and a new one is created (or re-created) for the new topic.

The `onChange(of: topicId)` handler explicitly resets `isAtBottom = true` and scrolls to bottom on topic switch, which is the right behaviour — you want to arrive at the latest content when switching topics.

### What happens when switching between two active streaming topics?

1. **Topic A is streaming** → User is at bottom, content growing
2. **User switches to Topic B** (also streaming) → `onChange(of: topicId)` fires, `isAtBottom = true`, `scrollToBottom(animated: true)` runs, user sees Topic B's latest content
3. **User switches back to Topic A** → Same thing: `onChange(of: topicId)` fires, scrolls to bottom of Topic A

This is correct. Each topic gets a fresh scroll-to-bottom on arrival, and streaming continues from wherever it was.

**One subtlety:** When the user switches away from a streaming topic and comes back, they'll be scrolled to the bottom, not to where they left off. This matches Telegram behaviour (switching chats always takes you to the bottom) and is the expected UX. No issue here.

### Potential concern: Topic A's scroll state is destroyed on switch

Since `@State` is tied to the view's identity in the hierarchy, and switching topics replaces the `MessageCanvas`, all scroll state is lost. This means:

- ✅ Fresh start on topic switch (expected)
- ✅ No stale scroll position carrying over (good)
- ⚠️ If we ever want to preserve scroll position across topic switches (e.g., "return to where I was reading"), we'd need external state storage. But that's a feature request, not a bug.

**Verdict: Current multi-topic behaviour is correct and matches user expectations.**

---

## 5. Overall Scroll Feel Goal

### Should BeeChat match Telegram exactly, or improve?

**Match Telegram's core policy, improve where safe.** The core policy — "at bottom = stay pinned, scrolled up = don't move, indicator = optional jump" — is the correct one. Every successful chat app uses it. Don't reinvent this wheel.

Where BeeChat can differentiate (safely):

1. **"New messages" badge** — Telegram shows a count ("3 new messages"). BeeChat currently shows just a chevron. Adding a count or "New" label is low-risk polish.

2. **Smooth re-entry** — When the user taps "Jump to latest," the current code does `withAnimation(.easeInOut(duration: 0.2))`. This is good. Telegram does a similar smooth scroll. ✅

3. **Topic switch animation** — Currently `scrollToBottom(animated: true)` on topic switch. This is fine but could be even smoother with a very short `easeOut` curve. Low priority polish.

### Patterns worth adopting from other apps

| Pattern | Source | Applicable? |
|---|---|---|
| Scroll-to-bottom with unread count badge | Telegram, Discord | Yes — polish item for later |
| Subtle fade-in for "new messages" indicator | WhatsApp | Already implemented ✅ |
| Scroll position memory per conversation | Telegram | Would need architectural change — not now |
| Velocity-aware auto-scroll (don't auto-scroll if user is actively scrolling) | Signal | Currently handled by `isAtBottom` threshold — close enough |
| "Scroll to first unread" on topic switch (not scroll to bottom) | Slack | Interesting but complex — future feature |

---

## Summary

### ✅ Approved — the fix is correct

The removal of `isUserMessage` from the scroll condition eliminates the white-space jump bug at its root cause. The remaining policy (`defaultScrollAnchor(.bottom)` + geometry-based `isAtBottom` + "Jump to latest" button) matches the established UX patterns of every major chat application.

### Recommendations (none are blockers)

| # | Priority | Recommendation | Rationale |
|---|---|---|---|
| 1 | **Polish** | Add "New" label next to the chevron button | Improves discoverability for new users |
| 2 | **Polish** | Consider `easeOut` instead of `easeInOut` for "Jump to latest" animation | Feels more natural — fast start, gentle stop |
| 3 | **Future** | Per-topic scroll state preservation | Not needed now, but if users report losing their place on topic switch, this would address it |
| 4 | **Defensive** | The 150ms debounce is fine. If feedback loops persist, consider 200ms | Not a user-facing concern |

### What I'd verify in testing

- [ ] Send message while at bottom → no white space, smooth pin to bottom
- [ ] Send message, scroll up slightly before response starts → no forced yank, "Jump to latest" appears
- [ ] Two topics streaming simultaneously → switching between them always shows latest content at bottom
- [ ] Rapid message send (3 quick messages) → no scroll fighting, no bounce
- [ ] Streaming response growing for 30+ seconds → stays pinned, no drift
- [ ] "Jump to latest" button → works, smooth scroll to bottom, disappears after

---

*Mel — UX review complete. Fix is approved with polish items tracked for later.*