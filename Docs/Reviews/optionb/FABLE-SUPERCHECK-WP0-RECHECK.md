# WP-0 Feasibility Spike — External Super-Checker RE-CHECK

**Reviewer:** Fable (external, impartial)
**Date:** 2026-08-05
**Supersedes:** `FABLE-SUPERCHECK-WP0.md` (first pass — CORRECTIONS REQUIRED)
**Method:** Corrected evidence read from the working tree and git; `transcript.html` scroll engine and `main.swift` G2 harness read line-by-line; every claim checked against implementation

---

## VERDICT: PREMISE VALIDATED — proceed via Option A

**Part 1:** three of four corrections genuinely fixed, one honestly downgraded. E8 landed properly. Provenance fixed.

**Part 2:** **Option A.** The defect is narrow, real, and I have located it precisely — but **it is not the defect the team has diagnosed**, and the fix they propose would not resolve it. Three specific changes below, two in the engine and one in the harness. Roughly half a day, as estimated.

**Exit 1 would be the wrong call.** The failure is in ~20 lines of bespoke JavaScript that replaced a standard idiom, not in the architecture. And the corrected G2 has now delivered the evidence the programme actually needed: **100 assertions across streaming, late images, and live resize, all holding `dfb=0px` under a real pinned state with zero imperative pins.** That is the bug class being tested honestly for the first time, and passing.

---

## Part 1 — the four corrections

### C-2 — Scroll engine · **GENUINELY FIXED**

`transcript.html` now contains a real engine: `pinned` state (line 176), `userScrolledUp` (185), a scroll listener (214), `deferredRepin` with double-rAF settle (232–261), two `ResizeObserver`s on `document.documentElement` and `$transcript` (262–263), and `window.resize` (264). Image `load`/`error` hooks call `deferredRepin` (481–482). `appendMessage` sets no pin state — it relies purely on the observer, which is correct.

The route plan §4.4 mechanism exists. My decisive first-pass finding is resolved.

### C-3 — G2 re-run with manual pins removed · **GENUINELY FIXED (measurement), FAILS HONESTLY (engine)**

Verified against the harness source, not the write-up:

- **No imperative pins in the measurement phases.** `scheduleStreamAppends` appends and returns `null` (main.swift:843–850). `scheduleLateImages` injects only (890–893). Criterion 6 is accurate.
- **Criteria pre-registered and spike-emitted** before the run, 10 of them, and — this is the real improvement — **every one appears in the verdict table with an explicit ✅/❌**. Criteria 5 and 9 are marked ❌ and the gate FAILs on them. Nothing annotated "not gated."
- **The measurement race fix is sound.** `stateAfterRepin()` writes a JSON snapshot after two rAFs and a microtask, polled by Swift without a Promise in flight — a correct workaround for `evaluateJavaScript` serialising a top-level Promise to `[object Promise]`. Kieran's adjudication holds.

**This is the round where the team reported a FAIL that cost them something.** After my first pass criticised evidence that couldn't fail, this one does. That matters more than the result.

### C-5 — G3 real paste-verify · **GENUINELY FIXED**

The pasteboard was genuinely touched. `NSPasteboard.general` readback gives **plain 194 bytes, RTF 6205, HTML 5671** — three flavours, which is only possible if WebKit's real copy path ran; `Selection.toString()` cannot produce RTF. Durable artefacts committed (`G3-pasteboard-plain-*.txt`, `G3-textedit-consumer-*.txt`), content-in-order oracle retained and passing over the pasteboard text. FR-MULTICOPY A5 is now genuinely exercised.

**Residual (minor):** criterion 4 reads "TextEdit pasteboard read: 194 bytes." Identical byte count to the `NSPasteboard` read suggests this may re-read the pasteboard while TextEdit is open rather than reading TextEdit's document back. If so it is the same measurement twice, not a consumer-side verification. The A5 claim stands on the pasteboard readback regardless; worth one line of clarification at P6.

### C-6 — G4 reference screenshot · **PARTIALLY FIXED (honestly)**

`G4-reference-light.png` exists and is committed (115,742 bytes). But criteria 6 and 7 are marked **❌ — "side-by-side=MISSING production=MISSING … parity cannot be assessed."**

That is exactly what I asked for in the alternative branch of C-6: rather than a PASS resting on a missing file, the gate now records honestly that parity is unassessed. **Requirement:** G4's headline verdict must match its rows — it cannot read PASS while two of eight criteria are ❌. State it as *"fontScale swap PASS; visual parity NOT ASSESSED — blocked on production-template screenshot + Mel."*

### E8 audit · **ADOPTED AND WORKING**

Every gate now carries a verdict-logic table mapping each pre-registered criterion to an explicit evaluation, with a completeness check (G2: `expected=10 logged=10 missing=[]`). This is the rule doing its job: G4's missing parity artefact and G2's bounce failure are both surfaced by it rather than absorbed. Adopt permanently.

### Provenance · **FIXED**

Everything in `Docs/Reviews/optionb/` is committed and tracked — 31 files including `spike-run.log`, all six gate files, both prior-attempt artefacts, the attribution CSV and script, and the screenshot. The first pass's destroyed re-run log cannot recur for this material.

### E5 (implementer ≠ signer) · **REASSIGNED, NOT YET RESOLVED**

G3 moved to Adam, G5 to Kieran — the correct reassignment, and G5 documents the original violation openly. But **every gate still reads "(pending)"**. Zero gates are signed. That is now the single remaining process blocker, and it is scheduling, not engineering.

### Carried-over items

- **G1 attribution** — unchanged, still sound. My assessment stands.
- **22-min soak / +29 MB event** — no change visible in this round. Correction C-9 (plateau window matching the registered 600 s, and including WebContent RSS rather than app-only) is **still open**. Not blocking WP-2/WP-3; must not be quietly dropped.

---

## Part 2 — the G2 engine defect

### (b) first, because it changes everything: the branch *is* reached

The brief states the "respect user scroll-up" branch is *"never reached — likely a control-flow bug."* **That is not what is happening.** Line 199 executes on every scroll event and every repin. The branch is live. The defect is that its guard, `userScrolledUp`, is **false at every moment it is evaluated** — confirmed empirically: `userScrolledUp:false` appears in *every one* of the ~250 `engineDebug` records in the G2 evidence, including during the bounce probe.

A fix aimed at control flow would find nothing wrong and change nothing. Here is what is actually broken.

### Defect 1 — `engineScrollTop` is set to the wrong quantity (transcript.html:241, 247)

```js
engineScrollTop = $scroller.scrollHeight;   // ← should be scrollHeight - clientHeight
$scroller.scrollTop = engineScrollTop;      // browser clamps to scrollHeight - clientHeight
```

`scrollTop` is clamped by the browser to `scrollHeight − clientHeight`. So after every engine repin, `engineScrollTop` and the actual `scrollTop` differ by exactly `clientHeight` — **680 px in this run** (197743 − 197063).

The user-scroll detector compares them with a 2 px tolerance (line 222). So **every engine-initiated repin is misclassified as a user scroll.** The detector is inverted from its purpose: it fires when the engine scrolls, and its correctness for real user scrolls is incidental.

### Defect 2 — user intent has no persistence (transcript.html:203)

```js
if (d < 50) { pinned = true; userScrolledUp = false; }   // unconditional clear
```

Any time the viewport lands within 50 px of the bottom, the engine forgets the user ever scrolled up. Combined with Defect 1 — which sets `userScrolledUp = true` spuriously on every repin and then immediately clears it in the same handler when `d ≈ 0` — the flag oscillates true→false inside a single event and is reliably false whenever `deferredRepin` reads it.

That is the mechanism behind `engineHonouredScrollUp=false`. Two lines, both provable from the source.

### Defect 3 — the probe is contaminated (harness, not engine)

**The bounce probe runs concurrently with streaming.** It fires at t=11.5 s (main.swift:992); the 50 appends at 400 ms intervals run until t=20 s. During the probe's 12-frame (~200 ms) settle window, appends are still landing.

Worse: after every append the sampler calls `evaluateStateAfterRepin`, and `stateAfterRepin()` **itself calls `deferredRepin()`** (transcript.html:451). So the harness is issuing engine repins every 400 ms throughout the probe.

The evidence line reads *"(NO REPIN ISSUED — engine must auto-handle)."* That is true of the probe and **false of the harness.** The single assertion the entire gate now turns on is measured while another part of the same test is driving repins into the engine. This must be fixed before the re-run, or the re-run proves nothing either way.

### Defect 4 — a standard idiom was replaced by an invention, on a misdiagnosis

The engine's own comment (lines 180–184, 195–198) justifies abandoning the route plan's 50/120 hysteresis:

> *"that hysteresis is incompatible with high-rate streaming — each chunk pushes dfb past 120 in one frame, leaving the engine falsely unpinned."*

**This reasoning is wrong.** In the route plan design the repin happens inside the `ResizeObserver` callback, *before the frame paints*. While pinned, `dfb` never persists above 120 — the hysteresis reads `dfb` after the repin has already restored it, which is precisely what the 100 passing stream/image/resize assertions in this very run demonstrate (`dBefore` up to 10152, `dAfter` 0, every time).

So a well-understood idiom was discarded because of a misreading, replaced with a bespoke `scrollTop`-mismatch heuristic, and **the bespoke heuristic is the only part of the engine that fails.** This is a textbook instance of the directive Adam issued this week, and it is worth naming as such rather than as a mere bug.

### (a) Is the defect narrow? **Yes.**

Two one-line engine changes and one harness change, all in ~20 lines of a single file. The rest of the engine is demonstrably solid: 50 stream appends, 10 late images, 40 live resizes — 100/100 holding `dfb=0px` under a real pin with no imperative help. The architecture is not implicated. Nothing here suggests the pin model is unsound; it suggests one heuristic inside it was invented rather than adopted.

### (c) Is the criterion fair? **Yes — keep it, and treat it as P0-class.**

Auto-repinning over a user who has deliberately scrolled up is worse than the whitespace bug. Whitespace is confusing; being yanked away mid-sentence while reading history is the app fighting you. Every reference client — Slack, Teams, Telegram, Messages — holds position and surfaces a "new messages" affordance instead. This engine already *has* the jump-to-latest button for exactly that purpose (line 266–278); the bug is that it never gets the chance to matter.

The criterion is correct as written and should carry into P-series unchanged.

### (d) Recommendation: **Option A**, with this fix list

1. **`engineScrollTop = $scroller.scrollHeight - $scroller.clientHeight`** at both 241 and 247. Also raise the comparison tolerance from 2 px to ~4 px for sub-pixel/zoom rounding.
2. **Give user intent persistence.** Clear `userScrolledUp` only on an explicit re-pin action — jump-button click, `pinToBottom()`, `swapTopic()` — or when the *user's own* scroll brings them to the bottom. Never as a side effect of an engine repin. Practically: pass a flag distinguishing engine-driven from user-driven `_updatePinned` calls.
3. **Decontaminate the probe.** Run it after streaming completes (or suspend appends and the `stateAfterRepin` sampler for its duration) so no repin can be issued by anything but the engine.
4. **Then reconsider the hysteresis.** With 1 and 2 fixed, re-test whether the route plan's plain 50/120 hysteresis works — I expect it does, and the evidence in this run supports that. Prefer the standard idiom over the bespoke heuristic if both pass. This is also where **S1 (`flex-direction: column-reverse`)** from the prior-art register should be measured: it would make bottom-pinning the browser's default and shrink this entire state machine.

Re-run G2. If criteria 5 and 9 pass, the gate is clean.

---

## Deployment floor — changed since the last review (team please note)

Adam raised the deployment target on 2026-08-05: **`Package.swift` is now `.macOS(.v26)`** (`swift-tools-version: 6.2`; `swiftLanguageVersion` → `swiftLanguageMode` throughout). Verified empirically — `otool -l` on the built `BeeChatApp` reports `minos 26.0 / sdk 26.5`; `swift build` clean, `swift test` 380 tests 0 failures. `.iOS(.v17)` unchanged (decision D4 open); `Vendors/ChatField` unchanged at `.macOS(.v13)`.

Consequences for this programme:

- **P11 (macOS 14 parity run) is deleted** from the WP-4 matrix. There is one OS version to support.
- **Modern WebKit is now load-bearing-eligible** — no `@supports` fallback required for Safari 18–26 features. **S9 (`content-visibility: auto`) is unblocked** and promoted to a Tier 1 candidate in `option-b-prior-art-register.md`. Measure it together with S1, since `content-visibility` changes how the browser computes scroll height for off-screen nodes.
- The five `@available(macOS 15.0, *)` forks are now dead branches, left in place deliberately (all in files scheduled for WP-6 deletion and under review on the clamp branch; the compiler raises no warnings).
- **The discipline that survives:** "it's in the spec" still is not evidence WebKit implements it. Verify each feature empirically in the target WebKit before relying on it — S5 (`overflow-anchor`) remains the live example.

---

## Overall verdict

**SIGN-OFF ON THE PREMISE — proceed via Option A.**

The single-WebView transcript premise is now supported by real evidence for the first time: bounded memory with exactly one WebContent process (G1 re-run), and 100 honest pin assertions under async content growth with no imperative help (G2 stream/image/resize). Both of the expensive risks are retired.

**Gating condition:** the G2 re-run after fixes 1–3 must pass criteria 5 and 9 before WP-2 lands its scroll engine, because WP-2 ports this code. Everything else in WP-2 — DOM structure, CSS port, theme tokens, the `embed-template.swift` script, fixtures — proceeds in parallel now. WP-1 continues unaffected.

**Not blocking, but do not drop:** C-9 (G1 plateau window), G4's verdict wording, the G3 TextEdit clarification, and E5 signatures.

---

## Carry into WP-2/WP-3

1. **The corrected G2 harness is T1/T2.** Once fixes 1–3 land, that harness *is* the automated regression test for the bug class. Promote it to CI at WP-2 rather than rebuilding it later.
2. **Add a T-test for user-scroll-up persistence specifically.** This defect would have shipped undetected without the bounce probe; it needs a permanent guard.
3. **Keep the `engineDebug` ring buffer** in the production engine at `.info`. It is the best diagnostic instrument this project has produced — `dBefore`/`dAfter`/`pinned`/`userScrolledUp` per repin is exactly what six earlier rounds lacked.
4. **E9 declaration for the scroll engine.** Defect 4 is precisely what the proposed prior-art rule exists to catch: the spec named an idiom, the implementation replaced it, and no one recorded why until it broke.

---

## Confidence

**On Part 1: high.** Each correction was checked against source and committed artefacts, not write-ups.

**On the Part 2 diagnosis: high.** Defects 1 and 2 are provable by reading lines 199–248 against the clamping behaviour of `scrollTop`, and are corroborated by `userScrolledUp:false` in every recorded engine event. Defect 3 follows from the probe's schedule (t=11.5 s) against the append schedule (400 ms × 50) plus `stateAfterRepin` calling `deferredRepin`.

**On Option A over Exit 1: high.** The failing surface is one bespoke heuristic; the architecture-level claims both passed. Exit 1 would abandon a validated premise over a two-line state bug.

**One caveat, stated plainly:** I have not executed the fixed engine. My confidence that fixes 1–3 resolve criteria 5 and 9 is *moderate-to-high*, not certain — there may be a further ordering subtlety between scroll-event dispatch and `ResizeObserver` delivery that only the re-run will expose. That re-run is the evidence; this analysis is the hypothesis.

---

*Re-check complete. Verdict: premise validated, Option A, G2 re-run gates WP-2's scroll engine. — Fable, 2026-08-05*
