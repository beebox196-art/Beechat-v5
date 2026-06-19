# Kieran Review: Scroll Bounce / White Space Spec — Adversarial Analysis

**Date:** 2026-05-14
**Reviewer:** Kieran
**Verdict:** ⚠️ **Partially sound. RC2 is almost certainly the primary cause; RC1 is a secondary contributor. Several proposed fixes have non-trivial regression risk.**

---

## 1. Root Cause Analysis — What's Missing / Wrong

### The Priority Order Is Wrong

The spec ranks **RC1 (onChange cascade)** as the top likelihood, then **RC2 (resetIndicator)**. Reading the actual code, I believe this is **backwards**.

**RC2 (resetIndicator) is the white-space culprit.** It sits directly in the detail VStack, above MessageCanvas. When `showAutoResetToast` flips to true, a ~24pt view appears above the canvas, pushing every message down. When it disappears 3s later, the canvas expands back up. This is a *visible layout shift* that looks exactly like "white space leaping into existence." Even the `autoResetting` and `manualResetting` states insert ProgressView + label views of different heights. The spec underweights this because it focuses on streaming-state transitions, but the reset indicator fires independently of streaming and has the most dramatic height impact.

**RC1 (onChange cascade) is real but mitigated.** The 100ms debounce in `scrollToBottom` means even if all three handlers fire in the same runloop, only the first call wins — subsequent calls within 100ms are dropped. This is working as designed. The spec says "each call triggers a layout recalculation," which is true, but the debounce *prevents* the cascade from becoming a bounce spiral. The real issue with RC1 is not the cascade itself — it's the **interaction between debounce timing and state transition ordering** (see Failure Mode 1 below).

### Missing Root Causes

**MRC1: ThinkingBeeIndicator ↔ StreamingBubble height swap (RC4 under-described).** The spec identifies RC4 but underestimates it. The `ThinkingBeeIndicator` and `StreamingBubble` have materially different heights. When `thinkingState` transitions from `.thinking` → `.streaming`, the indicator disappears and the bubble appears *in the same layout pass*. In a `LazyVStack` with `.defaultScrollAnchor(.bottom)`, this height delta changes where the bottom anchor sits relative to the visible region. If the bottom anchor was `onAppear`-ing (isAtBottom=true), the height change can push it off-screen, flipping `isAtBottom=false` mid-stream. This is a genuine feedback loop the spec describes but doesn't fully characterise the severity of.

**MRC2: "Load earlier messages" button insertion.** When `canLoadEarlier` becomes true, a ~40pt button is inserted at the top of the LazyVStack. This pushes all existing content down. In a bottom-anchored scroll view, this can fire `onDisappear` on the bottom-anchor, flipping `isAtBottom=false`. If this happens while streaming is active, the next `scrollToBottom` call may be skipped. The spec doesn't mention this at all.

**MRC3: Window boundary changes from MessageListObserver.** `MessageListObserver.setAllMessages()` calls `applyWindow()` which does `Array(allMessages.suffix(messageLimit))`. When the window slides (e.g., from 25 to 50 messages), 25 new views are inserted into the LazyVStack. This is a *massive* layout change that fires during the same runloop as streaming content updates. The bottom-anchor's `onAppear`/`onDisappear` will absolutely fire during this. The spec doesn't account for this interaction.

**MRC4: The `onChange(of: thinkingState)` handler is a red herring for bounce.** The spec lists `onChange(of: thinkingState)` alongside the other three, but looking at the actual code it only logs — it doesn't call `scrollToBottom`. It *does* trigger a body re-evaluation (because `thinkingState` changes the conditional views inside the LazyVStack), but it's not a scroll trigger. The spec's claim that "all three fire in quick succession" is accurate for the three that call scrollToBottom, but the thinkingState handler is orthogonal.

---

## 2. Failure Modes for Each Proposed Fix

### Fix 1: Remove `onChange(of: isStreaming)` and `onChange(of: showStreamingBubble)`

**🔴 HIGH REGRESSION RISK**

**Failure Mode 1 — Streaming content invisible on scroll start:**
Scenario: User sends a message. `messages.count` changes → `scrollToBottom` fires → debounce sets `lastScrollTime = now`. User scrolls up *before* streaming begins. `isStreaming` becomes true. `showStreamingBubble` becomes true (streamingContent has content). Under current code, `onChange(of: isStreaming)` would scroll to bottom. Under the fix, **only** `onChange(of: messages.count)` can trigger a scroll. But `messages.count` hasn't changed — only `streamingContent` has. **Result: streaming text appears off-screen and the user doesn't see Bee's response.**

The spec says `defaultScrollAnchor(.bottom)` handles this. It does **not**. `defaultScrollAnchor(.bottom)` positions the scroll view at the bottom when the view first appears. It does **not** keep the scroll anchored to the bottom when content *grows dynamically*. That's a common misconception. The anchor is a one-time positioning hint, not a persistent policy.

**Failure Mode 2 — Race between debounce and isUserMessage:**
The fix changes the condition to `isAtBottom || isUserMessage`. `isUserMessage` checks if `messages.last?.role == "user"`. This is a reasonable proxy for "user just sent something." But it creates an asymmetric policy: if the user sends a message, they're always scrolled to bottom (good). If the user is reading old messages and Bee sends a multi-part response (each part is a separate message with role "assistant"), subsequent assistant messages **won't auto-scroll** because `isUserMessage` is false and `isAtBottom` is false. This is arguably correct behavior, but it's a **behavioral change** from the current code which would scroll for any new message while streaming.

**Failure Mode 3 — The debounce protects against cascade but creates gaps:**
Current code's debounce means that within a 100ms window, only one `scrollToBottom` executes. This is *good* for preventing bounce. But if `onChange(of: isStreaming)` fires first and consumes the debounce window, then `onChange(of: messages.count)` fires 20ms later — it gets dropped. If the new message has important content, it scrolls off-screen. **Paradoxically, removing `onChange(of: isStreaming)` could make this BETTER** by letting `messages.count` be the sole scroll trigger. But only if `messages.count` reliably changes *after* streaming content appears, which it may not.

**Verdict on Fix 1:** The instinct is right (fewer scroll triggers = less bounce), but removing `onChange(of: isStreaming)` without a replacement policy for "keep user at bottom during streaming" is dangerous. The spec needs to propose a **single unified scroll policy** that handles all cases, not just delete handlers and hope `defaultScrollAnchor` picks up the slack.

---

### Fix 2: Move resetIndicator to overlay

**🟡 MODERATE REGRESSION RISK**

**Failure Mode 1 — Accessibility hit-testing:** Moving `resetIndicator` to `.overlay(alignment: .top)` means the progress indicator and text float over the message content. VoiceOver focus order changes — the overlay is read *after* the underlying content, not *before* it as it is now in the view hierarchy. If the reset indicator is conveying important state ("Refreshing context..."), users relying on VoiceOver may miss it until they navigate past the messages.

**Failure Mode 2 — Visual overlap with composer or first message:** An overlay at `.top` of MessageCanvas could overlap with the first visible message bubble. The current inline approach reserves space. The overlay approach does not. If the reset indicator is 24pt tall and the first message is near the top of the viewport, they'll overlap.

**Failure Mode 3 — Three-state overlay stacking:** The `resetIndicator` has three conditional states (`autoResetting`, `manualResetting`, `showAutoResetToast`). If these are all in a single overlay, only one shows at a time (correct, due to if/else if). But if they're in separate overlays (as the spec's pseudocode suggests with `if ... else if ... etc`), and there's a brief state transition where both are true, you get double overlays. The current inline code avoids this through mutually exclusive if/else if in a `@ViewBuilder`.

**Failure Mode 4 — Gesture interference:** Overlays in SwiftUI can intercept tap gestures. The `resetIndicator` currently sits in the view flow and doesn't capture touches outside its bounds. An overlay *might* create a larger hit-testing area depending on how it's configured, potentially intercepting taps on the top message bubble.

**Verdict on Fix 2:** This is the right instinct for eliminating the layout shift, but the implementation needs care. Use `.overlay(alignment: .top)` with a single container view that conditionally renders one state at a time (same if/else if pattern as current). Add `.allowsHitTesting(false)` to prevent gesture interference. And add top padding to the MessageCanvas content to prevent overlap with the first message.

---

### Fix 3: Stabilise isAtBottom tracking

**🟡 MODERATE REGRESSION RISK (interim fix) / 🟢 LOW RISK (ideal fix)**

**Failure Mode 1 — iOS 18+ `onScrollGeometryChange` is not backward compatible:** The spec mentions this as the ideal approach. BeeChat's minimum deployment target needs to be checked. If it's iOS 17 or earlier, this is a non-starter. The spec should confirm the deployment target before recommending this.

**Failure Mode 2 — The interim fix (4pt → 20pt anchor) is a band-aid, not a fix:** Increasing the anchor height from 4pt to 20pt creates a larger "bottom zone." The bottom-anchor is now a 20pt tall invisible view. Its `onAppear` fires when any part of it is visible, and `onDisappear` fires when it's fully off-screen. With a 20pt anchor, minor layout shifts are less likely to flip `isAtBottom`. But it doesn't solve the fundamental problem: the anchor's visibility is a **discrete boolean signal** for a **continuous scroll position**. No height makes it perfectly reliable.

**Failure Mode 3 — 20pt anchor affects scroll-to-bottom target:** `scrollToBottom` calls `proxy.scrollTo("bottom-anchor", anchor: .bottom)`. With a 20pt anchor, scrolling to its bottom puts the scroll position 20pt *below* where it was with a 4pt anchor. This creates a subtle but visible gap between the last visible message and the bottom of the viewport.

**Verdict on Fix 3:** The 20pt interim fix is pragmatic and worth trying, but it introduces a minor visual regression (gap at bottom). The spec should explicitly accept this tradeoff or propose a `safeAreaInset` approach that doesn't affect scroll positioning.

---

### Fix 4: Remove animation from non-user-initiated scrolls

**🟢 LOW REGRESSION RISK**

**Failure Mode 1 — Jarring snap-scroll:** Removing animation from automatic scrolls means new messages appear instantly at the bottom. For a user watching the conversation, this can feel jarring — text "teleports" rather than slides into view. The current 0.2s animation is short enough to feel smooth but long enough to feel intentional. Removing it entirely makes the app feel more mechanical.

**Failure Mode 2 — The code already handles this partially:** Looking at `scrollToBottom`, it already uses `withAnimation` only when `animated: Bool = true` AND `isStreaming` is false AND `thinkingState` is idle. The `onChange(of: messages.count)` handler calls `scrollToBottom(proxy: proxy)` which defaults to `animated: true`, but the function's internal logic already suppresses animation during streaming. The real question is: should `isUserMessage` scrolls be animated? The fix says "only animate for explicit user-initiated scrolls." But `isUserMessage` scrolls happen when the user sends a message — which IS user-initiated. So this fix is partially already implemented.

**Verdict on Fix 4:** Mostly already in place. The spec should clarify which specific scroll paths still use animation and whether they should be changed. The only remaining animated path is `onChange(of: topicId)` (topic switch) and `onAppear` (initial load), both of which should stay animated.

---

## 3. What The Spec Misses Entirely

### Composer Resizing
When the user types a multi-line message, the Composer view grows. This pushes the MessageCanvas up (they share a VStack with `spacing: 0`). If the user is scrolled to the bottom and the composer grows, the canvas shrinks — the bottom-anchor may go off-screen, `isAtBottom` flips to false, and then when the message is sent and the composer shrinks back, the canvas expands but `isAtBottom` is still false. The next streaming content update doesn't auto-scroll.

### LazyVStack Cell Recycling
`LazyVStack` recycles cells that scroll off-screen. When the user scrolls up to read old messages, cells below the viewport are deallocated. If new messages arrive while scrolled up, the LazyVStack may need to create new cells while simultaneously recycling old ones. This double-work during a streaming poll cycle can cause a layout pass that takes longer than usual, during which the scroll position is in an undefined state.

### The `showStreamingBubble` Logic Itself
The `showStreamingBubble` computed property checks if the streaming content differs from the last assistant message's content. This means:
- If the last assistant message is complete and matches `streamingContent`, `showStreamingBubble` is **false**
- If streaming content is ahead of the last saved message, `showStreamingBubble` is **true**

This creates a toggle: as `messages` are saved (by the persistence layer), the last assistant message content catches up to `streamingContent`, and `showStreamingBubble` flips from true to false. This flip triggers `onChange(of: showStreamingBubble)`, which calls `scrollToBottom`. The persistence save and the streaming poll are on different cycles, so this can create an additional scroll trigger that the spec doesn't account for.

---

## 4. Summary & Recommendations

### Priority Re-Ranking
1. **RC2 (resetIndicator layout shift)** — Move to overlay first. Highest impact on white-space symptom.
2. **RC4 (indicator height swap in LazyVStack)** — Stabilise the transition. Use `.transition(.opacity)` with `.drawingGroup()` to flatten the height change into a single layout pass.
3. **RC1 (onChange cascade)** — Consolidate to one handler, but **don't just delete handlers**. Replace with a unified policy.
4. **RC3 (withAnimation)** — Already partially handled by existing debounce + streaming guard. Low priority.
5. **RC5 (50ms poll)** — The diff guard is effective. Not a meaningful contributor to bounce.

### Before Implementing
1. **Add logging to measure actual scroll-call frequency.** Instrument `scrollToBottom` to log every call with its trigger source (messages.count, isStreaming, showStreamingBubble). Run a test conversation and count calls per message. This will tell you whether RC1 is actually a problem or just a theoretical one.
2. **Confirm iOS deployment target** before recommending `onScrollGeometryChange`.
3. **Test resetIndicator overlay with VoiceOver** to confirm accessibility isn't degraded.
4. **Check if composer resizing interacts with scroll state** — this could be a hidden contributor to the white-space bug.

### Spec Amendments Needed
- Fix 1: Add back `onChange(of: isStreaming)` but make it **set a flag** instead of calling `scrollToBottom` directly. The `messages.count` handler then checks this flag. This preserves the "keep at bottom during streaming" policy without creating competing scroll calls.
- Fix 2: Specify `.allowsHitTesting(false)` on the overlay and confirm no overlap with first message.
- Fix 3: Explicitly document the 20pt gap tradeoff and check deployment target.
- Fix 4: Already mostly implemented; clarify remaining animated paths.

---

*Review complete. No code changes recommended until priority re-ranking and spec amendments are agreed.*
