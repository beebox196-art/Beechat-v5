# UX Review: BC5-SPEC-005 v3 — Jump to Latest Message

**Reviewer:** Mel  
**Date:** 2026-05-08  
**Spec:** BC5-SPEC-005 v3 (final, build-ready)  
**Source:** `MessageCanvas.swift` (current)

---

## 1. Current UX Flow — Will Anything Break?

I walked through every user action in BeeChat today against the proposed changes. Here's the verdict per flow:

| User Action | Today | After Spec | Breaks? |
|---|---|---|---|
| Open app → see latest messages | `onAppear` → `scrollToBottom` | Same, but now stored proxy + retry | No. Retry is additive safety. |
| Send a message | `onChange(of: messages.count)` → always scrolls | `isUserMessage` check → always scrolls | No. Correctly gated. |
| Receive assistant message (at bottom) | `onChange(of: messages.count)` → scrolls | `isAtBottom == true` → scrolls | No. |
| Receive assistant message (scrolled up) | Same — scrolls anyway (current bug: always scrolls) | `isAtBottom == false` → shows Jump button instead | **This is the intended fix.** |
| Streaming response (at bottom) | `onChange(isStreaming)` + `onChange(showStreamingBubble)` → scrolls | Same, always-scrolls | No. |
| Streaming response (scrolled up) | Same — scrolls anyway | Always-scrolls (by design) | No break, but see §2. |
| Load earlier messages | `anchorMessageId` logic → scroll to anchor | Untouched | No. |
| Switch topic | `messages.count` 0→N fires → `scrollToBottom` → no-op (bug) | New `onChange(of: topicId)` resets `isAtBottom = true`, then `messages.count` fires → scrolls | Fixed. |
| Scroll up manually | Nothing happens; new messages still auto-scroll (current behavior) | `isAtBottom` flips false, Jump button appears | No. |
| Scroll back to bottom | Nothing special | Hysteresis clears at <50px, button disappears | No. |

**Verdict: No current flows break.** The spec is additive — it adds detection and a button without removing working behaviour.

---

## 2. Streaming Always Auto-Scrolls — Is This the Right UX Call?

**The concern:** A user deliberately scrolls up during a long streaming response (e.g., to re-read an earlier paragraph). The spec forces auto-scroll on every streaming update, yanking them back to the bottom.

**My assessment:** This is a **real tension** but the spec's choice is defensible with one caveat.

**Why always-scroll during streaming is usually right:**
- In a chat app, the streaming response is the *primary thing happening right now*. Users who scroll up during streaming are usually glancing, not deep-reading.
- If streaming *doesn't* auto-scroll, the user gets stuck looking at a partial response with no clear signal that it's still growing below — that's worse.
- Every major chat app I can think of (ChatGPT, Claude, iMessage) auto-follows during streaming/active conversation.

**But the edge case is real:** A user reading a long response scrolls up to check a detail, and gets yanked back. This is annoying if the response is >1 screen.

**Recommendation:** Ship as-is (always-scroll during streaming), but add a subtle UX hint. If `isAtBottom == false` when streaming starts, briefly flash the Jump button or add a small "streaming ↓" indicator so the user understands *why* they got pulled back. This is a **nice-to-have, not a blocker** — it can be a follow-up.

**Verdict: Acceptable. Not a regression.**

---

## 3. Jump Button Thresholds (50px enter / 120px leave)

**Hysteresis is the right approach.** Without it, momentum scroll near the bottom causes the button to flicker on/off — ugly and distracting.

**50px enter threshold:** This is tight. On a typical Mac trackpad, a light flick can overshoot 50px and snap back. The user would need to be genuinely "at the bottom" for the button to disappear. This feels correct — you want the button gone only when you're truly at the latest content.

**120px leave threshold:** This means the button appears once you're ~120px (roughly 1-2 messages) above the bottom. This feels about right — you don't want the button popping up for tiny 20px bounces.

**Edge case — keyboard scrolling:** If a user holds ↓ arrow to scroll down, they might overshoot past the enter threshold and bounce back. Hysteresis handles this well — once `isAtBottom` is set to true, it stays true until 120px away.

**Edge case — window resize:** When the window resizes, the GeometryReader recalculates but the scroll position doesn't change relative to content. This could theoretically cause `isAtBottom` to flip if the visible area shifts. Low risk — the hysteresis buffer absorbs normal resize deltas.

**Verdict: Thresholds feel right. No changes needed.**

---

## 4. 200ms Retry — Noticeable "Stuck at Top"?

**The concern:** On topic switch, the first `scrollToBottom` attempt fires via `DispatchQueue.main.async` (next run loop). If `LazyVStack` hasn't rendered the bottom-anchor yet, it's a no-op. The retry fires 200ms later.

**Could the user see 200ms of "stuck at top"?**

In practice: **very unlikely to be perceptible.** 200ms is below the conscious perception threshold for "something is wrong" (that's ~300-500ms). The user also has the mental context switch of selecting a new topic — their attention isn't on the scroll position in that first 200ms.

**Worst case:** Very large conversation (hundreds of messages) where `LazyVStack` takes longer to render. Even then, the first attempt likely succeeds; the retry is a safety net, not the primary path.

**One minor concern:** The retry uses *no animation* (second `proxy.scrollTo` is unanimated), while the first attempt uses `withAnimation(.easeInOut(duration: 0.2))`. If the first attempt fails and the retry fires, the user sees an unanimated snap-to-bottom. This is fine — it's a fallback — but it could feel slightly jarring. Not a blocker.

**Verdict: 200ms is fine. No perceptible stuck moment.**

---

## 5. Accessibility Gaps

**What the spec gets right:**
- `.accessibilityLabel("Jump to latest message")` ✅
- `.accessibilityHint("Scrolls to the most recent message")` ✅
- `.buttonStyle(.plain)` avoids double-tap issues ✅

**Gaps:**

1. **Keyboard navigation to Jump button:** The button is overlaid with `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)`. This means there's a full-screen invisible tap target behind the visible circle. Keyboard Tab navigation should reach it, but VoiceOver users might be confused by the large hit area. Consider adding `.accessibilityElement(children: .ignore)` on the overlay container and making only the button itself the accessibility element. **Low severity — not a blocker.**

2. **Dynamic type / font scaling:** The Jump button is fixed at 36×36pt. This is fine for the icon, but at maximum accessibility font sizes, the button might feel small relative to the text. This is a very minor concern for an icon button. **Not a blocker.**

3. **VoiceOver announcement on new messages while scrolled up:** When new messages arrive and the user is scrolled up, there's no accessibility announcement that new content exists below. Consider adding an `.accessibilityAnnouncement` when `showJumpButton` becomes true. **Medium severity — recommend as follow-up.**

**Verdict: One medium-gap (missing announcement), rest is solid. Not a blocker for build.**

---

## 6. Future UX Problems (After a Week of Use)

1. **"Unread count" on Jump button:** After using this for a week, users will want to know *how many* messages they've missed, not just *that* they've missed some. Adding a badge count ("3 new") to the Jump button is a natural next step. **Plan for this in the component layout.**

2. **Streaming pull-back frustration:** As discussed in §2, the always-scroll-during-streaming will occasionally annoy users reading long responses. A future enhancement could track whether the user *actively scrolled* during streaming (vs. was already at bottom) and only auto-follow if at bottom. **Follow-up, not blocker.**

3. **Jump button overlap with messages:** The button sits bottom-trailing with 12px padding. If the last message is a long code block or wide image, the button could obscure content. Consider making the button semi-transparent on hover-inactive, or shifting it slightly when the input field is focused. **Very minor — watch for complaints.**

4. **Multiple rapid topic switches:** If the user rapidly switches between topics, `onChange(of: topicId)` fires multiple times, resetting `isAtBottom = true` each time. Combined with `onChange(of: messages.count)`, this could cause multiple scroll attempts on the same render cycle. SwiftUI should coalesce these, but it's worth a quick test with fast topic-switching. **Low risk.**

5. **`scrollProxy` state lifetime:** Storing `ScrollViewProxy` in `@State` is technically outside SwiftUI's designed lifecycle — proxy objects are meant to be used within the `ScrollViewReader` closure. If SwiftUI ever invalidates the proxy (e.g., on significant view tree changes), the stored reference could be stale. The retry mechanism partially mitigates this (it captures the proxy at call time), but this is worth watching. **Low risk — known SwiftUI pattern, widely used.**

---

## Summary

| Area | Verdict |
|---|---|
| Current flows preserved | ✅ All intact |
| Streaming auto-scroll | ✅ Acceptable (follow-up: streaming-aware scroll) |
| Hysteresis thresholds | ✅ 50/120px feels right |
| 200ms retry | ✅ Imperceptible |
| Accessibility | ✅ Good (one medium-gap: missing announcement) |
| Future problems | ⚠️ Minor — badge count, streaming pull-back, button overlap |

---

## GREEN LIGHT ✅

No UX regressions. All current flows are preserved or explicitly improved. The spec is well-thought-out with appropriate hysteresis, clear conditional scroll logic, and proper accessibility labels.

**Recommended follow-ups (post-build):**
1. Add `.accessibilityAnnouncement` when new messages arrive while scrolled up
2. Consider "N new" badge on Jump button
3. Optional: Track user scroll intent during streaming for smarter auto-follow