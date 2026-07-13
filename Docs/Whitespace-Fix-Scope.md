# Whitespace Fix — Scope Document

**Author:** Bee (scope, from Fable's review + code inspection)
**Date:** 2026-07-13
**Status:** SCOPE ONLY — no implementation yet
**Precedes:** Implementation plan (separate doc after evidence collection)

---

## 1. Confirmed Diagnosis

Fable's review validated the layer (scroll positioning, not measurement) and corrected the mechanism. My original "growth after anchor" story was geometrically wrong — growth leaves the user *above* content, not below it. The symptom (whitespace at bottom, scroll up to find messages) requires content to **shrink** after position was resolved, or the position to have been resolved against **transiently inflated** content.

### Mechanisms (all three are plausible; M3 is an amplifier)

**M1 — LazyVStack estimation overshoot (fresh-launch path).** ✅ Confirmed plausible.

On topic switch, `MessageListObserver.startObserving` resets `messages = []` synchronously (line 16), then GRDB delivers the 25-message window asynchronously. The scroll view mounts with only the 4pt bottom-anchor spacer. When messages arrive, `defaultScrollAnchor(.bottom, for: .sizeChanges)` re-anchors to bottom — but LazyVStack only materializes rows near the viewport and **estimates** rows above. General's window has extreme height variance (short 60pt native text alongside ~1200pt table WebViews). If estimated heights overshoot, `contentSize` starts inflated, the bottom anchor pins against the inflated size, and as rows above materialize at true (smaller) heights the content **shrinks** — stranding the viewport past the new end if `sizeChanges` re-anchoring doesn't self-correct.

Discriminator: reproduces on fresh launch (empty cache, M2 impossible).

**M2 — stale-tall cache seeds (revisit path).** ✅ Confirmed plausible.

`WebViewHeightCache.seed(id:)` (line 22–26) deliberately ignores width and fontScale. A height recorded at a narrower canvas (sidebar open, smaller window) is taller. On revisit at a wider canvas, every seeded bubble starts too tall, then honest `bcHeight` reports **shrink** it. The shrink is the designed correction — the stranding is not.

Code evidence:
- `MessageContent.init` seeds from cache: `_settledWebViewHeight = State(initialValue: WebViewHeightCache.shared.seed(id: message.id) ?? 40)` (line 26)
- `seed()` ignores width/fontScale: just returns `e.height` (line 23)
- `record()` stores width and fontScale but they're never used for validation on seed

Discriminator: reproduces only on revisits (not fresh launch). More pronounced after window resize between visits.

**M3 — chrome ScrollPosition reset may break `sizeChanges` re-anchoring.** ✅ Confirmed plausible as amplifier.

`MacOS15ScrollPositionChrome.onChange(of: topicId)` (line 317–319) writes `ScrollPosition(edge: .bottom)` against **empty content** (the fresh scroll view). Whether a scroll view with a programmatically-set `ScrollPosition` still honours `defaultScrollAnchor(.bottom, for: .sizeChanges)` re-anchoring is **undocumented** — Round 5 flagged exactly this interaction and the manual test (#1) was never run.

M3 alone doesn't produce the symptom (broken latch under pure growth strands at the *top*). It's the **amplifier**: if `sizeChanges` re-anchoring is broken, any late shrink (M1/M2) becomes permanent instead of self-healing.

**M4 — Jump-to-Latest button invisible when stranded (independent defect).** ✅ Confirmed.

`distanceFromBottom < 0` falls inside the `enterBottomThreshold` (< 50pt), so `isAtBottom = true`, hiding the button (line 157–159). The one control that would fix the state in one click is invisible precisely when needed.

```swift
// Line 156-159: hysteresis logic
if distanceFromBottom < enterBottomThreshold {
    if !isAtBottom { isAtBottom = true }
} else if distanceFromBottom > leaveBottomThreshold {
    if isAtBottom { isAtBottom = false }
}
```

**M5 — measuredWidth two-pass correction.** Low priority, direction-dependent.

`measuredWidth` seeds at 1200 (line 63). Bubbles first lay out at `maxWidth = 1200 × 0.66 = 792`, then correct to real canvas width. At Bee's observed geometry (canvas ~1150), the correction narrows bubbles → taller → **growth**, not shrink. But on a canvas wider than 1200, the correction is a transcript-wide **shrink**. Not primary but worth logging.

### Ruled out

- **Composer/safe-area inset (Q3):** Composer sits below the canvas in a plain `VStack` (MainWindow.swift:220–258). No overlap.
- **Cache key collisions (Q8):** Keys are message UUIDs. No cross-topic inheritance.
- **Paint-lag / blank tall bubble:** Last message in General is native text (plain, instant height). WebView bubbles are mid-window.

---

## 2. Files and Functions Requiring Changes

### Primary fix (self-healing clamp)

| File | Function/Section | Change |
|------|------------------|--------|
| `Sources/App/UI/Components/MessageCanvas.swift` | `onScrollGeometryChangeCompat` action closure (lines ~153–160) | Add negative-distance detection + debounce + re-anchor |
| `Sources/App/UI/Components/MessageCanvas.swift` | `isAtBottom` logic (lines ~156–160) | Extend to show jump button when `distanceFromBottom < -leaveThreshold` |

### Conditional second fix (cache width-awareness)

| File | Function/Section | Change |
|------|------------------|--------|
| `Sources/App/Rendering/WebViewHeightCache.swift` | `seed(id:)` (lines ~22–26) | Add width-tolerance check; reject seeds whose recorded width differs from current canvas width beyond tolerance; fall back to 40 |

### Diagnostic/logging additions (before fix, temporary)

| File | Function/Section | Change |
|------|------------------|--------|
| `Sources/App/Rendering/MessageWebView.swift` | `bcHeight ACCEPT` handler (line ~181) | Add direction indicator: log whether accepted height is a shrink or growth (compare to `current`) |
| `Sources/App/UI/Components/MessageCanvas.swift` | `onScrollGeometryChangeCompat` action | Add `Logger.info` for first ~3s after topic switch: `contentSize`, `contentOffset`, `containerSize`, `distanceFromBottom` |

---

## 3. Implementation Plan

### Phase 0 — Evidence collection (do this first)

**Goal:** Confirm which mechanisms are active in the real symptom before writing any fix code.

1. **bcHeight direction logging** — Modify the ACCEPT handler to log `(was → h)` with shrink/growth label. Capture via `log stream --level debug --predicate 'process == "BeeChat"'` during General entry repro. Count shrinks: any shrink from a large `was` confirms M2.

2. **Geometry probe** — In `onScrollGeometryChangeCompat`, log `contentSize.height`, `contentOffset.y`, `containerSize.height`, `distanceFromBottom` for ~3 seconds after topic switch (gate on a transient flag set by `onChange(of: topicId)`). This is the smoking gun: persistent negative `distanceFromBottom` = offset stranding confirmed; ≈0 with visible whitespace = phantom content.

3. **Fresh-launch vs revisit matrix** — Reproduce General entry:
   - Immediately after fresh launch (cache empty → M2 impossible)
   - After visiting General earlier in session (stale seeds possible)
   - After resizing window between visits (M2 amplified)
   Cross-reference with bcHeight direction logs to discriminate M1 vs M2.

4. **Latch test** — Toggle that skips the chrome's `onChange(of: topicId)` ScrollPosition reset (lines 317–319). If symptom disappears with the reset off, the programmatic write is breaking `sizeChanges` re-anchoring → M3 confirmed.

5. **Manual recovery test** — Debug menu item or keyboard shortcut invoking `macOS15JumpAction` while whitespace is visible. Instant correction validates that the clamp's mechanism works end-to-end.

### Phase 1 — Self-healing bottom clamp (~10 lines)

In `onScrollGeometryChangeCompat`'s action closure:

```swift
// Self-healing clamp: if viewport is stranded past the end of content,
// re-anchor to bottom. Cannot fight the user — a user cannot legitimately
// dwell past the end; the only transient negative is rubber-band overscroll,
// handled by the debounce requirement (two consecutive frames).
if distanceFromBottom < -8 && isAtBottom {
    // Two-frame debounce: confirm across consecutive geometry callbacks
    // to skip rubber-band overscroll and mid-settle transients.
    consecutiveStrandedCount += 1
    if consecutiveStrandedCount >= 2 {
        consecutiveStrandedCount = 0
        macOS15JumpAction?.perform()  // ScrollPosition.scrollTo(edge: .bottom)
    }
} else {
    consecutiveStrandedCount = 0
}
```

- Add `@State private var consecutiveStrandedCount: Int = 0` to `MessageCanvas`
- Reset `consecutiveStrandedCount` in `onChange(of: topicId)` (fresh start per topic)
- macOS 15+ only (same gate as the jump button). macOS 14 needs nothing new.
- The clamp fires at most once per topic entry; never during active scrolling (user scroll makes `isAtBottom = false`, resetting the count).

### Phase 2 — Jump button visibility fix (tiny)

In the jump button opacity logic, show the button when stranded past content:

```swift
// Show jump button when stranded past content (negative distance)
// in addition to the existing "scrolled up" condition
.opacity(isAtBottom && distanceFromBottom >= -leaveThreshold ? 0 : 1)
```

This requires `distanceFromBottom` to be accessible in the button overlay. Options:
- Lift it to a `@State` property (already computed in the geometry action)
- Or compute the button visibility inside the geometry action

**Note:** If the Phase 1 clamp works reliably, this becomes moot (the clamp heals before the user sees the button). Include it anyway as defence-in-depth — M4 is an independent defect regardless of the clamp.

### Phase 3 — Cache width-awareness (conditional)

Only implement if bcHeight direction logging (Phase 0 step 1) shows shrink-from-seed events.

In `WebViewHeightCache.seed(id:)`:

```swift
func seed(id: String, currentWidth: CGFloat, tolerance: CGFloat = 100) -> CGFloat? {
    lock.lock(); defer { lock.unlock() }
    guard let e = store[id],
          abs(e.width - currentWidth) <= tolerance else { return nil }
    return e.height
}
```

Callers pass `currentWidth` from the environment's `canvasWidth`. Mismatched seeds fall back to 40 and re-measure — deletes M2 at source.

### NOT now

- Re-litigating the chrome/anchor architecture
- §5 native Grid work (separate spec, shrinks WebView population long-term)
- VStack swap experiment (separate spike, needs perf data)

---

## 4. Acceptance Criteria

| Criterion | How to verify |
|-----------|---------------|
| General topic shows no bottom whitespace on fresh launch | Launch app → tap General → no whitespace |
| General topic shows no bottom whitespace on revisit | Visit another topic → return to General → no whitespace |
| General topic shows no bottom whitespace after window resize | Resize window while in General → no whitespace |
| Jump-to-Latest button appears when viewport is stranded | If whitespace does appear, button is visible and fixes it in one click |
| No scroll position regression on other topics | Visit 3+ different topics, verify correct bottom positioning |
| No scroll position regression during streaming | Stream a response, verify auto-scroll stays at bottom |
| No scroll position regression during window resize | Resize while at bottom and while scrolled up |
| Clamp fires at most once per topic entry | Check `.info` log — should see ≤1 clamp event per topic switch |
| Clamp never fires during active scrolling | Scroll up, verify no clamp log entries |

---

## 5. Proof/Logging Plan

### Before fix (Phase 0)

1. **bcHeight direction logging** — Add shrink/growth label to ACCEPT log line. Capture via `log stream --level debug --predicate 'process == "BeeChat"'` during repro.
2. **Geometry probe** — Log `contentSize.height`, `contentOffset.y`, `containerSize.height`, `distanceFromBottom` for first ~3s after topic switch. Gate on transient flag set in `onChange(of: topicId)`.
3. **Fresh-launch vs revisit matrix** — Cross-reference with direction logs to discriminate M1/M2.
4. **Latch test** — Skip chrome reset toggle. If symptom disappears → M3 confirmed.
5. **Manual recovery test** — Debug menu item invoking `macOS15JumpAction` while whitespace visible.

### After fix

6. **Clamp firing log** — `Logger.info` when clamp fires (visible in `log show` without debug level).
7. **Re-run steps 1–3** — Assert: clamp fires ≤1 time per topic entry, never during active scrolling. No persistent negative `distanceFromBottom`.

---

## 6. Risk Assessment

| Change | Could break | Blast radius | Rollback |
|--------|------------|--------------|----------|
| Self-healing clamp | Spurious re-anchor during normal scrolling if debounce too low | MessageCanvas.swift, ~5 lines | Remove clamp, revert single commit |
| Jump button visibility | Button appears too eagerly | MessageCanvas.swift, ~1 line | Revert visibility change |
| Cache width-awareness | Seeds rejected too aggressively → more cold-mount 40pt | WebViewHeightCache.swift, ~3 lines | Remove tolerance check |
| Diagnostic logging | Performance impact from debug logging | Temporary, removed before ship | Remove logging commits |

All changes are confined to `MessageCanvas.swift` and `WebViewHeightCache.swift`. No architecture changes. No new dependencies.

---

## 7. Landing Order

Phase 0 (evidence) → Phase 1 (clamp) → Phase 2 (button visibility) → Phase 3 (cache, conditional on Phase 0 results) → Remove diagnostics → Ship.

Each phase is independently shippable and testable.