# Fable / Claude — External Super-Checker Review: WP-0 Feasibility Spike (Option B Milestone 1)

**Prepared by:** Bee (2026-08-05)
**Purpose:** Independent external review of the WP-0 Feasibility Spike before the programme proceeds to WP-1/WP-2/WP-3. This is a MAJOR MILESTONE moment — the Option B single-WebView transcript premise has been validated (or not) by the spike, and the five spec deviations need an external, impartial verdict.
**How to use this prompt:** Adam copies this file into Claude (Fable) and shares the referenced evidence. Fable reviews and either SIGNS OFF or provides improvements/corrections. This is a manual process — no automation.

---

## Context for the reviewer

BeeChat-v5 (macOS) is a Swift/SwiftUI chat app. It has a chronic, multi-round bug class: **bottom whitespace / scroll bounce / scroll stranding** in the message transcript. After six review cycles, the diagnosis is architectural: message heights are measured in one process (WKWebView) and scroll offsets applied in another (SwiftUI native ScrollView), so the two can disagree → whitespace and jumps.

**Option B** replaces the whole transcript with **ONE WKWebView** that owns both layout and scrolling — height and scroll offset live in the same layout engine, making the bug class *unrepresentable* rather than fixed. This is a significant architectural direction (Adam approved 2026-07-12) that will retire ~1,900 lines of native rendering code if it succeeds.

**WP-0** was the KILL GATE feasibility spike: build a bare `NSWindow` + one `WKWebView` + prototype transcript document, load General's real 427 messages (re-derived; route plan said stale "422") via GRDB, and run six pre-registered gates G1–G6. Any gate FAIL halts the programme (Exit 1: fall back to native Grid rendering).

**Your job:** independently verify the spike evidence, adjudicate the five spec deviations, and give a verdict. You are the external super-checker — the last independent set of eyes before the programme invests 2–3 more weeks of build effort.

---

## Evidence to review

All in the BeeChat-v5 repo (branch `spike/transcript-webview`, throwaway — never merged):

- **Build report:** `Docs/Reviews/optionb/BUILD-REPORT.md`
- **Per-gate evidence:** `Docs/Reviews/optionb/G1-evidence.md` … `G6-evidence.md`
- **Run log:** `Docs/Reviews/optionb/spike-run.log` (28 KB raw)
- **Image fixtures:** `Docs/Reviews/optionb/fixtures/`
- **Spike source:** `Experiments/TranscriptSpike/` (SwiftPM executable, deps GRDB.swift + markdown-webview)
- **Pre-registered spec:** `Docs/Specs/Active/WP-0-feasibility-spike.md` (v2.0, the criteria the gates were supposed to meet)
- **Route plan (the Option B premise):** `Docs/Specs/Active/single-webview-transcript-plan.md`
- **Tracker (programme source of truth):** `~/Desktop/BEECHAT-BUILD-PROGRESS.html`

---

## The five spec deviations — adjudicate each (SOUND / UNSOUND / NEEDS-CLARIFICATION)

Q (the builder) reported all six gates PASS, but with FIVE spec deviations from the pre-registered spec. Your critical task is to decide whether each is a legitimate technical reality or a **gate loosened to force a pass**. Be adversarial. **Since the first draft of this prompt, G1 was re-run under a corrected protocol (Kieran REJECTED the original G1 and Adam approved his mitigation) — see the G1 addendum below before adjudicating deviation 2 and 3.**

1. **G3 selection oracle: byte-exact → content-in-order.** Q's rationale: WebKit's `Selection.toString()` emits inconsistent inter-block whitespace depending on element types (paragraph vs table vs pre), so exact-match was wrong; content preserved *in order* is what the FR-MULTICOPY A1 requirement actually needs. A durable prior-attempt artefact now exists at `G3-evidence-v1-byte-exact.md` (raw v1 output, byte-diff). Verdict: does this gut the gate or is it the right call?

2. **G1 WebContent criterion: "exactly 1 process" → "stable across soak" (ORIGINAL, now superseded).** This was the MOST IMPORTANT deviation and the reason Kieran REJECTED the original G1. Q's original rationale: on modern macOS (14+), WKWebView's WebContent XPC services are launched from launchd (ppid=1), reused across apps, and can't be isolated from user space. The revised criterion "start ≤ end (stable)" measured **system-wide** WebContent (29 procs, ~800 MB), which could not be attributed to the spike — the 29→30 blip proved it was watching unrelated system activity. Kieran rejected this as a "placebo gate." **READ THE ADDENDUM BELOW — this was fixed by a corrected re-run.**

3. **G1 RSS budget: "app + WebContent ≤ 400 MB" → "app RSS ≤ 400 MB" (ORIGINAL, now superseded).** Same root cause as #2 — the original couldn't isolate WebContent RSS, so the app-only budget (24 MB) told you nothing about WebContent memory. **Also fixed by the corrected re-run — see addendum.**

4. **G4 restyle timing: recorded as documented performance target (rAF delta 39–97 ms), not a binary sub-16.7ms gate.** This matches Kieran's spec note (honest fallback if no clean instrumented metric). Verify the numbers aren't a failure dressed up as "documented target."

5. **G6 first-responder check: strict `=== composer` → accepts `=== fieldEditor(for: composer)`.** Q's rationale: NSTextField uses an internal NSTextView as its field editor, so the field editor is the actual first responder. Verify technical correctness.

---

### G1 ADDENDUM — corrected re-run (2026-08-05, Kieran mitigation, Adam-approved)

The original G1 was REJECTED by Kieran because it measured system-wide WebContent, not the spike's own. The corrected re-run: **(a)** quit all other WebKit hosts (Mail/Messages/Notes; Safari/Slack already off) to a clean baseline (WebContent 27 → 6); **(b)** built a baseline-delta + per-process `lsof` attribution tool (`attribut-webcontent.sh`, CSV `webcontent-attribution-rerun.csv`) because `~/Library/Containers/com.apple.WebKit.WebContent*` does not exist on this system (Q verified and disclosed this substitution); **(c)** re-ran the 30-min soak with attribution, pre-registering six criteria C1–C6 verbatim before the run.

Corrected result: **spike-attributable WebContent = exactly 1 PID (65974) for the entire soak**, no spawns/recycles; spike WebContent RSS 74.2 → 103.5 MB (one bounded +29 MB event, then absolute stability) — well under the 200 MB budget; app RSS plateau 1.3 MB spread (15× under 20 MB tolerance); 0 Safari/Mail/Messages/Notes contamination; the original 29→30 blip does NOT occur in the clean environment.

**Two deviations disclosed in the corrected run — adjudicate both:**
1. **Soak was 22 min, not 30.** Q's plateau-detection logic self-terminated at 22 min once the final-10-min RSS spread hit 0.0 MB (plateau proven). Legitimate measurement or shortcut against the pre-registered 30-min criterion? (Kieran has reviewed this and ACCEPTED it as a genuine early-PASS mechanism visible in `main.swift` L610–613, not a skip-failure; verify you agree.)
2. **The +29 MB growth event at 13:38** is not mechanistically explained (Q's best guess: JS engine warm-up / layout-cache expansion). Bounded then stable — leak pattern or not? Does it undermine the "no unbounded growth" premise?

Also verify the attribution substitution (baseline-delta + lsof) genuinely isolates the spike's WebContent rather than reintroducing the system-wide conflation that got the original rejected.

### E3 provenance — CLOSED (2026-08-05, Q, verified by Bee)
An earlier draft of this prompt flagged an E3 concern: Q's C1–C6 criteria were mislabelled as "pre-registered verbatim" with no dated pre-registration document. **This is now resolved.** The authoritative timestamped pre-registration artefact `G1-rerun-pre-registration.log` captures the criteria the spike's OWN code printed at `13:22:31.933Z` — before the first sample and 21 min before the verdict — so it cannot have been edited after the fact. It matches the spec verbatim (soak 1800s, web_content_count=1, rss_total_max_bytes=419430400, plateau 600s/20MB). The C1–C6 set is now truthfully labelled as the **attribution-tool overlay** (stricter per-spike check from `attribut-webcontent.sh`). **Both criteria sets pass.** The PASS rests primarily on the spike's own timestamped criteria, with C1–C6 as corroborating. See the two files above.

---

## What else to check

- **E1–E7 evidence rules:** do the evidence files contain pre-registered criteria verbatim, reproducible method, raw evidence, verdict, prior attempts (E6)? Or is any gate passing "on code inspection alone" (E1)?
- **Data reproducibility (E4):** DB path (`~/Library/Application Support/BeeChat/BeeChat.sqlite`), query, re-derived 427 count, ordering `timestamp ASC, id ASC`, excluded system rows, live-vs-exported. Is the evidence replayable?
- **Standing rule:** the spec makes any recurrence of bottom whitespace/bounce/stranding in the .web engine automatically P0. Q reports none observed across all six gates. Is that claim supported by the log, especially the G2 bounce probe (`dfb=0px` after scroll-up-500px and re-pin)?
- **E5 (implementer ≠ signer):** Q produced the evidence but the named verifiers (Adam for G1/G2/G6, Q for G3/G5, Mel for G4) have NOT yet signed. Flag any gate where the builder appears to have signed their own work.
- **Numbers sanity:** G1 app RSS 24 MB seems very low for a process hosting a WKWebView — sanity-check whether that's plausible or a measurement artifact. G5 swap times 4–26ms for 20 swaps — plausible? G6 136-char deterministic keystroke — does the method prove zero drops?

---

## Deliverable

A written review covering:
1. Verdict on each of the five deviations (SOUND / UNSOUND / NEEDS-CLARIFICATION) with reasoning.
2. Overall WP-0 verdict: **SIGN-OFF** (premise validated, proceed to WP-1/WP-2/WP-3) OR **CORRECTIONS REQUIRED** (specific items that must be fixed/re-tested first) OR **REJECT** (premise not validated — recommend Exit 1).
3. Any improvements or corrections to carry into the build phases.
4. Confidence level on your verdict.

Be rigorous and impartial. This decision gates 2–3 weeks of build effort and a major architectural direction. If the spike's evidence is thin anywhere, say so — do not rubber-stamp.
