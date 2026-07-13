# Whitespace Fix — Phase 1 Implementation Spec

**Author:** Bee
**Date:** 2026-07-13
**Status:** SPEC — pending implementation
**Branch target:** `fix/whitespace-phase1-clamp` from `fix/whitespace-phase0-diagnostics`
**Review:** Kieran (adversarial) → Bee (validation)

---

## 0. Phase 0 Evidence Summary

Diagnostic logs from build `0.9.5f-diag` (2026.07.13-5) confirm:

| Mechanism | Status | Evidence |
|-----------|--------|----------|
| M1 (LazyVStack estimation overshoot) | ✅ CONFIRMED | contentSize 16,470 → 8,030 (48% overshoot) during General topic entry |
| M2 (Stale-tall cache seeds) | ❌ NOT ACTIVE | All bcHeight shows dir=grow; no shrinks from seed |
| M3 (sizeChanges latch broken) | ❌ RULED OUT | sizeChanges re-anchor DOES fire (offset self-corrects in 2-3 frames) |
| M4 (Jump button invisible when stranded) | ✅ CONFIRMED | isAtBottom=true at distFromBottom=-4029 |

**Critical sequence** (repeats every General entry):
1. LazyVStack estimates content at ~16,470pt (wild overshoot)
2. contentSize corrects down: 16,470 → 13,743 → 9,699 → 8,740 → 8,030
3. During shrink, offset stays stuck at 12,776 while content collapses below it
4. distFromBottom goes massively negative (-4,029, then -4,988)
5. isAtBottom stays **true** (because -4,988 < 50 = enterBottomThreshold)
6. sizeChanges re-anchors after 2-3 frames, but user sees flash of whitespace

**Root cause:** LazyVStack estimation overshoot (M1) causes a brief but visible content shrink during topic entry. The hysteresis incorrectly classifies the stranded state as "at bottom" (M4).

**What sizeChanges re-anchoring does right:** It self-corrects within 2-3 frames. The fix is a clamp that accelerates this correction rather than waiting for SwiftUI's settle.

---

## 1. Changes

### File: `Sources/App/UI/Components/MessageCanvas.swift`

**Change A: Add stranded-state detection state**

Add two new `@State` properties to `MessageCanvas`:

```swift
/// Phase 1: Tracks consecutive frames where distFromBottom is deeply negative
/// while isAtBottom is true (stranded past content). Used by the self-healing
/// clamp to re-anchor without fighting the user.
@State private var strandedFrameCount: Int = 0
```

**Change B: Self-healing bottom clamp in the geometry action**

In the `onScrollGeometryChangeCompat` action closure, after the existing hysteresis logic, add the clamp:

```swift
// Phase 1: Self-healing bottom clamp.
// When distFromBottom is deeply negative AND we're classified as "at bottom",
// the viewport is stranded past the end of content (M1 overshoot correction).
// The user cannot legitimately dwell past content — the only transient cause
// is rubber-band overscroll, which a 2-frame debounce skips. Re-anchor to
// the true bottom via the chrome's ScrollPosition.scrollTo(edge: .bottom).
if distanceFromBottom < -8 {
    if isAtBottom {
        strandedFrameCount += 1
        if strandedFrameCount >= 2 {
            strandedFrameCount = 0
            macOS15JumpAction?.perform()
        }
    }
} else {
    strandedFrameCount = 0
}
```

**Change C: Reset stranded count on topic switch**

In the existing `onChange(of: topicId)` block, add:

```swift
strandedFrameCount = 0
```

**Change D: Remove Phase 0 diagnostic logging**

Remove all `NSLog` calls and `isTopicEntry`/`topicEntryTask` state added in Phase 0. Also remove the `GeometrySnapshot` struct if it still exists (it was removed in build v5, but confirm).

### File: `Sources/App/Rendering/MessageWebView.swift`

**Change E: Remove Phase 0 bcHeight direction logging**

Revert the `NSLog` line back to the original `Logger.debug` format (without `dir=`), since Phase 0 is complete and we have the evidence we need:

```swift
MessageWebView.logger.debug("bcHeight ACCEPT h=\(rounded) (was \(current)) w=\(w) gen=\(gen)")
```

---

## 2. Acceptance Criteria

| # | Criterion | How to verify |
|---|-----------|---------------|
| AC1 | General topic shows no bottom whitespace on entry | Launch app → tap General → no whitespace |
| AC2 | General topic shows no bottom whitespace on revisit | Visit another topic → return to General → no whitespace |
| AC3 | Other topics unaffected | Visit 3+ topics, verify correct bottom positioning |
| AC4 | Streaming still auto-scrolls | Stream a response, verify auto-scroll stays at bottom |
| AC5 | Window resize doesn't strand | Resize window while at bottom and while scrolled up |
| AC6 | Clamp fires at most once per topic entry | Check NSLog/console for clamp firing (optional diagnostic) |
| AC7 | Clamp never fires during active user scrolling | Scroll up → no clamp interference |

---

## 3. Risk Assessment

| Change | Could break | Blast radius | Rollback |
|--------|------------|--------------|----------|
| Self-healing clamp | Spurious re-anchor if threshold too low | MessageCanvas.swift, ~10 lines | Remove clamp, revert single commit |
| strandedFrameCount state | None (additive, resets on topic switch) | MessageCanvas.swift | Remove state, revert commit |
| Diagnostic removal | None (restoring original logging) | MessageWebView.swift | N/A (cleanup only) |

All changes confined to `MessageCanvas.swift` and `MessageWebView.swift`. No architecture changes. No new dependencies.

---

## 4. Not in Scope

- Phase 2 (jump button visibility fix) — deferred; clamp makes it moot for now
- Phase 3 (cache width-awareness) — M2 not active, no evidence needed
- §5 native Grid work (separate effort)
- VStack experiment (separate spike)
- Architecture changes to scroll positioning

---

## 5. Dev Sequence

1. **Bee** — Write this spec ✅
2. **Q** — Implement on branch `fix/whitespace-phase1-clamp`
3. **Kieran** — Adversarial review (doubt-driven-development)
4. **Bee** — Build, validate against AC1-AC7
5. **Merge** → `develop-v0.9.5d-whitespace`