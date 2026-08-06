# WP-0 — Feasibility Spike (KILL GATE)

**Author:** Bee
**Date:** 2026-08-05
**Version:** 2.0 (folded Kieran + Q spec validation)
**Status:** SPEC v2 — pending Kieran + Q re-validation of changes
**Workflow:** Bee spec → Kieran+Q validate → dispatch Q to build → Kieran check → Bee validate → Adam sign-off. External super-checker (Fable/Claude) at milestone only.
**Source:** `Docs/Specs/Active/single-webview-transcript-plan.md` §3 (Phase B-0) + Desktop tracker `BEECHAT-BUILD-PROGRESS.html`
**Builder:** Q · **Spec validation:** Kieran + Q · **Gate verifiers:** Adam (G1,G2,G6), Q (G3,G5), Mel (G4) · **Branch:** `spike/transcript-webview` (throwaway — NEVER merged)
**Estimate:** 2–3 days · **Exit:** all six gates G1–G6 PASS

---

## 1. Goal

Validate that **Option B's core premise actually holds on this machine** before committing real build effort. One `WKWebView` becomes the entire message transcript — message height and scroll offset live in the same layout engine, which makes the whitespace/bounce bug class **unrepresentable**. The spike proves this with real, measurable evidence, or stops the programme early (Exit 1).

**Any G-gate FAIL halts the programme.** Throwaway code, non-throwaway evidence (D3: full G1–G6 depth, get it right).

## 2. The spike harness

- Bare `NSWindow` hosting **one** `WKWebView` + a prototype transcript document.
- **Harness reuse (verified 2026-08-05):** `Experiments/W4MemoryProbe/` exists — a SwiftPM executable target (`swift-tools-version:5.9`, `platforms: [.macOS(.v14)]`, dependency `markdown-webview`). **Q must smoke-test it before relying on it** (compile/run). If it's not a clean reusable target, extract the minimal window+probe pattern explicitly rather than assuming reuse. Document the target's exact launch mechanism, RSS sampling, and WebContent-process counting in the evidence file.
- **Gotcha (carried from Round 3):** GUI probes launched from background shells need manual `NSWindow` + `orderFrontRegardless` — macOS 14+ cooperative activation never maps `WindowGroup` windows, so `onAppear` never fires. Has cost a day before.

### 2.1 Real-data source (E4 — reproducible, per Q)
- **Database:** identify and document the exact GRDB store path used by the running app (Q to confirm the `DatabaseManager`/store location during spike prep). The spike must access the **same persistence store** the app uses.
- **Topic selection:** load **"General"** topic's full message set by **bypassing the 25-message UI window** — pull directly via GRDB.
- **Reproducibility:** document (in the evidence file) the exact GRDB query, topic identifier rule, ordering, excluded/system rows, and whether the fixture is a **live DB snapshot** or **exported JSON** (state which).
- **Message count:** the "422" figure in the route plan is **stale — re-derive it.** Record the query, timestamp, and resulting count (define: all rows vs visible/renderable messages). Evidence must include this.

## 3. The six gates (all must PASS) — with pre-registered, objective protocols (E3)

### G1 — Memory feasibility (verifier: Adam)
- Soak **30 minutes** (restate explicitly).
- **Exactly 1 WebContent process** — deterministic identification method (PID discovery via process query), observed across the full soak window.
- **app + WebContent RSS < 400 MB** — define RSS as summed across the app process + the one WebContent PID.
- **RSS plateaus** — sample at a pre-registered interval (e.g. every 60s); no monotonic growth across the **final 10 min**; document tolerance (e.g. no sustained growth > X MB per sample, transient spikes allowed and noted).
- **Message count re-derived** per §2.1.
- Pre-register all thresholds before the run (E3).

### G2 — Scroll feasibility (verifier: Adam)
- Pinned-at-bottom while: 5fps streaming appends, 10 image loads (late arrival), continuous live window resize 10s.
- **Objective assertions (not just screen recording):**
  - pin state remains `true` throughout;
  - distance from bottom ≤ defined pixel tolerance after each append/image/resize;
  - no unexpected `scrollTop` change beyond tolerance;
  - define "visible jump" and how it's reviewed from the recording.
- **Image fixtures:** 10 late-loading images must use **local/controlled fixtures** — not uncontrolled remote network behaviour (deterministic arrival).
- Screen recording attached (E1).

### G3 — Selection feasibility (verifier: Q) — FR-MULTICOPY A1 chokepoint
- Drag-select across 5 messages incl. a table and code block; Cmd+C; paste into TextEdit.
- **Golden fixture (not arbitrary real content):** use a known table + code fixture with a **documented expected plain-text output** — exact line endings and table representation. Assert the pasted output matches (normalisation rules stated).
- **FR-MULTICOPY A1:** this gate is the prototype proof that cross-message multi-line selection works. If G3 fails, FR-MULTICOPY A1 cannot work in Option B either — programme premise falsified for the copy requirement.
- A2/A3/A4/A5 stay at parity P6 (correctly scoped out of WP-0).

### G4 — Theme feasibility (verifier: Mel)
- Port **1 representative theme** (state which, and why — e.g. the default/light theme) + fontScale slider live.
- **Visual parity** against a **reference screenshot** of the native bubble chrome in that ported theme — document viewport/window size, scale factor, and acceptable pixel-diff threshold.
- **Restyle < 1 frame (16.7ms)** — needs instrumentation. Specify the start/end event (slider change → first composited frame) and the measurement method. **If a clean instrumented frame metric isn't available, record this as a documented performance target rather than a binary gate** (Q's finding — do not fake a number). The other 7 themes are deferred to P4.

### G5 — Topic swap feasibility (verifier: Q)
- Swap between two 25-message topics **20×**.
- **Instrumented:** define swap timing start/end; state whether "< 100ms" means JS mutation-to-bottom, first composited frame, or user-observed latency. Detect white flash via screen recording/frame inspection or pixel sampling. Document exact topic fixtures + expected message counts.

### G6 — Input feasibility (verifier: Adam) — the honest risk
- Type in native composer while transcript streams.
- **Deterministic keystroke harness:** pre-registered input string, typing method/rate, number of repetitions, and how streaming is synchronised. Typed string compared to composer contents — **zero dropped keystrokes**.
- **No focus theft** = observable assertion: composer remains first responder / focus owner throughout.
- State explicitly what's out of scope: IME, key repeat, paste, modifier keys (unless Adam wants them in).

## 4. FR-MULTICOPY linkage

- **G3** = chokepoint for A1 (prototype proof). **A2/A3** = WP-2 transcript-document deliverables, verified at P6. **A4/A5** = P6 (parity matrix), per tracker. WP-0 does not implement or gate A2–A5.
- Evidence template should state this split explicitly (G3 covers A1 only; P6 covers A1–A5 in production).

## 5. Exit criteria

1. **All six gates PASS** → proceed to WP-2 (document) + WP-3 (host) in parallel.
2. **Any gate FAIL** → stop, write up per E6 (negative results recorded), fall back to **Exit 1**: native `Grid` rendering + Whitespace-Fix-Scope Phases 1–3. WP-1 boundary kept regardless.

## 6. Evidence requirements (E1–E7 binding)

- One evidence file per gate at `Docs/Reviews/optionb/<GATE-ID>-evidence.md` — date/build/machine, operator + verifier (must differ, E5), pre-registered criteria verbatim (E3), reproducible method, raw evidence, verdict, prior attempts (E6).
- No gate passes on code inspection alone (E1). Real-data fixtures (E4). Author cannot sign own gate (E5).
- **Standing rule:** any recurrence of bottom whitespace, bounce, or scroll stranding in the `.web` engine is **automatically P0**, regardless of repro narrowness.
- (E2 log threshold and E7 concurrent suite are less relevant to throwaway spike gates but noted: any log used as evidence must be `.info`+.)

## 7. Scope (out)

- No merge to any permanent branch. Branch is throwaway.
- No FR-MULTICOPY A2/A3/A4/A5 implementation (WP-2 / P6).
- No production code changes to the native transcript.
