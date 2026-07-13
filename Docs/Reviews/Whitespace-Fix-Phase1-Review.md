# Adversarial Review — Whitespace Fix Phase 1 (Self-Healing Bottom Clamp)

**Reviewer:** Kieran
**Date:** 2026-07-13
**Subject:** `fix/scroll): self-healing bottom clamp for LazyVStack overshoot (Phase 1)` (commit `3b0ecb5`)
**Spec:** `Docs/Whitespace-Fix-Phase1-Spec.md`
**Phase 0 evidence:** build `0.9.5f-diag` (2026.07.13-5)
**Method:** doubt-driven-development; adversarial, evidence-first; no rubber-stamp

---

## VERDICT: **REQUEST CHANGES**

The implementation faithfully translates the spec, but the spec itself encodes a frame-count debounce that — when paired with the existing `macOS15JumpAction`'s 0.2s `withAnimation` — produces a **layout loop that defeats the debounce**. One critical fix and one missing verification path block merge. The non-loop findings are well-scoped and small.

---

## Findings

### F1 — Animation re-trigger loop (Critical)

**Severity:** Critical
**File:** `Sources/App/UI/Components/MessageCanvas.swift`, lines 165–180 (clamp block) + `MacOS15ScrollPositionChrome` (lines 320–333).

**Description:**

The clamp fires `macOS15JumpAction?.perform()` once `strandedFrameCount >= 2`, then resets the counter to 0. But the chrome's `MacOS15JumpAction` body is:

```swift
withAnimation(.easeInOut(duration: 0.2)) {
    var current = binding.wrappedValue
    current.scrollTo(edge: .bottom)
    binding.wrappedValue = current
}
```

This 0.2s `withAnimation` interpolates the scroll view from `contentOffset = (stranded, +)` toward `.bottom`. **During that 0.2s the geometry action closure keeps firing**, with `distanceFromBottom` slowly easing from ≈ −4029 toward 0. While it is still < −8 and `isAtBottom` is still true, the clamp logic re-arms the counter:

- Frame N: clamp fires, counter reset to 0, `withAnimation` starts.
- Frame N+1: `distanceFromBottom` ≈ −4000 (easeInOut barely moves in 1 frame at 200ms). Counter → 1.
- Frame N+2: ≈ −3950. Counter → 2. **Clamp fires again.**
- Frame N+2's `withAnimation` nests inside the in-flight one. SwiftUI cancels and replaces the in-flight animation. The new animation interpolates from the *current* (~−3950) toward `.bottom`. With easeInOut it barely moves in 1 frame; pattern repeats.
- Net: the clamp fires roughly once per 2 frames for the full 0.2s of the animation, then a few more times as the post-animation geometry settles. **Worst case ≈ 6–10 fires per stranded event**, plus the writes it spawns to the chrome's `ScrollPosition` binding.

**Why this matters:**

1. **The "once per topic entry" guarantee (AC6) is broken.** A single stranding event produces a burst of jump-action calls, not one.
2. **The animation never actually interpolates** (it's reset every 2 frames), so the user sees a snap — *which is fine visually* — but the binding is being written 6–10 times for one logical event. Wasted work, risk of unexpected side-effects.
3. **Worst case during content settling:** if `contentSize` continues to shrink as the animation is being re-anchored, the *new* `distanceFromBottom` may briefly read very negative *after* the animation, re-arming the clamp again. **A genuine layout loop** (re-anchor → re-render → re-anchor) is possible for a topic that has multiple waves of LazyVStack estimation, e.g. very tall WebView bubbles mounting in sequence after the initial flood. Not confirmed in logs but not ruled out either.
4. **The Fable review explicitly recommended "with animations disabled"** (§5, recommended-fix-strategy, primary candidate). The spec dropped that recommendation, and the implementation inherits the gap. The debounce frame-count and the `withAnimation` duration were not cross-checked during spec drafting.

**Evidence alignment:** Phase 0 logs show `distanceFromBottom` reaching −4988 during the M1 shrink (Spec §0, critical sequence step 4). The shrink itself takes 2–3 frames (Spec §0 step 2: `16,470 → 13,743 → 9,699 → 8,740 → 8,030`). If those 2–3 frames happen to coincide with a clamp-induced animation, the post-clamp geometry read will *still* be deeply negative — and the loop restarts.

**Suggested fix (smallest safe, in scope):**

Pick **one** of the following, all in `MessageCanvas.swift`:

- **Option A (preferred — minimal change):** In the clamp's "fire" branch, instead of `strandedFrameCount = 0`, set it to a large negative sentinel or use a separate `lastClampFrame: Int?` cooldown. Cooldown: do not re-arm the clamp until the geometry callback reports `distanceFromBottom >= 0` (or > `enterBottomThreshold`). This guarantees the animation completes (or is interrupted) before a second fire is even possible. ~5 lines.

- **Option B:** Increase the threshold from `>= 2` to `>= 30` (≈ 500ms at 60fps, well past the 0.2s animation duration). Crude but correct. ~1 line.

- **Option C (cleanest but cross-cuts chrome):** Add a `disablesAnimations: Bool` parameter to `MacOS15JumpAction` and a `silentJumpAction` environment value; the clamp calls the silent one. This also serves future programmatic-scroll use-cases. Out of Phase 1 scope; file a follow-up.

**Recommended:** Option A. Keeps the spec's surface area intact and stays within MessageCanvas. Add a comment cross-referencing Fable's "with animations disabled" recommendation so the next reviewer sees why the cooldown exists.

**Verification:** After fix, re-run the Phase 0 capture (`log stream --level debug --predicate ...`). Confirm exactly one `clamp fired` log line per topic entry, and confirm the scroll lands at the bottom in ≤ 1 frame after the log line.

---

### F2 — No verification path for the clamp's behaviour (Major)

**Severity:** Major
**File:** `Sources/App/UI/Components/MessageCanvas.swift`, lines 162–180 (no log call) + `Sources/App/Rendering/MessageWebView.swift`, line 186 (revert of `dir=` field).

**Description:**

Phase 0 captured ACCEPT/REJECT lines and `dir=` (shrink/grow) discriminator via `Logger.debug`. The Phase 1 implementation:

1. Removed all `Logger` calls from the clamp block (the diagnostic `Logger(subsystem:...category:"ScrollGeometry")` was deleted in the same commit).
2. Reverted the `dir=` field in `MessageWebView.swift`'s ACCEPT log (line 186).

**Consequences:**

- **AC6 ("Clamp fires at most once per topic entry") cannot be verified.** The spec marks it "optional diagnostic" but the only mechanism to verify the F1 fix is, in fact, log output. Fable's review §6 proof plan #7 explicitly says: *"After the fix: re-run 2–4; assert the clamp fires (add a `.info` log when it does, so it's visible in `log show`) at most once per topic entry and never during active scrolling."*
- The F1 fix above will be unverifiable without restoring at least one log line.
- The `dir=` revert is a clean revert to a debug-level line; that's defensible cleanup, but the *clamp* deserves a new `Logger.info` line to be visible in `log show` (debug is invisible there, per Fable §2d). Different log levels: that's why the Fable plan said "info" not "debug".

**Suggested fix:**

Add inside the clamp's fire branch (Option A from F1):

```swift
let logger = Logger(subsystem: "com.beebox.beechat", category: "ScrollGeometry")
logger.info("clamp FIRED distFromBottom=\(distanceFromBottom) strandedCount=\(strandedFrameCount)")
```

Optionally also add `logger.debug("clamp rearm skipped — cooldown active")` in the Option-A cooldown path. Keep `info` (not `debug`) so `log show` can see it.

The `dir=` revert on `MessageWebView.swift:186` is fine to keep — Phase 0 is complete and that field served its purpose. Do not re-add it.

**Acceptance:** AC6 verifiable from `log show --predicate 'subsystem == "com.beebox.beechat"'` after one General topic entry, expected exactly one `clamp FIRED` line in the 3s window.

---

### F3 — Debounce too short to skip bottom rubber-band on long content (Major)

**Severity:** Major
**File:** `Sources/App/UI/Components/MessageCanvas.swift`, line 168.

**Description:**

`scrollBounceBehaviorCompat(axes: .vertical)` uses `.basedOnSize` on macOS 15+, which permits bottom rubber-band on tall content. The spec's "2-frame debounce" assumes rubber-band is one or two frames. **That is true for a 60Hz flick on a short view, but not for a slow drag on tall content** — SwiftUI's overscroll animation can stretch to 6–10 frames in such cases. The debounce may not skip a deliberate slow drag, which is a legitimate user action. Result: the clamp fires mid-drag and the user's scroll snaps to the bottom.

This is the same concern Fable §3 Q6 flagged: "rubber-band overscroll, which a 2-frame debounce skips" — the *claim* is correct, the *debounce length* is not justified for slow drags.

**Worst-case impact:** During a slow scroll-to-top gesture on a tall topic, the user passes through bottom rubber-band and the clamp fires once. The scroll view snaps to the bottom, undoing the user's gesture. Minor inconvenience, not data loss, but contradictory to AC7 ("clamp never fires during active user scrolling").

**Suggested fix (in scope, with F1 Option A):**

Combine the F1 cooldown with a **longer re-arm threshold (e.g., 15 frames ≈ 250ms)** for the first fire, then the F1 cooldown for subsequent fires. Or: tie the re-arm to `distanceFromBottom >= 0` (i.e., we know we've been at-or-past the bottom at least once) rather than a frame count. The Option A cooldown naturally handles this: if rubber-band returns `distanceFromBottom` to 0 (which it does once released), the next sustained-negative event starts a fresh 2-frame count, but the slow-drag case where `distanceFromBottom` stays < −8 across many frames is filtered by the longer initial threshold.

Concretely: change `if strandedFrameCount >= 2` to `if strandedFrameCount >= 15` (still way under the 0.2s animation for the *first* fire). For subsequent fires, the F1 Option A cooldown handles it.

**Acceptance:** Manual test — slow drag from top of a long topic down past the bottom, hold rubber-band for 1 second, release. No clamp fire (log line from F2 is the verification).

---

### F4 — `distanceFromBottom` units and sign convention unstated (Minor)

**Severity:** Minor
**File:** `Sources/App/UI/Components/MessageCanvas.swift`, line 152.

**Description:**

The transform computes:

```swift
let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
```

The comment says "may be negative during overscroll", which is correct, but the sign convention is not documented. The clamp uses `distanceFromBottom < -8` — a reader has to derive that −8 means "viewport bottom is 8pt *past* the end of content". Worth a one-line comment in the clamp block explicitly stating the sign convention so the threshold values (−8, 50, 120) are interpretable in isolation.

**Suggested fix:** Add `// negative ⇒ viewport past content (overscroll / stranded). −8pt chosen to ignore sub-point FP jitter at content edge.`

**Acceptance:** Comment is present; threshold values are self-documenting.

---

### F5 — `strandedFrameCount` reset on `topicId` change is correct, but coupling to `onChange` is fragile (Nit)

**Severity:** Nit
**File:** `Sources/App/UI/Components/MessageCanvas.swift`, lines 213–219.

**Description:**

The reset is placed in `onChange(of: topicId)` inside the `ScrollViewReader`. This works for the current code path, but the `.id(topicId)` modifier sits on the inner `ScrollView`. The `onChange` is attached to the *outer* `ScrollViewReader`. If a future refactor moves the `.id` outside the `ScrollViewReader` (e.g., to `body` root for a different reason), the `onChange` and the rebuild split, and `strandedFrameCount` could leak across topics.

This is a *latent* fragility, not a current bug. Mention for future maintenance.

**Suggested fix:** Either move the reset to a `.task(id: topicId)` (which runs once per identity change in a well-defined point in the lifecycle) or add a `// brittle: depends on .id(topicId) being inside the onChange's view tree` comment. The latter is the smaller change.

---

### F6 — Spec accuracy on "2 consecutive frames" (Nit)

**Severity:** Nit
**File:** `Docs/Whitespace-Fix-Phase1-Spec.md`, §1, Change B (and §3, AC6).

**Description:**

The spec describes the debounce as "2 consecutive frames", which is what the code counts. But the actual unit is **"2 consecutive geometry callbacks"**, which in SwiftUI's `onScrollGeometryChange` corresponds to *distinct geometry values*, not frame-paint events. A geometry callback is rate-limited by SwiftUI's internal scheduler; in practice it can fire less often than the display refresh (e.g., on a static view it can be skipped entirely), so "2 frames" is technically a slight overstatement. The spec language is fine for readability but should not be relied upon for performance reasoning (e.g., "2 frames at 60Hz = 33ms" is wrong; it's "≤ 2 frames", could be more).

**Suggested fix:** Add a one-line clarification in the spec's Change B prose: "debounce in geometry callbacks (≤ 2 paint frames in practice; SwiftUI may coalesce)". No code change.

---

## What I did **not** find (notes for the validation pass)

These are explicitly checked and *not* issues, so the validator doesn't have to re-check them:

- **macOS 14 safety:** ✓ The clamp code is inside the `onScrollGeometryChangeCompat` action closure, which is a no-op on macOS 14. `macOS15JumpAction` is `nil` there. `strandedFrameCount` stays 0. `isAtBottom` stays `true`. No crash, no behaviour change vs. Phase 0. (Reviewed lines 298–319 of the compatibility shim.)
- **Topic switch reset:** ✓ `strandedFrameCount = 0` is set in `onChange(of: topicId)` (line 218). Even if the new view rebuilds before the `onChange` fires, the default `@State` value is 0.
- **Hysteresis interaction:** ✓ Hysteresis runs first, clamp runs second. Hysteresis can only set `isAtBottom` to `true` in the strand case (since `distanceFromBottom < −8 ≪ 50`). The clamp's `if isAtBottom` guard is correct.
- **Streaming interaction:** ✓ During streaming, `distanceFromBottom` stays near 0 (auto-anchored). Clamp doesn't fire. Streaming growth re-anchors via `defaultScrollAnchor(.bottom, for: .sizeChanges)`, not the clamp.
- **Jump button interaction:** ✓ The button is hidden when `isAtBottom = true`, which is the case when the clamp fires. So the user can't click the button during a clamp-induced jump — no double-fire.
- **Performance:** ✓ The clamp adds one int compare and one optional state write per geometry callback. Trivial. Geometry callbacks are coalesced by SwiftUI.
- **Diagnostic removal in MessageWebView.swift:** ✓ The single `dir=` line revert is exactly what the spec called for, and the rest of the diagnostic code was Phase 0-only.
- **`import os` removal:** ✓ Verified: no other `Logger` / `os` usage in `MessageCanvas.swift` after the diagnostic block was removed. `import os` removal is correct.
- **Spec / Fable review alignment:** ✓ All other spec changes match Fable §5 "primary candidate" recommendation (debounce on negative distance, `isAtBottom` gate, re-anchor via chrome). The one deviation is the missing "with animations disabled" qualifier, which is F1 above.

---

## Summary of required changes before merge

1. **(F1) Cooldown / longer initial debounce** — must fix; pick Option A (recommended) or B.
2. **(F2) Add a `Logger.info` "clamp FIRED" line** — must add; without it, AC6 and the F1 fix are unverifiable.
3. **(F3) Either increase the initial debounce to ≥ 15 frames, or rely on the F1 cooldown + sustained-zero reset** — recommended; otherwise AC7 has a slow-drag failure mode.

Nits (F4–F6) are non-blocking but cheap to address in the same commit.

The rest of the diff (`MessageWebView.swift` revert, the `import os` removal, the rest of the clamp block, the `onChange(of: topicId)` reset) is correct as-is. Re-review after the above three changes — should be clean.

---

*Adversarial review complete. — Kieran*
