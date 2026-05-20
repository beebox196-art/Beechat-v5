# Adversarial Review — Scroll Bounce & Whitespace Remediation

**Reviewer:** Kieran  
**Date:** 2026-05-19  
**Spec:** `Docs/Specs/SCROLL-AND-WHITESPACE-REMEDIATION.md`  
**Files reviewed:** `MessageCanvas.swift`, `Composer.swift`, `MainWindow.swift`, `SyncBridgeObserver.swift`, `StreamingBubble.swift`  
**Verdict:** **APPROVE WITH CONDITIONS** (see conditions below)

---

## Executive Summary

The spec's core diagnosis is correct: we have too many programmatic `scrollToBottom` calls fighting `defaultScrollAnchor(.bottom)`, and the monolithic `SyncBridgeObserver` broadcasts cross-topic noise. The removal-first approach (Fix 1 + 2) is the right instinct.

However, the spec contains **one macOS 14 blind spot that would break the UX entirely if unaddressed**, several overstated claims about SwiftUI rendering behaviour, and an implementation order that could leave users in a degraded state between steps. The safeAreaInset proposal (Fix 7) is directionally correct but underspecified for macOS.

---

## Findings

### K1 — macOS 14 Has No Scroll Geometry Tracking, and the Spec Doesn't Acknowledge It

**Severity:** CRITICAL

`onScrollGeometryChangeCompat` is a **no-op on macOS 14**. The fallback is just `self`. This means:

- `isAtBottom` stays permanently `true` (its initial value)
- The "Jump to latest" button **never appears** — `isAtBottom ? 0 : 1` always evaluates to `0`
- On macOS 14, the user has **zero visibility** into whether new messages are arriving below the fold

After applying Fix 1 (removing `scrollToBottom` from `messages.count`), the **only** scroll-to-bottom triggers on macOS 14 become:
1. `onChange(of: topicId)` — fires on topic switch
2. `onAppear` — fires when the view appears

If the user scrolls up manually on macOS 14 (they can, even if the button is hidden), then scrolls back down by hand, they have no visual feedback that they're at the bottom. They're flying blind.

**What the spec should add:**
- A macOS 14-specific mitigation: either implement a fallback `onScrollGeometryChange` using `.background(GeometryReader)` + `.onPreferenceChange` on macOS 14, OR accept that the Jump button is macOS 15+ only but explicitly document this limitation.
- The current code already has the `WidthReader` GeometryReader inside the ScrollView — this *could* be repurposed for macOS 14 scroll tracking (it measures the ScrollView's frame, which gives you the container size). Combined with a custom scroll offset reader, you could rebuild `isAtBottom` on macOS 14.

**Why this is critical:** If we deploy Fix 1 + 2 without addressing this, macOS 14 users lose their only visual indicator of scroll position. Not a crash, but a significant UX regression that Adam would notice immediately.

---

### K2 — `defaultScrollAnchor(.bottom)` Behaviour with `LazyVStack` on macOS 14 Is Unproven

**Severity:** HIGH

The spec asserts that `defaultScrollAnchor(.bottom)` "already keeps the scroll pinned to the bottom when new content is added" and compares to Telegram/Discord. But:

1. **Telegram and Discord do NOT use pure SwiftUI for their scroll views.** They use AppKit `NSScrollView` wrappers or custom renderers. The comparison is misleading.
2. **`defaultScrollAnchor(.bottom)` with `LazyVStack` has known quirks** when items appear/disappear rapidly. On macOS 14 especially, the anchor only guarantees initial placement — it does **not** guarantee automatic scroll-following during content growth in all cases. The `.bottom` anchor is primarily about *initial offset* and *alignment when content fits*, not about *tracking new content*.
3. The spec doesn't specify whether `defaultScrollAnchor(.bottom)` on macOS 14 behaves the same as macOS 15. Apple's documentation is vague, and in practice, SwiftUI scroll behaviour has shifted significantly between these releases.

**What the spec should add:**
- Explicit testing matrix: verify `defaultScrollAnchor(.bottom)` behaviour on macOS 14 AND macOS 15 with: (a) empty → 1 message, (b) 10 messages → streaming growth, (c) content smaller than viewport, (d) content larger than viewport.
- A fallback plan: if `defaultScrollAnchor(.bottom)` doesn't reliably track on macOS 14, we need a programmatic scroll-to-bottom for the *first* message only (guarded by a "just appeared" flag), not the blanket removal proposed.

---

### K3 — Fix 4's TimelineView Claim Is Technically Wrong

**Severity:** MEDIUM

The spec claims the cursor `Text("▌")` animation "causes continuous view invalidation" and "triggers SwiftUI to reconsider layout." This is incorrect:

- `.opacity` is a **compositing-level property**. Changing opacity does **not** trigger a layout pass in SwiftUI. It triggers a rendering update, which is handled by the GPU compositor.
- The `.repeatForever(autoreverses: true)` animation on `cursorVisible` toggles opacity between 0 and 1. This is a **render-only** operation. No layout recalculation happens.
- `TimelineView` causes `body` to be recomputed on each tick. While `TimelineView` doesn't trigger *layout* invalidation, it **does** cause `body` recomputation. If the `body` contains heavy views, this can be worse than a compositing-only animation.

**The real culprit for scroll jitter during streaming is NOT the cursor animation** — it's the `streamingContent` string changing every 50ms, which forces the entire `Text(content)` view to re-layout because the text size changes as new characters are appended. The cursor is a red herring.

**Recommendation:** Keep the cursor animation as-is (it's correct and performant). Or, if you want to eliminate even the compositing overhead, use a simpler approach: `.opacity(0.5 + 0.5 * sin(Date.now.timeIntervalSinceReferenceDate * 3))` — no state, no animation transaction, no TimelineView. But this is a micro-optimisation. Fix 4 is solving a non-existent problem while the actual problem (content growth) is handled by Fix 1 + 2.

**Downgrade priority:** Fix 4 should be LOW or dropped entirely.

---

### K4 — Fix 3's Characterisation of WidthReader Is Inaccurate

**Severity:** LOW

The spec says `WidthReader` with `GeometryReader` is "placed inside the ScrollView as a background, causing it to participate in the scroll content's layout." This mischaracterises the code:

```swift
ScrollView(...) {
    LazyVStack { ... }
}
.background(
    WidthReader { width in ... }
)
```

The `.background()` modifier applies to the **ScrollView itself**, not to the LazyVStack content. The GeometryReader fills the ScrollView's frame, not the scroll content. It does not participate in the scroll content's layout at all.

That said, having a `GeometryReader` as a `.background()` on a `ScrollView` inside a `ZStack` inside a `VStack` inside a `NavigationSplitView` detail pane *can* cause layout quirks, just not for the reason the spec states. The real risk is that the GeometryReader proposes the ScrollView's *current* frame size, which might be incorrect during a layout pass triggered by the Composer expanding.

**Recommendation:** Fix 3 is still worth doing (outer GeometryReader is cleaner), but the rationale should be corrected. The actual benefit is that an outer GeometryReader gives you the *container* size reliably, while an inner one gives you the *content* size (which changes during scrolling). For width measurement, container size is what we want.

---

### K5 — `safeAreaInset` with Dynamic Composer Height Will Be Janky on macOS

**Severity:** MEDIUM

Fix 7 proposes wrapping the Composer in `safeAreaInset(edge: .bottom)`. The Composer grows from 36px (single line) to 160px (max). On macOS, `safeAreaInset` with **dynamic height changes** is known to be problematic:

1. **Inset height changes are not animated by default.** When the Composer grows from one line to two, the scroll content area jumps immediately. This could actually *cause* the whitespace issue rather than fix it.
2. **The Divider positioning.** The spec puts the Divider inside the safeAreaInset closure. This means the Divider moves with the Composer. Visually this is correct, but it means the Divider is part of the inset view, and its presence adds 1px to the inset height calculation, which SwiftUI might measure differently on different macOS versions.
3. **NavigationSplitView interaction.** The detail pane's safe area is already constrained by the NavigationSplitView layout. Adding a dynamic safeAreaInset on top of this creates a layout dependency chain: Composer height → safeAreaInset height → MessageCanvas inset height → ScrollView content size → scroll position. Any timing mismatch in this chain causes the whitespace.

**What the spec should add:**
- Wrap the safeAreaInset content in `animation(.easeInOut(duration: 0.15), value: composerHeight)` to ensure the inset height change is animated alongside the Composer growth.
- OR, use a fixed-height safeAreaInset (160px max) and let the Composer float within it. This trades 124px of unused space for layout stability.
- Explicitly test: type a multi-line message, watch for scroll position jumps.

---

### K6 — The `pendingTopicScroll` Flag Is a Race Condition Waiting to Happen

**Severity:** MEDIUM

The current code:
```swift
.onChange(of: topicId) { _, newId in
    if newId != nil {
        isAtBottom = true
        if messages.isEmpty {
            pendingTopicScroll = true
        } else {
            scrollToBottom(proxy: proxy, animated: true)
        }
    }
}

.onChange(of: messages.count) { _, _ in
    // ...
    } else if pendingTopicScroll {
        pendingTopicScroll = false
        scrollToBottom(proxy: proxy, animated: true)
    }
    // ...
}
```

The race:
1. User switches to Topic B (empty) → `pendingTopicScroll = true`
2. Gateway sends the first message for Topic B → `messages.count` changes
3. `pendingTopicScroll` is cleared and `scrollToBottom` fires

But what if:
- The user switches to Topic B, and `messages` is NOT empty (cached messages from a previous visit)? → `scrollToBottom` fires immediately in the `topicId` onChange. But the messages might still be loading from the database. The scroll might target a stale position.
- The user switches to Topic B (empty), but the first message arrives *before* the `topicId` onChange has fully processed? → Both `topicId` and `messages.count` onChange fire in the same runloop. The `topicId` onChange sets `pendingTopicScroll = true`, then `messages.count` onChange sees it and clears it. This works, but it's fragile.

**The spec doesn't address this at all.** If Fix 1 removes the `isAtBottom` branch from `messages.count`, the `pendingTopicScroll` path becomes the **only** automatic scroll mechanism for new topics with messages arriving. If it misfires, the user lands in the wrong position with no recovery (the Jump button might not appear if `isAtBottom` was already true).

**Recommendation:** Add a `lastTopicId` check to the `pendingTopicScroll` handler:
```swift
} else if pendingTopicScroll {
    pendingTopicScroll = false
    if topicId == lastTopicId {  // guard: only scroll if we're still on the same topic
        scrollToBottom(proxy: proxy, animated: true)
    }
}
```

---

### K7 — Fix 1 + Fix 2 Together Remove the Safety Net for "User Is at Bottom and Sends a Message"

**Severity:** HIGH

The spec's core assumption: "defaultScrollAnchor(.bottom) handles this automatically." But consider this sequence:

1. User is at the bottom of Topic A
2. User types a message in the Composer (it expands to 2 lines)
3. User sends the message
4. `messages.count` increases (user message appears)
5. `thinkingState` transitions to `.thinking`
6. Composer is still at 2 lines
7. Streaming content arrives, `streamingContent` changes every 50ms
8. LazyVStack content height is constantly changing

With Fix 1 + 2 applied:
- `messages.count` onChange: no scrollToBottom (removed)
- `thinkingState` onChange: no scrollToBottom (removed)
- `defaultScrollAnchor(.bottom)`: supposed to handle it

But `defaultScrollAnchor(.bottom)` is a **declarative anchor**, not a **reactive tracker**. When the content height changes faster than SwiftUI can reconcile layout (step 8), the anchor position can become stale. The ScrollView content offset might not update to match the new content bottom.

This is exactly the whitespace intrusion the user is seeing. The spec identifies it correctly but the proposed fix **relies on the very mechanism that might be causing it**.

**What the spec should add:**
- A conditional scroll-to-bottom that fires ONLY when: (a) the user was at the bottom before the message appeared, AND (b) at least 500ms have passed since the last scroll (to avoid the bounce during rapid streaming). This gives `defaultScrollAnchor` time to settle, then corrects if it didn't.
- OR, use `scrollPosition` (macOS 15+) with a binding that tracks the bottom, which is more reactive than `defaultScrollAnchor`.

---

### K8 — `onAppear` Always Scrolls to Bottom, Even If User Was Reading

**Severity:** LOW

The `onAppear` handler in MessageCanvas:
```swift
.onAppear {
    scrollProxy = proxy
    scrollToBottom(proxy: proxy, animated: true)
}
```

`NavigationSplitView` may cache and reuse the detail view. When the user switches back to a topic they were reading, `onAppear` fires and forces them to the bottom. They lose their reading position.

This is pre-existing, not introduced by the spec. But the spec's verification checklist says "Switching topics scrolls to bottom of new topic correctly" — which implies they want this behaviour. However, the checklist doesn't address: "Returning to a topic where the user was reading earlier messages — should we preserve position?"

**Recommendation:** Track whether the user manually scrolled up, and only scroll to bottom on `onAppear` if they didn't. Or, accept this as desired behaviour and document it.

---

### K9 — `isStreaming` Parameter Is Passed to MessageCanvas But Never Used

**Severity:** LOW

Looking at `MessageCanvas.swift`:
```swift
let isStreaming: Bool
// ...
// isStreaming is never read in the view body
```

Wait — actually it IS used:
```swift
} else if isStreaming && streamingContent.isEmpty {
```

So `isStreaming` is used for the typing indicator suppression. It's not dead code. But it's worth noting that the spec's Fix 5 ("per-topic thinkingState") doesn't mention `isStreaming`, which is also global-to-local. The spec should ensure `isStreaming` is also computed per-topic (it already is in `MainWindow.swift`, so this is fine, but it should be documented).

---

### K10 — No Network Disconnect / Reconnect Behaviour Addressed

**Severity:** MEDIUM

The spec doesn't mention what happens when:
1. Network disconnects during streaming → `streamingContent` stops updating → the streaming bubble freezes mid-sentence
2. Network reconnects → does streaming resume? Does `didStopStreaming` fire? Does `thinkingState` reset?
3. User sends a message during disconnection → `onMessageSent` fires → `thinkingState = .thinking` → but no streaming ever starts → the thinking indicator spins forever (mitigated by the 60s timeout, but that's 60 seconds of a stuck UI)

The `SyncBridgeObserver` has a `connectionState` property, and `MainWindow` observes it, but `MessageCanvas` doesn't. If the network drops, the user sees a frozen streaming bubble with no indication of what went wrong.

**Recommendation:** Pass `connectionState` to `MessageCanvas` and show a "Connection lost" indicator when disconnected during streaming. This is outside the scope of the current spec but should be noted as a follow-up.

---

### K11 — Fix 5's Per-Topic thinkingState Has a Transition Gap

**Severity:** MEDIUM

The proposed fix:
```swift
let topicThinkingState: ThinkingState = isActiveTopicStreaming
    ? syncBridgeObserver.thinkingState
    : .idle
```

The gap:
1. User sends a message
2. `onMessageSent` fires → `syncBridgeObserver.thinkingState = .thinking`
3. At this moment, `isActiveTopicStreaming` is **false** (streaming hasn't started yet)
4. So `topicThinkingState` evaluates to `.idle`
5. The `ThinkingBeeIndicator` does NOT appear
6. 1-3 seconds later, `didStartStreaming` fires → `thinkingState = .streaming` → `isActiveTopicStreaming = true` → `topicThinkingState = .streaming`
7. Now the streaming bubble appears

The user sees: send message → nothing happens for 1-3 seconds → streaming bubble appears. The "thinking bee" is skipped entirely.

This is a **regression** compared to current behaviour, where the global `thinkingState` transition to `.thinking` triggers the ThinkingBeeIndicator immediately.

**Fix:** The per-topic computation should also check the global `thinkingState`:
```swift
let topicThinkingState: ThinkingState = {
    if isActiveTopicStreaming {
        return syncBridgeObserver.thinkingState
    }
    // If not streaming but global thinking is active, show thinking for active topic
    if syncBridgeObserver.thinkingState == .thinking {
        return .thinking
    }
    return .idle
}()
```

---

### K12 — Spec's "What NOT To Do" Section Contradicts Itself

**Severity:** LOW

The spec says:
> "Don't add `scrollPosition` binding (iOS 18+/macOS 15+) as a 'fix'. It's useful for programmatic control, but the root cause here is too MUCH programmatic control, not too little."

But then the verification checklist says:
> "Messages appear smoothly without bouncing during streaming"

If `defaultScrollAnchor(.bottom)` doesn't deliver on this (and on macOS 14, it might not), then `scrollPosition` IS the right fix. The spec pre-emptively disqualifies a valid solution without evidence. This is dogma, not engineering.

**Recommendation:** Remove this prohibition from the spec. If testing shows `defaultScrollAnchor` isn't sufficient, `scrollPosition` is a legitimate fallback.

---

## Summary Table

| # | Finding | Severity | Fix |
|---|---------|----------|-----|
| K1 | macOS 14 has no scroll geometry tracking — Jump button invisible | **CRITICAL** | Add macOS 14 fallback or document limitation |
| K2 | `defaultScrollAnchor(.bottom)` with `LazyVStack` on macOS 14 is unproven | HIGH | Explicit testing matrix + fallback plan |
| K3 | TimelineView claim is technically wrong — opacity animation doesn't cause layout | MEDIUM | Downgrade Fix 4 to LOW or drop it |
| K4 | WidthReader mischaracterised — it's on ScrollView, not in content | LOW | Correct rationale (fix still valid) |
| K5 | `safeAreaInset` with dynamic Composer height will be janky on macOS | MEDIUM | Animate inset height changes or use fixed height |
| K6 | `pendingTopicScroll` is a race condition with topic switching | MEDIUM | Add `lastTopicId` guard |
| K7 | Removing ALL scroll-to-bottom removes safety net during content growth | HIGH | Add delayed corrective scroll (500ms guard) |
| K8 | `onAppear` always scrolls to bottom, losing reading position | LOW | Decide and document desired behaviour |
| K9 | `isStreaming` is per-topic but undocumented in Fix 5 | LOW | Document that it's already handled |
| K10 | No network disconnect behaviour addressed | MEDIUM | Note as follow-up, not blocking |
| K11 | Per-topic thinkingState skips the "thinking" indicator transition | MEDIUM | Add fallback for `.thinking` state |
| K12 | Spec pre-emptively disqualifies `scrollPosition` without evidence | LOW | Remove prohibition |

---

## Conditions for Approval

The spec is **APPROVED** subject to these conditions being addressed before implementation:

1. **K1 (CRITICAL):** The macOS 14 gap MUST be addressed. Either implement a fallback for `isAtBottom` tracking on macOS 14, or explicitly document that the Jump-to-latest button is macOS 15+ only and accept the UX trade-off. This is not optional — it's a known regressions vector.

2. **K7 (HIGH):** Fix 1 + 2 should not remove ALL programmatic scrolling. Add a **delayed corrective scroll** that fires 300-500ms after a `messages.count` increase, but ONLY if the user was at the bottom before the increase. This gives `defaultScrollAnchor` time to settle, then corrects if it failed. This is the safety net that prevents the user from being stranded.

3. **K11 (MEDIUM):** Fix 5 must include the `.thinking` state fallback to avoid the transition gap where the ThinkingBeeIndicator disappears between send and stream-start.

4. **K5 (MEDIUM):** If Fix 7 is implemented, the safeAreaInset height change must be animated. Test on macOS 14 and 15 specifically for Composer height changes causing scroll jumps.

5. **K2 (HIGH):** Create a testing matrix for `defaultScrollAnchor(.bottom)` behaviour on both macOS 14 and 15 before committing to the removal-first approach. If it doesn't reliably track on macOS 14, the fallback plan (conditional scroll) becomes mandatory.

---

## What I Agree With

- **Fix 1 + 2's core insight is correct.** We have too many `scrollToBottom` calls. Removing the redundant ones during streaming is the right move.
- **Fix 6 (reduce poll to 150ms)** is a no-brainer. 50ms is overkill for text streaming.
- **Fix 5's direction (per-topic state)** is correct. The global `thinkingState` is the source of cross-topic bounce.
- **The implementation order** (1+2 first, test, then 7, then 3-5, then 6) is sensible — it isolates changes and makes regression tracking possible.
- **The "What NOT To Do" principles** (no more programmatic scroll calls, no GeometryReader in scroll content, no more debouncing) are sound — except the `scrollPosition` prohibition.

---

## Final Note

The biggest risk here isn't any individual fix — it's the **combinatorial effect** of removing multiple safety nets simultaneously. Each `scrollToBottom` call exists because someone observed a broken state and added a fix. Removing them all at once assumes `defaultScrollAnchor(.bottom)` will fill the gap. On macOS 15, that's probably true. On macOS 14, it's unproven.

Test on macOS 14. Test with an empty topic. Test with rapid topic switching. Test with multi-line Composer input. Test with network disconnection. If all pass, ship it.
