# Option B — Single-WebView Transcript: Managed Scope & Verification Gates

**Author:** Fable
**Date:** 2026-08-04
**Status:** SCOPE — for team execution
**Companion to:** `single-webview-transcript-plan.md` (the technical route, 2026-07-12, direction approved by Adam)
**Relationship:** The route plan says *what* to build. This document says *how the work is governed*: work packages, owners, entry/exit gates, evidence standards, sign-off authority, rollback, and the decisions that must be taken before work starts.

---

## 0. How to use this document

- **§1–2** — what is and isn't in scope; read once.
- **§3** — drift audit. The route plan is three weeks old and several claims no longer hold. Read before estimating.
- **§4** — the evidence standard. **This is the part that makes the difference.** Every gate below is enforced by it.
- **§5** — work packages WP-0…WP-5. Each has an owner, entry condition, deliverables, and an exit gate.
- **§6–9** — the gate register (G/T/P/R series), in full.
- **§10–13** — risk register, defect bar, schedule, RACI.
- **§14** — decisions needed from Adam before WP-1 starts.

A work package is **not complete** when the code is written. It is complete when its exit gate has a signed evidence artifact in `Docs/Reviews/optionb/`.

---

## 1. Why this programme exists

Since Round 1 (2026-06-30) the message window has consumed six review cycles, five branches, and roughly six weeks of team time. The bug list — bottom whitespace, bouncing, jump-stops-short, topic-switch flash, blank bubbles after WebContent death — has been diagnosed correctly four separate times and patched three times, and it is still happening in production today.

The reason is architectural, not a sequence of coding errors: **message heights are computed in one layout engine (WebKit) and consumed in another (SwiftUI), asynchronously, across a process boundary.** Every fix so far has been a correction applied *after* the two engines disagreed. Option B removes the disagreement by putting height and scroll offset back in the same layout engine.

The success condition for this programme is not "the whitespace bug is fixed." It is **"the whitespace bug class is unrepresentable."** A fix that could regress is not a pass.

### 1.1 Current state of the tactical line (as of 2026-08-04)

| Item | State |
|---|---|
| `main` | `72b1cd3`, v0.9.5c (2026-07-04) — contains **none** of the whitespace work |
| `fix/whitespace-phase1-clamp` | `c84a50f`, clamp v3, **unmerged**, Kieran review = REQUEST CHANGES (1 actionable: F-N1, a one-line logging fix) |
| Whitespace-Fix-Scope Phases 2, 3 | Never started |
| Last activity | 2026-07-17 |

**Management consequence:** Adam is currently running a build that has either no whitespace mitigation at all, or an unreviewed local build. Decision D1 (§14) resolves this. It is not optional — it determines what "livable" means for the ~3 weeks this programme runs.

---

## 2. Scope boundary

### 2.1 In scope

- A swappable transcript engine boundary (`TranscriptBoundary.swift`) — shippable value on its own, independent of Option B's success.
- A single app-lifetime `WKWebView` rendering the entire message transcript.
- Transcript document (HTML/CSS/JS), Swift host, bridge protocol.
- Theme token extension for bubble geometry (radius/spacing/shadow — see §3.2).
- Parity across streaming, topic switch, load-earlier, themes, font scale, links, images, selection/copy, VoiceOver, WebContent process death.
- Retirement of the native transcript engine and the per-bubble WebView machinery, **after** two stable releases on `.web`.

### 2.2 Out of scope (explicitly)

| Item | Why | Where it goes |
|---|---|---|
| Composer, sidebar, status bar, sheets, reset indicator | Outside the transcript boundary; untouched | — |
| `MessageListObserver` 25-message windowing | Upstream concern, identical in both engines | Unchanged |
| Native `Grid` table rendering (§5 of the old rendering spec) | Was the fallback if Option B fails | Exit-1 path, §11 |
| Cmd+F in transcript, native image viewer, ThinkingBee winged animation | Polish, not parity | Post-default-on backlog (§9.3) |
| BeeChat-Mobile / iOS | Separate platform target, unresolved since Round 3 | Decision D4 (§14) |
| Sanitizer policy changes | Policy is unchanged; only the *call site* moves | Mel reviews location only |

### 2.3 The one accepted fidelity regression

ThinkingBee ships as a CSS three-dot pulse, not the 64-line `BeeWingsAnimation` SwiftUI port. Logged, accepted, scheduled for polish. Anyone who raises it during P-series review should be pointed here.

---

## 3. Drift audit — corrections to the 2026-07-12 route plan

The route plan's §1.1 reuse inventory and §4.2 token map were written against the tree as it stood on 2026-07-12. Verified against `fix/whitespace-phase1-clamp` today, four claims are wrong. **Estimates in the route plan's §11 do not account for these.**

### 3.1 `scripts/embed-template.swift` does not exist

`MessageTemplate.swift:16` instructs the reader to run `swift scripts/embed-template.swift`, and the route plan lists it in the "zero changes required" reuse inventory. `scripts/` contains only `build-and-install.sh`, `gateway-probe.mjs`, `gateway-probe.py`, `release.sh`.

The embedded template constant has been maintained **by hand**. This is a live risk for the hand-assembled `.app` bundle, which per `MessageTemplate.swift:10` depends *solely* on that constant — an un-regenerated constant ships a stale template with no build error.

**Action:** WP-2 writes the script for real (`TranscriptTemplate.html` → `TranscriptTemplate.swift`), and WP-2's exit gate includes a drift check. Add ~half a day. This is a genuine pre-existing defect surfaced by the audit, not new scope.

### 3.2 The theme token gap is different from what the plan states

Route plan §4.2 lists eight "new tokens needed." Verified against `ThemeManager.computeCSSTokens()`:

| Plan says needed | Reality |
|---|---|
| `--bc-bg-surface` | ✅ Already exists |
| `--bc-bg-panel` | ✅ Already exists |
| `--bc-bg-elevated` | ✅ Already exists |
| `--bc-text-on-accent` | ✅ Already exists |
| `--bc-accent-primary` | ⚠️ Wrong name — actual token is `--bc-accent` |
| `--bc-text-secondary` | ⚠️ Wrong name — actual token is `--bc-text-dim` |
| `--bc-border-subtle` | ⚠️ Wrong name — actual token is `--bc-code-border` |
| `--bc-shadow`, `--bc-radius-xl`, spacing tokens | ❌ **Genuinely missing — no geometry or shadow tokens exist at all.** `computeCSSTokens()` emits colours, `--bc-appearance`, and `--bc-font-scale`. Nothing else. |

**Action:** WP-2 adds a *geometry* token group to `ThemeManager` (radius, bubble padding, gap, shadow). Colour work is smaller than planned; geometry work is larger. Net: roughly neutral, but the brief must say the right thing or the implementer will look for tokens that aren't there.

### 3.3 `FeatureFlags` cannot host `transcriptEngine` as-is

`FeatureFlags` holds exactly one `Bool` (`htmlRenderingEnabled`) with a hardcoded `Keys` enum. `TranscriptEngine` is a `String`-raw-value enum. The route plan's "same `@Observable` + UserDefaults pattern" is directionally right but not a copy-paste. Small (~15 lines), but it needs stating so WP-1 doesn't get surprised, and `FeatureFlagsTests.swift` must be extended.

### 3.4 The deletion ledger is now larger

`MessageCanvas.swift` was ~470 LOC when the ledger was written; the Phase-1 clamp took it to **528**. If the clamp lands (D1), the ledger grows again. Corrected total at retirement: **~1,960 removed** vs ~710 added = **net −1,250**.

This is a point worth making to the team: *every line added to the tactical line is a line the strategic line deletes.* It is an argument for keeping the clamp minimal, not for abandoning it.

### 3.5 Unverified figure carried forward

Gate G1 specifies "General's real 422 messages." That count is three weeks stale. **WP-0 re-derives it from the DB before the run and records the actual number in the G1 evidence artifact.** Do not let a pre-registered threshold quietly float.

---

## 4. The evidence standard

This project has a specific, documented failure mode. It is worth naming plainly because the gates below exist to prevent its recurrence:

- **Round 5:** all five prescribed fixes reviewed and 4/5 confirmed — *"nothing runtime-verified yet."* One of the five (F1, the monotonic height guard) was a real defect that shipped.
- **Round 7:** the discriminating log lines were `Logger.debug`, which macOS **does not persist**. The single field that would have settled the M1-vs-M2 question — whether accepted heights were shrinks or growths — *was never checked by anybody* across two review cycles.
- **Round 6b:** a log audit was read as evidence of memory-pressure kills; the correct reading was ordinary lifecycle churn. The conclusion reversed on re-analysis of the same data.

Three cycles were spent on conclusions that code inspection produced and runtime evidence later contradicted. The rules below are not bureaucracy; each one maps to a specific cycle that was lost.

### E-rules (binding on every gate in this document)

| # | Rule | Origin |
|---|---|---|
| **E1** | **No gate passes on code inspection alone.** Every gate requires an artifact produced by *running* something: a log capture, a test run, a screenshot, a measured number. "I read the diff and it looks right" is a review comment, not a gate pass. | Round 5 |
| **E2** | **Any log line that is gate evidence must be `.info` or higher.** `Logger.debug` is not persisted by macOS and cannot be audited after the fact. Gate evidence must survive to `log show`. | Round 7 |
| **E3** | **Thresholds are pre-registered.** The numeric pass criterion is written into the gate *before* the run. A threshold adjusted after seeing results invalidates the gate and requires a re-run under the new number, recorded as such. | W4 probe discipline |
| **E4** | **Real-data fixtures.** Gates run against General's actual message window pulled from GRDB, not synthetic transcripts. Synthetic corpora hid the table-heavy reality that broke the ~95%-native assumption in Round 8. | Round 8 |
| **E5** | **The author cannot sign their own gate.** Implementer produces evidence; a second party verifies and signs. For G-series and P-series, Adam or a named reviewer signs. | AgentDrop convention |
| **E6** | **Negative results are recorded, not discarded.** A failed gate run gets an evidence artifact too. A gate that passed on the fourth attempt must show the three failures. | Round 6b |
| **E7** | **Green suite means the whole suite, run concurrently.** No cherry-picked test runs. `swift build && swift test` clean, output pasted into the artifact. | AgentDrop convention |

### 4.1 Evidence artifact format

One markdown file per gate at `Docs/Reviews/optionb/<GATE-ID>-evidence.md`:

```
# <GATE-ID> — <name>
Date / Build (commit SHA) / Machine + macOS version
Operator: <who ran it>       Verifier: <who signed it>  [must differ — E5]

## Pre-registered criteria
<copied verbatim from this document, before the run>

## Method
<exact commands, exact repro steps — reproducible by someone else>

## Raw evidence
<log excerpts, numbers, screenshot paths, test output>

## Result: PASS | FAIL | PASS-WITH-CONCERNS
<if PASS-WITH-CONCERNS: what concern, who owns it, which gate re-tests it>

## Prior attempts
<E6: any earlier failed runs>
```

`PASS-WITH-CONCERNS` exists so that people stop rounding a partial result up to PASS. It does not block progress, but the concern is assigned an owner and a later gate that must re-test it.

---

## 5. Work packages

Dependency graph:

```
        ┌──────────────────────────────────────────────┐
        │ D1–D4 decisions (§14) — Adam, before start   │
        └───────────────┬──────────────────────────────┘
                        │
       ┌────────────────┴────────────────┐
       ▼                                 ▼
  WP-1 boundary  ──────────────►   WP-0 spike (G1–G6)
  (0.5–1 day)         parallel        (2–3 days)
       │                                 │
       │              ┌──────────────────┘  KILL GATE
       │              ▼
       │        ┌─────┴──────┐
       ▼        ▼            ▼
     WP-2 document      WP-3 host        (parallel, interface-contracted)
     (2.5–3.5 days)     (2 days)
            └──────┬──────┘
                   ▼
            WP-4 parity (2–3 days)
                   ▼
            WP-5 rollout (2 release cycles, calendar)
                   ▼
            WP-6 retirement (0.5 day)
```

---

### WP-1 — Transcript boundary refactor

| | |
|---|---|
| **Owner** | Kieran |
| **Reviewer** | Q (interface contract) |
| **Entry** | D1, D2 decided |
| **Estimate** | 0.5 day + 0.5 day for §3.3 flag work = **1 day** |
| **Branch** | `feat/transcript-boundary` |
| **Standalone value** | **Yes** — ship this even if Option B is abandoned. It is the modularity insurance Adam asked for. |

**Deliverables**
1. `Sources/App/UI/Transcript/TranscriptBoundary.swift` — `TranscriptState`, `TranscriptCallbacks`, `TranscriptEngine`, `transcriptView(engine:state:callbacks:)` per route plan §2.
2. `FeatureFlags.transcriptEngine: TranscriptEngine` (§3.3 — string-backed, defaults `.native`), plus `FeatureFlagsTests` coverage.
3. `NativeTranscriptView` — rename-and-wrap of `canvasWithMacOS15Chrome` + `MessageCanvas` + chrome. **Zero logic changes.**
4. `MainWindow.swift:234` calls `transcriptView(...)`.
5. Streaming/bridge policy (`MessageCanvas.swift:37–60`) moved to `TranscriptState` extension methods, so both engines consume one derived `streamingHTML` / `settledBridgeHTML`.
6. `WebTranscriptView` stubbed to `EmptyView`.

**Exit gate B1** — see §7.

**Rollback:** revert one commit. No behavioural surface touched.

---

### WP-0 — Feasibility spike (the kill gate)

| | |
|---|---|
| **Owner** | Bee |
| **Verifier** | Adam (G1, G2, G6), Q (G3, G5), Mel (G4) |
| **Entry** | D3 decided; W4MemoryProbe harness located (`Experiments/W4MemoryProbe`, confirmed present) |
| **Estimate** | 2–3 days |
| **Branch** | `spike/transcript-webview` — **throwaway, never merged** |
| **Authority** | **Any G-gate failing halts the programme.** Not "raises a concern" — halts. Fall back to Exit 1 (§11). |

Runs in parallel with WP-1 because WP-1 has standalone value and does not depend on the spike's outcome.

**Deliverables:** a bare `NSWindow` hosting one `WKWebView` + a prototype transcript document, sufficient to run G1–G6. Throwaway quality is fine; **evidence quality is not.**

**Carried gotcha (Round 3):** GUI probes launched from background shells need manual `NSWindow` + `orderFrontRegardless` — macOS 14+ cooperative activation never maps `WindowGroup` windows, so `onAppear` never fires and the probe silently measures nothing. This has cost the team a day before.

**Exit gate:** G1–G6 all PASS (§6).

---

### WP-2 — Transcript document

| | |
|---|---|
| **Owner** | Bee (implementation), Mel (CSP/sanitizer review) |
| **Reviewer** | Q (bridge protocol conformance) |
| **Entry** | G1–G6 PASS; §4.3/§4.5 bridge contract frozen |
| **Estimate** | 2.5–3.5 days (route plan's 2–3 + §3.1 embed script + §3.2 geometry tokens) |
| **Branch** | `feat/transcript-document` |

**Deliverables**
1. `Sources/App/Resources/TranscriptTemplate.html` — DOM per route plan §4.1, CSS per §4.2, JS API per §4.3, scroll engine per §4.4, events per §4.5, CSP per §4.6.
2. `Sources/App/Rendering/TranscriptTemplate.swift` — generated constant, same resolution chain as `MessageTemplate.swift`.
3. **`scripts/embed-template.swift` — written for real** (§3.1), handling both templates, with a `--check` mode that exits non-zero on drift.
4. `ThemeManager` geometry token group (§3.2): `--bc-radius-bubble`, `--bc-pad-bubble`, `--bc-gap-msg`, `--bc-shadow-bubble`. Names to be confirmed by Mel against the existing convention.
5. Headless tests T1–T4 (§8), extending the `MessageTemplateTests` harness.
6. Fixture corpus: 18 converter matrix cases + General's real window exported as JSON.

**Interface contract with WP-3:** the JS API (route plan §4.3) and event set (§4.5) are **frozen at WP-2 entry**. Any change requires Q's sign-off and a note to WP-3's owner the same day. This is what lets WP-2 and WP-3 run in parallel.

**Exit gate B2** — see §7.

---

### WP-3 — Swift host

| | |
|---|---|
| **Owner** | Kieran |
| **Reviewer** | Q |
| **Entry** | G1–G6 PASS; bridge contract frozen; WP-1 merged |
| **Estimate** | 2 days |
| **Branch** | `feat/transcript-host` |

**Deliverables** per route plan §5: `Sources/App/UI/Transcript/WebTranscriptView.swift` (~300 LOC), one app-lifetime `WKWebView`, state diffing in `updateNSView`, content prep memoized by content hash, process-death replay, context-menu filtering (keep Copy / Copy Link / Look Up / Share; remove Reload / Go Back / Inspect Element).

**Explicitly deleted, not ported:** the `BubbleWebView.scrollWheel` inversion hack. It existed only because bubbles sat inside a native scroll view.

**Housekeeping (do it here, it's a two-line fix with outsized payoff):** set the app's **bundle identifier** in the hand-assembled `Info.plist`. Per Bee's Round 6b finding this is currently unset, which is why `log show --predicate 'subsystem == "com.beebox.beechat"'` returns nothing. **E2 evidence is not collectable until this is fixed** — so it is a WP-3 blocker, not housekeeping. Consider pulling it forward into WP-0 if the spike needs log evidence.

**Exit gate B3** — see §7.

---

### WP-4 — Parity and hardening

| | |
|---|---|
| **Owner** | Bee (fixes), Adam + Q + Mel (verification) |
| **Entry** | B2 and B3 both PASS |
| **Estimate** | 2–3 days including fixes |
| **Branch** | `feat/transcript-parity` |

**Deliverables:** P1–P12 (§9) all PASS or PASS-WITH-CONCERNS with owners; soak test; screenshot-diff corpus across all 8 themes.

**Exit gate B4** — see §7. B4 is the **default-on gate**: passing it authorises WP-5 step 2.

---

### WP-5 — Rollout

| | |
|---|---|
| **Owner** | Adam (release decisions), Bee (builds) |
| **Entry** | B4 PASS |
| **Duration** | 2 release cycles — calendar time, not effort |

1. **R1** — release with `transcriptEngine` default `.native`, `.web` available via toggle. Adam and Bee's agents dogfood `.web`.
2. **R2** — release with default `.web`, native retained as escape hatch (flip-back is one UserDefault, no reinstall).
3. **R3** — after two stable releases on `.web`, authorise WP-6.

Gates R1–R3 in §10.

---

### WP-6 — Retirement

| | |
|---|---|
| **Owner** | Kieran |
| **Entry** | R3 PASS |
| **Estimate** | 0.5 day |

Execute the deletion ledger (§12). Net −1,250 LOC. `TranscriptBoundary` remains — the boundary is the permanence, not the dead code.

---

## 6. G-series — feasibility gates (kill authority)

Run in WP-0. **Any FAIL halts the programme** and triggers Exit 1 (§11). Pre-registered per E3.

| Gate | Test method | Pass criteria (pre-registered) | Verifier |
|---|---|---|---|
| **G1** memory | Load General's real message set (pull via GRDB, bypass the 25-window), soak 30 min | Exactly **1** WebContent process; app+WebContent RSS **< 400 MB**; RSS **plateaus** (no monotonic growth across final 10 min). Actual message count recorded per §3.5. | Adam |
| **G2** scroll | Pinned-at-bottom while: 5fps streaming appends, 10 images with late arrival, continuous live window resize for 10s | **Never** unpins, **never** strands, no visible jump. Screen recording attached. | Adam |
| **G3** selection | Drag-select across 5 messages incl. a table and a code block; Cmd+C; paste into TextEdit | Coherent multi-message plain text; table rows legible as rows | Q |
| **G4** theme | Port 1 of the 8 themes + fontScale slider live | Visual parity with native bubble chrome; restyle completes **< 1 frame** (16.7ms) | Mel |
| **G5** topic swap | Swap between two 25-message topics **20×** | No white flash on any of 20; lands at bottom **20/20**; perceived **< 100ms** | Q |
| **G6** input | Type in native composer while transcript streams | No focus theft; **zero** dropped keystrokes (typed string compared to composer contents) | Adam |

**Why these six and not others:** each maps to a specific failure that has already happened. G1 → the 12.9 GB WebContent blowup (Round 3). G2 → the whitespace/bounce bug class itself. G3 → Adam's stated requirement that copy work. G4 → the 8-theme token plumbing risk flagged in Round 1. G5 → topic-switch flash. G6 → the composer/transcript focus interplay, the one genuinely new risk Option B introduces.

**G6 deserves attention.** It is the only gate testing something the current architecture gets for free. A native composer alongside a web transcript is the one place Option B is *worse* on paper. If G6 is marginal, say so at the time — do not let it pass on a shrug.

---

## 7. B-series — phase exit gates

| Gate | Package | Criteria | Evidence | Signs |
|---|---|---|---|---|
| **B1** | WP-1 | App behaviourally identical; flag flips `.native`↔`.native` (web stubbed); `swift build && swift test` fully green (E7); no diff in rendered output on a 3-topic manual walk | Test output + before/after screenshots of 3 topics | Q |
| **B2** | WP-2 | T1–T4 PASS (§8); fixture corpus renders correctly across all 8 themes (screenshot-diff); `embed-template.swift --check` exits 0; CSP reviewed and signed by Mel | Test output, screenshot grid, Mel's sign-off note | Mel + Q |
| **B3** | WP-3 | Flag `.web` renders General end-to-end with live streaming against the gateway; `kill -9` on WebContent mid-session → transcript self-restores **at bottom** within **1s**; bundle-id fix verified by a successful `log show` query | Screen recording of the kill/restore; `log show` output | Q |
| **B4** | WP-4 | P1–P12 all PASS or PASS-WITH-CONCERNS-with-owner; soak passes; **zero** open P0/P1 defects (§13) | Full P-matrix artifact | **Adam** |

**B4 is the one Adam personally signs.** It authorises default-on for his own daily driver.

---

## 8. T-series — automated document tests (CI-enforced)

Written in WP-2, extend the `MessageTemplateTests.swift` headless-WKWebView harness. These are the regression guard **after** the programme ends — they are the reason the bug class stays dead.

| Test | Asserts |
|---|---|
| **T1** | `setTopic` lands `scrollTop == scrollHeight − clientHeight` **before** the first paint callback (the topic-switch fix, mechanised) |
| **T2** | Pin hysteresis across scripted scrolls: enters pinned at d<50, leaves at d>120, no oscillation in the 50–120 band |
| **T3** | `prependEarlier` preserves the anchor offset **exactly** (record scrollHeight before, assert `scrollTop += delta` after) |
| **T4** | Streaming settle produces **zero** node-count flicker (MutationObserver assert — R4's death certificate) |

Add **T5** (recommended, not in the route plan): a regression test that asserts `bcHeight` does not exist in the bridge surface. Cheap, and it prevents a future contributor reintroducing a height protocol "just for one case." That is exactly how the current architecture happened.

---

## 9. P-series — parity matrix (WP-4)

### 9.1 Must-pass (blockers for default-on)

| # | Scenario | Expectation | Verifier |
|---|---|---|---|
| P1 | Topic switch ×20 incl. General | Lands at bottom, no flash, no whitespace — **the original sin, gone** | Adam |
| P2 | ThinkingBee → stream → settle | One continuous bubble; no remount flash | Adam |
| P3 | Load earlier ×3 | Viewport anchored on previously-visible message | Q |
| P4 | All 8 themes + fontScale range | Full restyle, no reload | Mel |
| P5 | Live resize 10s | Pinned stays pinned; mid-scroll position tolerably stable | Q |
| P6 | Cross-message selection + Cmd+C incl. table + code | Clean multi-line copy | Adam |
| P7 | Links (allowed + blocked schemes), image tap | `LinkPolicy` parity, no behaviour change | Mel |
| P8 | Archived read-only view, reset indicator overlay | Unchanged (outside boundary) | Q |
| P9 | WebContent kill during streaming | Self-heal ≤1s, no blank bubble | Q |
| P10 | VoiceOver walk + arrival announcement | Coherent order, `aria-live` fires | Mel |
| ~~P11~~ | ~~macOS 14 run~~ | **DELETED 2026-08-05.** Deployment floor raised to `.macOS(.v26)` (Adam) — see `option-b-prior-art-register.md` §1. There is one OS version to support, so there is nothing to run a parity pass against. Freed effort goes to S1/S9 measurement | — |
| P12 | Memory census after 1h mixed use | 1 WebContent process; RSS plateau; repurposed `WebViewCensus` asserts count==1 | Adam |

### 9.2 Regression sweep (must also pass)

The transcript is not the only thing in the window. Before B4:

| # | Area | Check |
|---|---|---|
| P13 | Topic delete / archive | `DIAG-001` behaviour unchanged |
| P14 | Session reset marker | `FR-005` feedback unchanged |
| P15 | Font scale persistence | `FontScaleTests` green, visual check |
| P16 | Gateway reconnect (`FR-002`) | Status bar + transcript recover together |

### 9.3 Post-default-on backlog (not gates)

Cmd+F via `WKWebView.find(_:)`; native image viewer for `bcImage`; ThinkingBee CSS wings port.

---

## 10. R-series — rollout gates

| Gate | Trigger | Criteria | Signs |
|---|---|---|---|
| **R1** | Release with `.web` opt-in | Build ships; Adam + Bee's agents on `.web` for **≥5 days** of normal use | Adam |
| **R2** | Flip default to `.web` | R1 period produced **zero** P0/P1 transcript defects; census evidence from real use (E2 logs, `log show`) attached | Adam |
| **R3** | Authorise retirement | **Two** stable releases on `.web` default; zero P0/P1; no `.web`→`.native` flip-backs by any user | Adam |

**The escape hatch is the point.** Between R2 and R3 the native engine stays. Flip-back is one UserDefault, no reinstall. Do not delete anything before R3 — that is what makes R2 a low-stakes decision.

---

## 11. Exit paths

| Path | Trigger | Action |
|---|---|---|
| **Exit 0 — Success** | R3 PASS | WP-6 retirement |
| **Exit 1 — Spike failure** | Any G1–G6 FAIL | Halt. Write `Docs/Reviews/optionb/EXIT1-<gate>.md`. Fall back to: native `Grid` table rendering to shrink the WebView population, plus the Whitespace-Fix-Scope Phases 1–3 completed properly. **WP-1's boundary is kept regardless** — it is standalone value. |
| **Exit 2 — Parity failure** | B4 blocked >1 week on P0/P1 | Adam decides: extend, or ship `.web` opt-in permanently and revisit. Native remains default. Nothing is deleted. |
| **Exit 3 — Field failure** | P0 in R1/R2 | Flip the UserDefault back to `.native`. No rebuild, no reinstall, no data migration. Root-cause before re-attempting R2. |

Every exit path leaves the app shippable. That is a deliberate property of the sequencing, not a coincidence — it is why the boundary (WP-1) comes first and retirement (WP-6) comes last.

---

## 12. Deletion ledger (corrected per §3.4)

Executed at WP-6 only.

| File / area | LOC |
|---|---|
| `MessageWebView.swift` (height bridge, tripwire, coordinator) | 267 |
| `WebViewHeightCache.swift` | 36 |
| `HTMLMessageConverter.swift` + SwiftSoup dependency | 326 |
| `ConvertedMessageView.swift` | 206 |
| `MessageCanvas.swift` (chrome, hysteresis, `.id(topicId)`, clamp, compat shims, CompletedBridgeBubble) | **528** ⬆ |
| `MessageContent.swift` webview/converter branches; `StreamingBubble` webview path | ~120 |
| `MessageBubble.swift` + width plumbing (recreated as ~60 lines of CSS) | 155 |
| Converter/rendering tests tied to the above | ~300 |
| **Removed** | **~1,938** |
| **Added** (template ~350 + host ~300 + boundary ~60) | **~710** |
| **Net** | **−1,228** |

Also removed, and worth more than the line count: one rendering pipeline instead of three (native / per-bubble webview / bridge bubbles); **zero** undocumented SwiftUI scroll semantics in the dependency set. (The macOS 14/15 fork dimension was independently deleted on 2026-08-05 by the deployment-floor raise to `.macOS(.v26)` — the five surviving `@available` branches are dead code awaiting WP-6 rather than a live compatibility burden.)

---

## 13. Defect bar during the programme

| Sev | Definition | Response |
|---|---|---|
| **P0** | Data loss, crash, transcript unreadable, or the whitespace/bounce class reappearing | Stop-the-line. Blocks all gates. |
| **P1** | Parity regression vs native engine in a P1–P12 scenario | Blocks B4. Fix before default-on. |
| **P2** | Cosmetic/fidelity gap with a workaround | PASS-WITH-CONCERNS; owner + target gate assigned |
| **P3** | Polish | §9.3 backlog |

**Standing rule:** any recurrence of bottom whitespace, bounce, or scroll stranding in the `.web` engine is **automatically P0**, regardless of how narrow the repro. The entire premise of this programme is that those states are unrepresentable. A single reproducible instance falsifies the premise and is worth more attention than any other defect in the queue.

---

## 14. Decisions required before WP-1 starts

These block the start. Each is a genuine fork where different answers produce materially different work.

| # | Decision | Options | Recommendation |
|---|---|---|---|
| **D1** | **The tactical line.** The clamp branch is unmerged under REQUEST CHANGES for a one-line logging fix, while `main` has no whitespace work at all. | (a) Fix F-N1, merge Phase 1 to `main`, ship it as the interim. Phases 2–3 dropped. (b) Complete Phases 1–3 fully in parallel. (c) Abandon the branch; run on `main` for ~3 weeks. | **(a).** One line of work converts a stalled branch into three weeks of livability, and everything on it is in the deletion ledger anyway. (b) spends real effort on code scheduled for deletion. (c) leaves you on a build with no mitigation at all. |
| **D2** | **Owner allocation.** WP-1 and WP-0 run in parallel and are independent briefs. | Kieran on WP-1 + Bee on WP-0 (as scoped), or serialise on one owner | **Parallel as scoped.** WP-1 has standalone value and does not depend on the spike outcome; serialising adds 2–3 days for nothing. |
| **D3** | **Spike depth.** WP-0 is throwaway code with non-throwaway evidence. | (a) Full G1–G6 as specified, 2–3 days. (b) G1/G2/G6 only (memory, scroll, focus), ~1 day, accept G3/G4/G5 risk into WP-4. | **(a).** G4 (theme port across 8 themes) and G5 (topic swap) are precisely where "it looked fine in the prototype" would cost a week later. The compressed option trades 2 days now for the programme's main schedule risk. |
| **D4** | **Platform target.** Unresolved since Round 3: Bee stated the feature was for BeeChat-Mobile; Q's spec and your instruction said macOS. | macOS only (as scoped), or macOS + iOS parity | **macOS only for this programme.** iOS gets a separate scope once the macOS engine is proven. The `TranscriptBoundary` seam is what makes that cheap later — the document and bridge port; only the host is platform-specific. |

Two further items need noting but do not block:

- **Docs in git.** Several rendering docs have been untracked across multiple rounds, which meant Bee's agents could not see them. Before WP-1, commit `Docs/Specs/Active/` and `Docs/Reviews/` so the whole team is working from the same text. The untracked `Investigations/`, `Reviews/`, `Specs/`, `debug-logs/` directories at repo root also need a decision — commit or `.gitignore`, but not left ambiguous.
- **Bundle identifier.** Scheduled in WP-3, but it gates E2 evidence collection. If WP-0 needs log-based evidence for G1, pull it forward.

---

## 15. Schedule

| Package | Effort | Calendar (parallel-aware) |
|---|---|---|
| D1–D4 decisions | — | Day 0 |
| WP-1 boundary | 1 day | Days 1–2 ┐ parallel |
| WP-0 spike (G1–G6) | 2–3 days | Days 1–3 ┘ |
| **KILL GATE** | — | End of day 3 |
| WP-2 document | 2.5–3.5 days | Days 4–7 ┐ parallel |
| WP-3 host | 2 days | Days 5–7 ┘ (needs contract frozen) |
| WP-4 parity | 2–3 days | Days 8–10 |
| **B4 — default-on gate** | — | Day 10 |
| WP-5 rollout | — | 2 release cycles |
| WP-6 retirement | 0.5 day | After R3 |

**≈ 2 working weeks to flag-on**, unchanged from the route plan — the drift corrections in §3 are absorbed by the WP-2 buffer. Rollout is calendar time and cannot be compressed; that is the point of it.

### Team fit

- **Kieran** — WP-1, WP-3, WP-6 (implementation).
- **Bee** — WP-0, WP-2, WP-4 fixes.
- **Q** — bridge protocol review, B1/B2/B3 sign-off, G3/G5.
- **Mel** — sanitizer/CSP review, theme tokens, G4, P4/P7/P10. Her open sanitizer-location question from Round 3 resolves naturally here: **sanitize-at-inject, one call site.**
- **Adam** — D1–D4, G1/G2/G6, B4, R1–R3.

---

## 16. What "done" means

The programme is complete when:

1. `transcriptEngine` defaults to `.web` and has for two stable releases (R3).
2. The deletion ledger is executed (WP-6).
3. T1–T5 run in CI on every commit.
4. No P0/P1 transcript defect is open.
5. `Docs/Reviews/optionb/` contains a signed evidence artifact for every G, B, P, and R gate — including the failures (E6).

Point 5 is the one that matters in six months. If Option B ships and something regresses in 2027, the evidence trail is what tells the next person whether the premise held or the implementation drifted. Three review cycles were lost on this project for want of exactly that.

---

*Scope document. No code changed. First actionable items: D1–D4 (Adam), then WP-1 and WP-0 briefs. — Fable, 2026-08-04*
