# BC5-SPEC-005 v4 — Final UX Review (Mel)

**Reviewer:** Mel  
**Date:** 2026-05-08  
**Spec:** `jump-to-latest.md` v4  
**Source reviewed:** `MessageCanvas.swift`, `MainWindow.swift`, `Composer.swift`, `GatewayStatusBar.swift`

---

## 1. Current UX Flow Walkthrough

### Flow A: Open topic → messages load
**Current:** `onAppear` calls `scrollToBottom(proxy:)`. With animated scroll, this works if LazyVStack has rendered. If not (0→N on topic switch), the scroll is a no-op and user sees the top.  
**v4 fix:** Retry mechanism (next run loop + 200ms fallback). `scrollProxy` stored in `@State` for safe async capture. ✅ Fixes the root cause.

### Flow B: Send message while at bottom
**Current:** `onChange(of: messages.count)` always scrolls. Works.  
**v4 fix:** Gated on `isAtBottom || isUserMessage || isStreaming`. User-sent messages always scroll. ✅ Same behaviour, now explicit.

### Flow C: Scroll up to read older messages
**Current:** New messages arrive → auto-scrolls back down. **Bad UX** — user is reading, gets yanked away.  
**v4 fix:** `isAtBottom` is false → no auto-scroll. Jump button appears. ✅ This is the core fix and it's solid.

### Flow D: Streaming active
**Current:** `onChange(of: isStreaming)` and `onChange(of: showStreamingBubble)` always scroll.  
**v4 fix:** Unchanged — always scrolls regardless of `isAtBottom`. ✅ Correct. Users expect to follow a live stream.

### Flow E: Load earlier messages
**Current:** `anchorMessageId` is set to first message's ID before loading. After load, `onChange(of: messages.count)` scrolls to anchor.  
**v4 fix:** `anchorMessageId` path is untouched — runs before the `isAtBottom` check. ✅ No regression.

### Flow F: Topic switch
**Current:** `messages` array changes entirely. `onChange(of: messages.count)` fires and scrolls. But if the new topic has fewer messages, it might work — if more, the race condition kicks in.  
**v4 fix:** `onChange(of: topicId)` resets `isAtBottom = true`. Combined with retry, new topic starts at bottom reliably. ✅ Good.

### Flow G: Composer interaction (no messages yet, typing)
**Current:** Composer has no interaction with scroll state.  
**v4 fix:** No changes to Composer. Jump button is inside `MessageCanvas`'s ZStack, not overlapping Composer. ✅ No conflict.

---

## 2. Jump Button Placement Review

**Spec:** 36pt circle, `chevron.down`, `.ultraThinMaterial`, bottom-trailing, 12pt padding.

### Layout context
The detail pane layout (top to bottom):
1. `GatewayStatusBar` — ~20-24pt tall, full width
2. `Divider` — 1pt
3. `MessageCanvas` — flexible height (`.frame(maxHeight: .infinity)`)
4. `Divider` — 1pt
5. `Composer` — 36-160pt height, padded `.md` vertical, `.lg` horizontal

The Jump button is placed **inside MessageCanvas's ZStack**, aligned `.bottomTrailing` with 12pt bottom + 12pt trailing padding.

### Overlap analysis
- **Composer:** Below MessageCanvas, separated by a Divider. The button is *inside* MessageCanvas, so it won't overlap the Composer. ✅
- **Message bubbles:** The button floats over message content at the bottom-right. With 12pt margin from both edges, it won't clip into the safe area. On a standard macOS window, the rightmost message bubbles end well before 36+12pt from the edge (messages are padded within the scroll view). The button will occasionally overlap the tail of a short message near the bottom — this is expected and acceptable (it's a floating overlay, same pattern as iMessage/WhatsApp). ✅
- **Scroll indicators:** macOS scroll indicators appear on the trailing edge. The system indicator is ~8pt wide and semi-transparent. The Jump button at 12pt trailing padding will sit just inside the scroll indicator. This could look slightly awkward. **Minor concern** — see recommendation below.
- **"Load earlier messages" button:** At the top of the list. No conflict. ✅
- **ThinkingBeeIndicator / TypingIndicator / StreamingBubble:** These appear at the bottom of the LazyVStack, just above `bottom-anchor`. If the user is scrolled up, these are below the viewport — no overlap. If at bottom, the button isn't visible. ✅

### Scroll indicator overlap recommendation
Consider increasing trailing padding to **16pt** to avoid the button sitting directly on top of the macOS scroll indicator. This is a minor polish point, not a blocker.

---

## 3. Streaming Always Auto-Scrolls

The spec keeps `onChange(of: isStreaming)` and `onChange(of: showStreamingBubble)` as always-scroll, regardless of `isAtBottom`.

**Is this the right UX call?** Yes, strongly.

Reasoning:
- When Bee starts streaming a response, the user explicitly triggered it (they sent a message or the system is responding). The content is being generated *for them right now*. Not scrolling would mean the user sees nothing happening — they'd have to manually scroll down to find the new content, which feels broken.
- This matches every major chat app (iMessage, Slack, ChatGPT, WhatsApp all auto-scroll during streaming/typing).
- The one edge case: user scrolled up during streaming. But the spec's rationale is sound — streaming content is the active conversation. If the user cared about old messages more than the live response, they can scroll back up after the stream completes. The Jump button will reappear once they scroll up far enough.

✅ No change needed.

---

## 4. Hysteresis (50px enter / 120px leave)

### Will this feel right?

**Enter threshold (50px):** If the bottom-anchor is within 50px of the visible area, we consider the user "at bottom." This is tight enough that the user still sees the last message clearly. At typical macOS scroll speeds, 50px is roughly 1-2 lines of text. This feels correct — if you can see the last line, you're "at bottom." ✅

**Leave threshold (120px):** The button only appears once you're 120px+ away from the bottom. 120px is roughly 4-6 lines of text at typical font sizes. This means you need to scroll up meaningfully before the button appears. This prevents the button from flashing in and out during small scrolls or momentum bounces near the bottom. ✅

**Dead zone (50-120px):** Between thresholds, the state holds. This is the hysteresis core — it prevents flicker. SwiftUI's scroll momentum on macOS can cause small bounces; the 70px dead zone is generous enough to absorb these. ✅

**Concern:** The gap is asymmetric (50 enter vs 120 leave). This means:
- Scrolling down to the bottom: button disappears relatively quickly (within 50px)
- Scrolling up from bottom: button takes longer to appear (must go 120px)

This asymmetry is *good*. It matches user expectation:
- "I scrolled to the bottom, the button should go away fast" ← 50px enter
- "I scrolled up a tiny bit by accident, the button shouldn't flash" ← 120px leave

✅ The hysteresis values feel right. No change needed.

---

## 5. 200ms Retry for Topic Switch

**Spec:** `scrollToBottom()` uses `DispatchQueue.main.async` (next run loop) + `DispatchQueue.main.asyncAfter(deadline: .now() + 0.2)` fallback.

### Will users notice the delay?

**Topic switch scenario:** User clicks a new topic in sidebar → messages load → scroll fires.

The 200ms fallback is only needed if the first attempt (next run loop) fails because LazyVStack hasn't rendered yet. In most cases, the first attempt succeeds and the fallback is a no-op. When the fallback is needed, 200ms is fast enough that:
- The user is still processing the visual change of the topic switch (sidebar highlight, message list replacement)
- 200ms is below the threshold where a UI response feels "laggy" (Jakob Nielsen's 100ms for "instant" feedback, 200ms is at the upper edge of "feels responsive")
- The animated scroll (0.2s duration) masks any perceived delay

**Could 200ms be too short?** On very large topics (hundreds of messages), LazyVStack might not have rendered the bottom-anchor in 200ms. But this is the *fallback* — the primary attempt is the next run loop, which could be 16-32ms. If even 200ms isn't enough, the user would have seen the top of the list anyway (no regression from current behaviour). 

**Could 200ms be too long?** If the first attempt fails and the user starts reading the top of the message list within 200ms, the fallback will yank them to the bottom. This is unlikely (200ms is very fast) but possible. The spec acknowledges this as an accepted risk. I agree — it's acceptable.

**Recommendation:** Consider a third attempt at ~500ms for very large topics. But this is a premature optimization. Ship with the current retry, observe, and add if needed.

✅ No change needed.

---

## 6. Edge Cases

### Edge case A: Empty topic (no messages)
`messages.count` is 0. `bottom-anchor` exists but there's nothing to scroll to. `scrollToBottom` will be a no-op (already at bottom). `isAtBottom` starts `true`. Jump button won't appear. ✅ Correct.

### Edge case B: Single message
One message in the list. User can't scroll meaningfully. `isAtBottom` stays true. ✅ Correct.

### Edge case C: Rapid topic switching
User clicks Topic A → Topic B → Topic C quickly. Each switch fires `onChange(of: topicId)` resetting `isAtBottom = true` and triggering `scrollToBottom`. The retry mechanisms for each topic could interleave. However, since each `scrollToBottom` targets `"bottom-anchor"` (same ID across topics), the last one wins. The user ends up at the bottom of the last-selected topic. This is correct behaviour. ✅

### Edge case D: macOS window resize
Resizing the window changes the scroll position relative to the bottom. The GeometryReader + PreferenceKey will fire, and `isAtBottom` will update correctly based on the new bottom-anchor position. However, if the user was at the bottom and the window shrinks, they might now be slightly scrolled up (content is taller relative to viewport). The 50px enter threshold should handle this — if they were at the very bottom, they'll likely still be within 50px. If not, the Jump button appears, which is the correct signal. ✅

### Edge case E: "Load earlier messages" + scrolled up
User scrolls up → loads earlier messages → `anchorMessageId` preserves position. The `anchorMessageId` path runs before the `isAtBottom` check in `onChange(of: messages.count)`. This is correct — loading earlier messages should preserve scroll, and the Jump button should remain visible (user is still scrolled up). ✅

### Edge case F: VoiceOver / keyboard navigation
The Jump button has `.accessibilityLabel("Jump to latest message")` and `.accessibilityHint("Scrolls to the most recent message")`. This is good for VoiceOver. But there's no keyboard shortcut to trigger the Jump button. A power user who navigates by keyboard would need to Tab to the button. This is standard SwiftUI behaviour, but a keyboard shortcut (e.g., Cmd+Down or End key) would be a nice Phase 2 addition. Not blocking.

### Edge case G: Scroll proxy stale after view rebuild
Spec notes: `scrollTo` on stale proxy is a no-op, not a crash. `scrollProxy` is set in `onAppear`. If the view fully rebuilds, `onAppear` fires again and resets the proxy. If the view partially rebuilds (state changes), the proxy should still be valid (it's captured by reference from the ScrollViewReader closure). ✅ Acceptable.

### Edge case H: Button appears during animated scroll-to-bottom
User taps Jump → `scrollToBottom()` fires with animation → during the 0.2s animation, `isAtBottom` is set to `true` immediately (in the button action). The button disappears instantly, but the scroll animation continues. This creates a brief moment where the button is gone but the scroll hasn't finished. This is fine — the user initiated the action, they know what's happening. No visual glitch. ✅

### Edge case I: Composer auto-resize
Composer can grow from 36pt to 160pt as the user types multiline text. This pushes MessageCanvas up, changing its frame. The bottom-anchor's position in the scroll view's coordinate space changes, potentially triggering `onPreferenceChange`. If the user was at the bottom, the anchor should still be within 50px (the messages haven't moved, only the canvas height changed). If they were scrolled up, the state holds. ✅ No issue.

---

## 7. Accessibility Gaps

### What's covered ✅
- `.accessibilityLabel("Jump to latest message")` — clear, descriptive
- `.accessibilityHint("Scrolls to the most recent message")` — explains action
- `.buttonStyle(.plain)` — avoids double-tap issues on macOS

### What's missing ⚠️
1. **Dynamic Type / font scaling:** The button is fixed at 36pt × 36pt with a 14pt SF Symbol. At maximum Dynamic Type sizes on macOS (accessibility large), the chevron might look small inside the circle. However, macOS doesn't have the same aggressive Dynamic Type scaling as iOS, and the button is a floating action — not content. **Low severity.**

2. **Keyboard shortcut:** No keyboard equivalent for the Jump button. VoiceOver users can Tab to it, but a keyboard shortcut (End key, Cmd+↓) would be more efficient. **Recommendation for Phase 2.**

3. **High contrast / reduce motion:**
   - `.ultraThinMaterial` relies on translucency. In high-contrast mode, macOS increases opacity of materials. The button should still be visible but may look different. This is standard SwiftUI material behaviour and should work fine.
   - The scroll animation uses `.easeInOut(duration: 0.2)`. With `reduce motion` enabled, SwiftUI automatically reduces/removes animations. The `scrollTo` will still work (it'll just jump instead of animate). ✅ Correct.

4. **Focus management:** When the button appears, it doesn't steal focus. It's part of the view hierarchy and can be Tabbed to. ✅ Standard SwiftUI behaviour.

5. **Contrast ratio:** `.ultraThinMaterial` on a light background has good contrast for the dark chevron. On a dark theme, it might be slightly lower. The `themeManager` likely handles dark mode, but the button's `.ultraThinMaterial` + `chevron.down` (default color) should be verified visually in dark mode. **Recommendation:** Consider explicitly setting the chevron color to `themeManager.color(.textPrimary)` or `.primary` for better contrast across themes. Not blocking, but worth a visual check during build.

---

## Summary

| Check | Result |
|-------|--------|
| All current UX flows still work | ✅ Pass |
| Jump button doesn't overlap existing UI | ✅ Pass (minor scroll indicator proximity — increase trailing padding to 16pt recommended) |
| Streaming auto-scroll is the right call | ✅ Pass |
| Hysteresis feels right | ✅ Pass (asymmetric thresholds match user expectation) |
| 200ms retry won't feel delayed | ✅ Pass (below perception threshold) |
| Edge cases handled | ✅ Pass (8 edge cases reviewed, all correct) |
| Accessibility | ✅ Pass with minor recommendations (keyboard shortcut Phase 2, verify chevron contrast in dark mode) |

---

## Recommendations (non-blocking)

1. **Trailing padding 16pt** instead of 12pt — avoids scroll indicator overlap
2. **Chevron color:** Set explicitly (`.primary` or theme color) rather than relying on default, for dark mode contrast
3. **Keyboard shortcut:** Consider End key or Cmd+↓ for Jump in Phase 2
4. **Third retry at 500ms:** Consider if large topics (>200 messages) show the top-of-list bug in testing

---

# GREEN LIGHT ✅

Spec is build-ready. The UX is sound, edge cases are covered, and the hysteresis values are well-chosen. The non-blocking recommendations above are polish items for during or after build — none warrant holding the spec.