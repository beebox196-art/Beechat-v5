# Fable / Claude — External Super-Checker RE-CHECK: WP-0 Feasibility Spike (after CORRECTIONS REQUIRED)

**Prepared by:** Bee (2026-08-05)
**Purpose:** Independent external re-review of the WP-0 Feasibility Spike AFTER the correction round. Your first review (FABLE-SUPERCHECK-WP0.md) returned **CORRECTIONS REQUIRED**. Q has now made the corrections. Verify each is genuinely fixed — and that the gates now test what they assert — before the programme proceeds.
**How to use:** Adam copies this file into Claude (Fable) and shares the corrected evidence. Fable re-checks and either SIGNS OFF or returns further corrections. Manual process — no automation.

---

## What you flagged last time (the four corrections + provenance)

Your decisive finding: the spike's `transcript.html` had **no ResizeObserver, no scroll listener, no pinned state** — only an imperative `pinToBottom()` calling `scrollIntoView`. Every G2 measurement was taken immediately after an explicit `pinToBottom()` in the same JS task, so the green `dfb=0px` lines only proved `scrollIntoView` works, NOT that the transcript stays pinned as content grows underneath — which is the entire bug class. You also flagged: the bounce probe "doesn't try to cause the bug"; G5's white-flash criterion never appeared in the fails; G3 never touched the pasteboard (no Cmd+C / NSPasteboard / TextEdit); G4's reference screenshot didn't exist; the attribution write-up inverted its own evidence; and the re-run's raw log was destroyed (only ever untracked).

## What to verify now — has each correction genuinely landed?

**Note: this re-check now has TWO parts.** Part 1 confirms the corrections from your first review landed. **Part 2 (added) asks you to adjudicate the G2 engine defect that the honest re-run exposed** — this is the fork decision Adam needs external input on before the programme proceeds. Read both.

---

## PART 1 — The four corrections + provenance (from your first review)

### 1. C-2 — The scroll engine (THE decisive one)
The route plan's §4.4 scroll engine — "the ~15 lines that replace two months of fighting" — must now EXIST in the spike's transcript document: a real `pinned` state, a ResizeObserver (or equivalent) keeping the view pinned as content grows underneath, and a scroll listener detecting user scroll-away-from-bottom and unpinning.
**Verify:** Is the pin machinery actually implemented? Is the pin driven by real pinned-state + observation of content growth, NOT by an imperative `pinToBottom()` before each measurement? Does the transcript stay pinned as content grows asynchronously underneath it?

### 2. C-3 — G2 re-run with manual pins removed
G2 must now be measured while content grows underneath a real pinned state — exactly the bug-class scenario — with re-registered criteria BEFORE the run (E3).
**Verify:** Are the G2 criteria re-registered + dated before the run? Are measurements taken during async content growth under a real pin, not after an imperative scroll? Does the bounce probe now actually try to cause the bug (the old one's comment said "We don't try to cause the bug here")? Does it detect any whitespace/bounce/stranding under streaming + late images + resize?

### 3. G3 — Real paste-verify (FR-MULTICOPY A5)
G3 must now do a REAL Cmd+C copy + NSPasteboard read-back, and paste into a real consumer (TextEdit or equivalent).
**Verify:** Did G3 actually touch the pasteboard? Is there a pasteboard read-back artefact? Was the content pasted into a real consumer and verified? (Content-in-order oracle can remain the correctness check, but A5's paste-verified criterion must now be genuinely exercised.)

### 4. G4 — Reference screenshot + visual parity assessed
`G4-reference-light.png` (or equivalent) must now exist, be committed, and visual parity actually assessed.
**Verify:** Does the reference screenshot exist and is it committed? Was visual parity against native bubble chrome actually assessed (Mel as named verifier, or documented substitution with sign-off)?

### 5. Provenance + E8 (new rule)
- **All evidence committed:** is EVERYTHING in the optionb directory committed? Is the new runs' raw log committed (the last one was destroyed mid-review)? Are the surviving files from your first review committed?
- **E8 cross-check (adopted):** one reviewer must confirm every criterion printed as "pre-registered" actually appears in the verdict logic — none silently skipped or annotated "not gated" after being printed as pre-registered. Verify this cross-check was done (it should be visible in the evidence, e.g. a verdict-log map per gate).
- **Attribution write-up:** is the S3 measurement now stated truthfully (system-wide vs spike-attributable, the appPID-discard limitation in `sampleRSSHeldByOurWebContent` noted explicitly)?

## What carries over from your first review (confirm still valid)
- The G1 attribution method (baseline-delta + lsof) — you said it was sound. Confirm the corrected re-run's G1 evidence still holds.
- The 22-min-vs-30-min soak — you found it "worse than disclosed, though not dishonest" (structurally guaranteed early exit). Has Q addressed this — either by documenting the structural guarantee honestly, or by changing the exit logic so a full 30-min soak can run?
- The +29 MB growth event — you said not a leak but it fell outside the plateau window. Is this now handled (e.g. plateau window covering the growth, or documented)?
- The C-2/C-3 gates gate WP-2/WP-3; everything else runs in parallel; WP-1 (Transcript Boundary) is engine-agnostic and proceeds independently.

## PART 2 — NEW: Adjudicate the G2 engine defect (the fork decision)

After the test-harness fix (stateAfterRepin wired, bounce probe fixed, E8 audit completed to all 10 criteria), **G2 still FAILs — but on a real, scoped engine defect, not a test problem.** This is the decision point Adam needs your independent judgement on.

### The defect
With the sampler now reading post-repin state honestly and the bounce probe actually executing (it never ran before — a Promise-serialisation bug), the probe revealed: **the engine auto-repins when content arrives below the viewport even if the user has scrolled up 500px.**

```
G2 bounce_probe initialDFB=500px finalDFB=0px pinned=true
  scrollTop 195455→197063 scrollH=197743 bubbles=457
  (NO REPIN ISSUED — engine must auto-handle)
  ok=false (engineHonouredScrollUp=false)
```

- `initialDFB=500px` — user scroll-up worked (500px from bottom)
- `finalDFB=0px` — engine DID auto-repin to the bottom (yanks the user back)
- `engineHonouredScrollUp=false` — the engine's "respect user scroll-up" branch is **never reached**
- Stream/image/resize: **100% PASS** at post-repin sample — the rest of the engine is solid

**The UX problem:** if a user scrolls up to read history and a new message arrives below, the engine forces them back to the bottom. That's a real bug — arguably worse than the whitespace/bounce bug the programme exists to kill.

### The fork (per WP-0 spec, a G-gate FAIL halts the programme — Exit 1 is the standing fallback)

**Option A — focused engine fix (~half a day):** the "respect user scroll-up" branch exists in the code but is never reached — likely a control-flow bug (e.g. the pin/repin path doesn't check user-scroll state before forcing the pin). Fix it, re-run G2. If G2 then passes, the premise holds and we proceed to WP-2/WP-3.

**Option B — Exit 1:** treat the G2 FAIL as the kill-gate trip, pivot to native Grid rendering + Whitespace-Fix Phases 1–3, and take the scroll-engine finding as the reason.

**Adjudicate:** (a) is the engine defect genuinely narrow/scoped (Option A viable), or does it signal a deeper architectural problem with the whole pin model (Option B)? (b) Is the "respect user scroll-up" branch actually reachable with a control-flow fix, based on your reading of the engine code? (c) Is the bounce probe's criterion fair — should the engine honour user scroll-up under content-arrival-below, or is auto-repin-to-bottom acceptable UX? (d) Your recommendation: A or B, with reasoning and confidence.

### Evidence for the defect
- Corrected G2 evidence: `Docs/Reviews/optionb/G2-evidence.md` (the honest FAIL re-run, rows 5 + 9)
- The scroll engine: `Experiments/TranscriptSpike/Sources/TranscriptSpike/Resources/transcript.html` (the pinned state + deferredRepin + user-scroll-detection logic)
- Kieran's adjudication: the G2 FAIL was a measurement race (now fixed) — the remaining fail is a real engine finding
- Route plan §4.4: `Docs/Specs/Active/single-webview-transcript-plan.md`

---

## Deliverable
A written re-review covering:
1. **Part 1** — verdict on each of the four corrections (GENUINELY FIXED / PARTIALLY FIXED / NOT FIXED) + E8 audit coverage + provenance (all evidence committed) + G5 E5 resolution, with evidence-backed reasoning.
2. **Part 2** — the G2 engine-defect fork: your recommendation (Option A focused fix / Option B Exit 1) with reasoning on (a)–(d) above.
3. Overall WP-0 verdict: **SIGN-OFF** (premise validated, proceed — naming whether via Option A or with the fix) OR **FURTHER CORRECTIONS REQUIRED** (specific items).
4. Any residual risks or improvements to carry into WP-2/WP-3.
5. Confidence level.

Be rigorous and impartial. This is the second external pass — the gates must now genuinely test what they assert, and the G2 fork is the load-bearing decision. Do not rubber-stamp.
