# WP-2 Transcript Document — Super-Checker RE-CHECK

**Reviewer:** Fable (external, impartial)
**Date:** 2026-08-06
**Branch:** `feat/transcript-document` @ `c0df445`
**Responds to:** `FABLE-SUPERCHECK-WP2.md` (REQUEST CHANGES — B-1, B-2, C-1, C-2)
**Method:** Both blockers re-verified by **running code**, not by reading the diff

---

## VERDICT: APPROVE WITH CONDITIONS — B2 may be signed; WP-3 may start

Both blockers are genuinely closed, and I verified them the same way I found them. Three small items remain; none blocks WP-3 from starting, and all should land before WP-3's first commit.

---

## B-1 — Scroll listener wiring · **FIXED, EMPIRICALLY VERIFIED**

`TranscriptTemplate.html:470` now reads `document.addEventListener('scroll', …)`. `$scroller` (`:417`) is retained for reading and writing scroll geometry, which is correct.

I re-ran the identical probe that produced the finding — real `window.scrollTo` and direct `scrollTop` assignment, **no `dispatchEvent` anywhere**:

| | Before (`08aa1c0`) | After (`c0df445`) |
|---|---|---|
| `document` hits | 2 | 2 |
| `window` hits | 2 | 2 |
| `scrollingElement` / `documentElement` hits | 0 | 0 |
| control `<div>` hits | 1 | 1 |
| **engine `userScrolledUp` after real scrolls** | **`false`** | **`true`** |

The event topology is unchanged — that was always a browser fact, not something to fix. What changed is that the engine now receives the event. **User-scroll-up protection works for a real user for the first time.**

### T2 is now a true regression guard — verified, not accepted on assertion

The commit message claims *"verified T2 FAILS with old wiring, PASSES with new."* I tested that claim by reverting the single line to `$scroller.addEventListener` and re-running:

```
TranscriptTemplateTests.swift:290: XCTAssertEqual failed: ("Optional(true)") is not equal to
    ("Optional(false)") - user scroll up must unpin (pinned=false)
TranscriptTemplateTests.swift:292: XCTAssertEqual failed: ("Optional(false)") is not equal to
    ("Optional(true)") - userScrolledUp flag must persist after explicit user scroll
```

T2 fails on exactly the right assertions with the old wiring and passes with the new. All synthetic dispatch is gone from `TranscriptTemplateTests.swift` (T2 at `:278`, T3 at `:353` both use real scrolls). Tree restored; suite green.

**This is the strongest gate evidence the programme has produced.** It is the first test here that has been shown to fail when the thing it guards is broken — which is what separates a regression guard from a passing assertion.

---

## B-2 — False hysteresis claim · **FIXED in the template, THREE STALE LINES REMAIN**

`TranscriptTemplate.html` (`:407`, `:423`) and the regenerated `.swift` now state correctly that the 50/120 hysteresis was **rejected** by the spike, citing `transcript.html:216-217`. `B2-evidence.md:62` carries an explicit, well-written correction note including a warning to WP-3. `--check` exits 0.

**Not yet closed —** `Tests/BeeChatAppTests/TranscriptTemplateTests.swift` still asserts the mechanism in three places:

- `:17` — *"T2 — pin hysteresis across scripted scrolls (50/120)"*
- `:28` — *"tolerances are constants in the test (50/120 px, …)"*
- `:250` — *"MARK: - T2 — pin hysteresis across scripted scrolls (50/120)"*

`:253` correctly explains the real mechanism, so the file now both asserts and denies it in the same header. This is the exact propagation vector I flagged, and the test file is what WP-3's author will read first. Three-line fix.

---

## C-1 — Fix 2 provenance · **IMPLEMENTED, with a residual worth one more line**

`_updatePinned(d, fromUser)` (`:443`) is the flag I recommended: the scroll listener passes `true` (`:479`), `deferredRepin` passes `false` (`:484`, `:490`). Engine repins and resize no longer discard user intent. That is the right shape.

**Residual — the middle branch still authorises the movement C-1 was meant to prevent:**

```js
} else if (d < 50) {
  // near bottom but not user-initiated — hold the pin flag but keep userScrolledUp
  if (!pinned) { lastPinTransition = performance.now(); }
  pinned = true;          // ← this authorises deferredRepin's `if (pinned)` repin
}
```

Concrete path: user scrolls up 60 px (`userScrolledUp=true`, `pinned=false`). Window grows 20 px taller — or a streaming bubble settles shorter — so `d` falls to 40. `deferredRepin` calls `_updatePinned(40, false)` → middle branch → `pinned = true` → **the engine repins them to the bottom.** The flag survives, but the user is still moved, which is the outcome C-1 exists to prevent.

Second-order: they now sit at the bottom with `userScrolledUp` still true, so the next content arrival unpins (`d ≥ 50`, not `fromUser`) and streaming stops following. The jump button does appear (`$jump.hidden = pinned` → false), so it is visible and recoverable — not silent stranding.

**Suggested fix (one line):** in the non-user branch, do not set `pinned = true`. Leaving `pinned` as-is means no repin is authorised and the user is not moved at all. The `fromUser` path still clears the flag when they genuinely scroll back into the bottom band.

Narrow trigger, visible affordance, no data loss — carry-forward, not a blocker.

---

## C-2 — `#scroller` DOM deviation · **DOCUMENTED, ACCEPTABLE**

Recorded as a known deviation from route plan `:154`, document-level scrolling accepted for B2, flagged for a WP-3 decision. That is the right disposition — it is now a decision rather than an omission.

---

## B-1a — G2 bounce probe · **RELEASING THIS, with a record**

`Experiments/.../main.swift:1074` still contains `scroller.dispatchEvent(new Event('scroll'))`. My original review listed a re-run as required; **I am withdrawing that.** The spike is throwaway code that never merges, and production T2 with real scrolls is strictly stronger evidence than re-running it could produce.

**But the provenance claim needs one sentence.** G2's bounce criterion was validated with synthetic input and is superseded by T2. `G2-evidence.md` has been corrected on the Fix-4 conclusion; add the supersession note so nobody later cites G2's bounce PASS as independent proof.

---

## Verified clean this round

| Check | Result |
|---|---|
| `swift test` | **396 / 0 / 0** |
| `embed-template.swift --check TranscriptTemplate` | exit 0 (in sync after regeneration) |
| Synthetic dispatch in production tests | none — T2/T3 use real scrolls |
| Working tree after my probing | clean (probe and stray `.bak` removed) |
| B-1 fix | empirically re-verified, before/after |
| T2 regression-guard property | empirically verified by reverting the fix |

---

## Conditions before WP-3's first commit (none block starting)

1. **B-2 residue** — three stale `50/120` lines in `TranscriptTemplateTests.swift` (`:17`, `:28`, `:250`).
2. **C-1 residue** — drop `pinned = true` from the non-user `d < 50` branch (one line), or document the behaviour honestly if kept deliberately.
3. **B-1a record** — one sentence in `G2-evidence.md` marking the bounce criterion superseded by T2.

---

## Separately outstanding — not WP-2's fault, but do not let these roll

- **G4 visual parity is still undischarged.** Mel signed G4 *with caveat*, explicitly deferring visual parity **to WP-2** (`E5-SIGNOFF-STATUS.md:16`): production-template screenshot plus full 8-theme side-by-side. WP-2's 8-theme tests assert *structure* (`loadedCount`, copy-button counts, roles) — not appearance. **The obligation has now been deferred twice.** It should be discharged here or explicitly re-assigned to WP-3 with Mel's agreement, not carried silently.
- **G5 (Kieran)** — still pending; the last open gate for full WP-0 closure.
- **C-9** — G1 plateau window (registered 600 s vs evaluated 120 s, app-RSS-only) still open from the WP-0 re-check.

---

## Confidence

**High on both blockers.** Each was verified by execution: B-1 by re-running the original probe and observing `false → true`, and the T2 guard by breaking the fix and watching the right assertions fail. Neither rests on reading a diff.

**High on the residuals** — all read directly from source at the cited lines.

**One thing I have not verified, and neither has anyone else:** how this looks. Every check in WP-2, mine included, is structural or behavioural. G4's parity caveat is the only mechanism that would have caught a visually broken transcript, and it is still deferred.

---

*Re-check complete. Verdict: APPROVE WITH CONDITIONS — B2 signable, WP-3 may start, three items before its first commit. — Fable, 2026-08-06*
