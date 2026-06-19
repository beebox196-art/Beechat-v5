# SPEC: Scroll Bounce & White Space Root Cause Remediation

**Date:** 2026-05-14 (v2 — post-team-review)
**Status:** Pending final team review

---

## Symptoms

1. **Scroll bounce:** When reading a long message scrolled to the bottom, the scrollbar and message window jitter/bounce.
2. **White space leap:** After sending a message, a large white space appears below the last visible content, forcing the user to scroll back up to see Bee's response.

---

## Root Causes (re-prioritised after team review)

### RC1 (HIGHEST IMPACT): `resetIndicator` view inserted ABOVE MessageCanvas causes layout shifts

**File:** `MainWindow.swift` (lines ~157–158)

```swift
resetIndicator    // ← conditionally rendered ABOVE the message canvas
MessageCanvas(...)
```

The `resetIndicator` is a `@ViewBuilder` that conditionally shows/hides between three states: `autoResetting`, `manualResetting`, and `showAutoResetToast`. Each transition adds or removes a ~24pt tall view above the message canvas, pushing the entire canvas down and then pulling it back up. This is the most visible cause of the "white space leap."

Even when no reset is happening, any state transition that briefly flips these booleans (e.g., the auto-reset toast appearing for 3 seconds) causes a visible layout shift that looks exactly like white space appearing.

**Team consensus:** This is the primary fix. The resetIndicator must become a non-layout overlay.

### RC2: Multiple `onChange` handlers all calling `scrollToBottom` during streaming

**File:** `MessageCanvas.swift` (lines 96–122)

Three separate `onChange` handlers all call `scrollToBottom`:

```swift
.onChange(of: messages.count) { ... scrollToBottom(proxy: proxy) }
.onChange(of: isStreaming) { ... scrollToBottom(proxy: proxy) }
.onChange(of: showStreamingBubble) { ... scrollToBottom(proxy: proxy) }
```

Each call triggers SwiftUI layout recalculation. Even with the 100ms debounce, the first call forces a premature layout pass, content height changes mid-pass, and the scroll overshoots → bounces back. The `isStreaming` handler fires before the streaming bubble has content, and the `showStreamingBubble` handler has fragile timing (it's a computed property).

**How Telegram/iMessage avoid this:** One scroll policy: "if at bottom, stay at bottom." No imperative `scrollTo` calls during streaming.

### RC3: `isAtBottom` detection via `onAppear`/`onDisappear` on a 4pt invisible view

**File:** `MessageCanvas.swift` (lines 86–88)

```swift
Color.clear
    .frame(height: 4)
    .id("bottom-anchor")
    .onAppear { isAtBottom = true }
    .onDisappear { isAtBottom = false }
```

In a `LazyVStack`, this 4pt view flickers in and out of the viewport during every layout shift, height change, and rapid scroll. Each flicker toggles `isAtBottom`, which controls whether `scrollToBottom` fires. This creates a feedback loop:

1. State changes → view height changes → `isAtBottom` flips
2. `onChange(of: messages.count)` fires → `scrollToBottom` runs (or doesn't)
3. Scroll position shifts → `onDisappear` fires → `isAtBottom = false`
4. Next state update → `scrollToBottom` doesn't run because `isAtBottom` is false
5. Content grows → white space appears at bottom

**Team consensus:** The `onAppear`/`onDisappear` approach is fundamentally broken for scroll position detection. Must be replaced with geometry-based detection.

### RC4: Animated scroll calls competing with `defaultScrollAnchor`

**File:** `MessageCanvas.swift` (line 101, lines 148–150, lines 194–195)

`withAnimation(.easeInOut(duration: 0.15–0.2))` on scroll calls creates overshoot. During layout recalculation, the animation curve competes with `defaultScrollAnchor(.bottom)`, causing visible bounce.

### RC5: `thinkingState` transitions add/remove views inside LazyVStack

**File:** `MessageCanvas.swift` (lines 74–86)

Transitions from `thinking` → `streaming` swap `ThinkingBeeIndicator` for `StreamingBubble` — different heights, causing `isAtBottom` to flip.

### Additional root causes identified by Kieran:

- **RC6: Composer resize** — multi-line typing shrinks the canvas, flipping `isAtBottom`
- **RC7: "Load earlier messages" button** — inserts ~40pt, pushes content down
- **RC8: MessageListObserver window jumps** — 25→50 message reflows cause massive LazyVStack churn
- **RC9: `showStreamingBubble` toggle** — persistence saves catching up to streaming content cause flicker

---

## Implementation Plan (priority order)

### Fix 1: Move `resetIndicator` to non-layout overlay (RC1)

**Current:** `resetIndicator` sits inline above `MessageCanvas` in a VStack.
**Proposed:** Use `ZStack(alignment: .top)` so it floats over messages without affecting canvas height.

```swift
// BEFORE (MainWindow.swift, detail area):
resetIndicator
MessageCanvas(...)

// AFTER:
ZStack(alignment: .top) {
    MessageCanvas(...)
    resetIndicator  // floats above, no layout shift
}
```

**Styling:** Add `.ultraThinMaterial` or semi-opaque background to the indicator views so text remains readable over message content. The `.transition(.opacity)` is fine in a ZStack — it will fade in/out without layout shift.

**Files changed:** `MainWindow.swift` (detail area layout, ~lines 155–170)

### Fix 2: Replace `isAtBottom` tracking with geometry-based detection (RC3)

**Current:** `onAppear`/`onDisappear` on a 4pt `Color.clear` view.
**Proposed:** Use `onScrollGeometryChange` (macOS 15+) with a 24pt threshold.

⚠️ **Deployment target consideration:** The current `Package.swift` sets `.macOS(.v14)`. `onScrollGeometryChange` requires macOS 15+. Since BeeChat is a Mac-only app and macOS 15 has been available since September 2024, we have two options:

**Option A (Recommended):** Bump deployment target to `.macOS(.v15)` in `Package.swift`. This gives us `onScrollGeometryChange` natively. BeeChat is Mac-only, not shipping to App Store, and Adam's machine runs macOS 26.

**Option B (Fallback):** Keep `.macOS(.v14)` and use a `PreferenceKey` + `GeometryReader` inside the `ScrollView` that reads `contentOffset` and `contentSize` via a `GeometryReader` at the bottom of the content. This is more code but supports macOS 14.

```swift
// Option A — onScrollGeometryChange (macOS 15+)
// In the ScrollView, after .defaultScrollAnchor(.bottom):
.onScrollGeometryChange(for: Bool.self) { geo in
    let threshold: CGFloat = 24
    let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
    return distanceFromBottom < threshold
} action: { _, newValue in
    isAtBottom = newValue
}

// Option B — PreferenceKey fallback (macOS 14+)
// Add a GeometryReader at the bottom of the LazyVStack that writes
// the scroll offset via PreferenceKey, then compare in onChange
```

**Keep** the `bottom-anchor` `Color.clear` for `scrollTo` targeting, but remove the `onAppear`/`onDisappear` handlers. Increase its height from 4pt to 8pt for reliable `scrollTo` targeting.

**Decision needed:** Adam to confirm — bump to macOS 15 target, or use PreferenceKey fallback?

**Files changed:** `MessageCanvas.swift`

### Fix 3: Remove redundant `onChange` scroll handlers (RC2)

**Remove these handlers entirely:**

```swift
.onChange(of: isStreaming) { _, isNowStreaming in
    if isNowStreaming {
        scrollToBottom(proxy: proxy)
    }
}
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing {
        scrollToBottom(proxy: proxy)
    }
}
```

**Simplify `onChange(of: messages.count)`:**

```swift
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        // Animated scroll for "load earlier" anchor positioning
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(anchorId, anchor: .top)
        }
        anchorMessageId = nil
    } else if pendingTopicScroll {
        pendingTopicScroll = false
        scrollToBottom(proxy: proxy, animated: true)
    } else if isAtBottom || isUserMessage {
        // Instant — no animation for automatic scrolls
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```

Note: `isStreaming` removed from the condition. `defaultScrollAnchor(.bottom)` handles staying pinned during streaming content growth. If user scrolls up, `isAtBottom` becomes false and we stop auto-scrolling.

**Files changed:** `MessageCanvas.swift`

### Fix 4: Non-animated auto-scrolls (RC4)

**Change `scrollToBottom` to only animate for user-initiated scrolls:**

```swift
private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
    let now = Date()
    if now.timeIntervalSince(lastScrollTime) < 0.1 {
        return  // Debounce
    }
    lastScrollTime = now
    if animated {
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    } else {
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
}
```

Animated = true for: topic switch (`pendingTopicScroll`), jump-to-latest button, `onAppear`.
Animated = false for: automatic message arrival, streaming.

**Remove the existing `isStreaming` / `thinkingState` check** that was in `scrollToBottom` — it's no longer needed since we removed the handlers that called it during streaming.

**Files changed:** `MessageCanvas.swift`

---

## Deferred fixes (for future iteration)

These are real issues but lower priority — address only if the main fixes don't fully resolve symptoms:

- **RC6: Composer resize** — consider `keyboardLayoutGuide` or fixed-height composer during scroll
- **RC7: "Load earlier messages" button** — currently fine for infrequent use; monitor
- **RC8: MessageListObserver window jumps** — consider smoother window expansion (5 messages at a time instead of 25)
- **RC9: `showStreamingBubble` toggle** — will be partially addressed by Fix 3 (removing the `onChange` handler); remaining flicker from persistence saves is low-impact

---

## What NOT to do

- **Don't add more `onChange` handlers** — each one is a potential bounce trigger
- **Don't add more conditional views inside the scroll area** — each add/remove causes layout shifts
- **Don't increase the streaming poll rate** — it's already at 50ms, and reducing it would make streaming feel laggy
- **Don't add `.animation()` modifiers to the scroll content** — they propagate to all child views and make bounce worse
- **Don't use `onAppear`/`onDisappear` for scroll position detection** — it's fundamentally unreliable in `LazyVStack`

---

## Implementation Checklist

- [ ] Fix 1: `resetIndicator` → ZStack overlay with material background (`MainWindow.swift`)
- [ ] Fix 2: `isAtBottom` → `onScrollGeometryChange` with 24pt threshold (`MessageCanvas.swift`)
- [ ] Fix 3: Remove `onChange(of: isStreaming)` and `onChange(of: showStreamingBubble)` handlers (`MessageCanvas.swift`)
- [ ] Fix 3: Simplify `onChange(of: messages.count)` — remove `isStreaming` condition (`MessageCanvas.swift`)
- [ ] Fix 4: `scrollToBottom` — instant for automatic, animated only for user-initiated (`MessageCanvas.swift`)
- [ ] Fix 4: Remove `isStreaming`/`thinkingState` special case from `scrollToBottom`
- [ ] Keep `bottom-anchor` `Color.clear` for `scrollTo` targeting (remove `onAppear`/`onDisappear` only)
- [ ] Build passes
- [ ] Manual QA: send message → no white space leap
- [ ] Manual QA: long message → no bounce at bottom
- [ ] Manual QA: streaming response → stays pinned at bottom
- [ ] Manual QA: scroll up during streaming → no auto-yank back to bottom
- [ ] Manual QA: reset indicator appears → no layout shift in message area

---

## Review Sign-offs

- [x] Q: Implementation feasibility ✅ — found macOS 14 deployment target issue, recommended bumping to macOS 15
- [ ] Kieran: Failure mode analysis (timed out, partial review)
- [ ] Mel: UX impact (timed out, no output)
- [ ] Adam: Go/No-go + deployment target decision (Option A: macOS 15 or Option B: PreferenceKey fallback)