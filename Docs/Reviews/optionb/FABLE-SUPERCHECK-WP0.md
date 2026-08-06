# WP-0 Feasibility Spike — External Super-Checker Review

**Reviewer:** Fable (external, impartial)
**Date:** 2026-08-05
**Scope:** WP-0 kill gate — six gates G1–G6, five disclosed deviations, G1 corrected re-run
**Method:** Evidence read from `spike/transcript-webview` (git), spike source read line-by-line, claims checked against implementation

---

## VERDICT: CORRECTIONS REQUIRED

The premise is **not falsified** — but it is also **not yet validated**. One gate (G1, corrected re-run) is genuine, well-executed evidence for the expensive half of the architectural claim. The gate that tests the *actual bug class* — G2 — cannot fail by construction, because **the scroll engine it exists to validate was never implemented in the spike**.

**Do not start WP-2 or WP-3 on the strength of the current G2.** WP-1 may continue (engine-agnostic, standalone value).

Corrections are cheap: hours of re-run work, not days. Nothing here suggests Exit 1.

---

## 1. The decisive finding (not in the five disclosed deviations)

**The spike's `transcript.html` does not contain the scroll engine.**

Route plan §4.4 specifies the mechanism the entire Option B premise rests on — *"the ~15 lines that replace two months of fighting"*:

```js
let pinned = true;                       // hysteresis: enter 50 / leave 120
scroller.addEventListener('scroll', …);  // maintains `pinned`
const repin = () => { if (pinned) scroller.scrollTop = scroller.scrollHeight; };
new ResizeObserver(repin).observe(transcript);
window.addEventListener('resize', repin);
```

Grepped against `Experiments/TranscriptSpike/Sources/TranscriptSpike/Resources/transcript.html` (429 lines): **zero occurrences** of `ResizeObserver`, zero scroll listeners, no `pinned` state variable, no hysteresis. The only pin machinery is:

```js
pinToBottom() {                                       // transcript.html:249
  const sentinel = document.getElementById('pin-sentinel');
  sentinel.scrollIntoView({ block: 'end' });
  return true;
}
```

An imperative scroll-to-bottom. Nothing observes content growth; nothing re-pins automatically.

**Consequence for G2.** Every single G2 measurement is taken immediately after an explicit `pinToBottom()` call, in the same JS task:

| G2 phase | Source | Pattern |
|---|---|---|
| streaming append | `main.swift:745` | `appendMessage(m); pinToBottom(); return state();` |
| late image | `main.swift:771` | `injectImage(…); pinToBottom();` then read state |
| window resize | `main.swift:843` | `w.setContentSize(s); … evaluate("pinToBottom()")` then read state |
| bounce probe | `main.swift:805` | scroll up 500px; `pinToBottom()`; read `dfb` — same synchronous block |

So `dfb=0px` across all 100+ assertions means *"`scrollIntoView` works."* It does not mean the transcript stays pinned when content grows underneath it — which is the whole bug class. The pre-registered criterion "**Pin state: `true` throughout**" is vacuous: there is no pin state to be true.

This is not a methodology quibble. G1 proves WebKit can hold 427 messages in one bounded process. G2 was supposed to prove the layout/scroll unification actually eliminates whitespace. **That remains untested.**

---

## 2. Adjudication of the five disclosed deviations

### Deviation 1 — G3 oracle: byte-exact → content-in-order · **SOUND**

The rationale is technically correct. WebKit's `Selection.toString()` genuinely does emit inter-block whitespace inconsistently depending on element type (paragraph vs `<table>` vs `<pre>`); byte-exact was the wrong oracle and v1 failing was a real discovery, not an inconvenience. Content-preservation-in-order is what FR-MULTICOPY A1 actually requires. The v1 artefact is durably preserved per E6. This did not gut the gate.

**However — see §3.3. G3 has a separate, undisclosed, more serious problem that the oracle change does not touch.**

### Deviation 2 — G1 process count (original) · **UNSOUND** (correctly rejected) · Re-run: **SOUND**

Kieran was right, and for a stronger reason than stated. The original G1 didn't just conflate system-wide WebContent — it **recorded 920.3 MB against a pre-registered 400 MB budget and returned PASS anyway**, annotating the breach as "(system-wide web RSS included)". A gate that fails its own registered number and reports PASS is the exact failure E3 exists to prevent.

The root cause is in the harness and still live: `sampleRSSHeldByOurWebContent(appPID:)` (`main.swift:218`) takes an `appPID` parameter, discards it (`_ = appPID`), and returns a `ps -ax` tally of every WebContent process on the machine. A function whose name asserts attribution while its body performs none.

**The corrected re-run's attribution method is sound.** Baseline-delta is the right technique, and the reasoning for it is correct: the spike loads `transcript.html` via `loadFileURL` from the *app* process, so the WebContent child holds no `/Users/` handles and pure lsof attribution cannot see it. The disclosure that `~/Library/Containers/com.apple.WebKit.WebContent*` doesn't exist is honest and accurate — WebContent XPC services have no per-app container. Clean-environment setup (27 → 6 baseline) is documented with PIDs. Result — **1 PID (65974), zero spawns, zero recycles, across every sample** — is real evidence and directly answers the Round-3 blowup (12.9 GB, ~500 webviews).

### Deviation 3 — G1 RSS budget (original) · **UNSOUND** · Re-run: **SOUND, but the write-up inverts its own evidence**

Per-spike ≤ 200 MB with an actual max of 103.5 MB is a good result with wide margin.

**Required correction to the document.** `G1-evidence-rerun.md` states the PASS "rests primarily on the spike's own timestamped pre-registered criteria (S1–S5)" with C1–C6 as "corroborating." **This is backwards.** S3 is computed by the same un-attributed system-wide function as the rejected original; in the re-run it reports `webBytes=274415616` (261.7 MB), which the document describes as *"≈ 262 MB spike-attributable + app RSS."* That is false — the spike's own measured contribution is 103.5 MB. The 262 MB is 6 idle residual processes plus the spike. S3 passes in the re-run **only because the environment was cleaned**, not because it attributes anything.

The load-bearing evidence is the C1–C6 attribution overlay. Say so. Also correct the claim that the overlay is "stricter, not loosened" — C1 (`spike_count ∈ {1,2}`) is explicitly *looser* than S2 (`= 1`), as the document itself concedes two paragraphs later. Measured value was 1, so nothing material turns on it, but a gate document should not assert the opposite of its own text.

### Deviation 4 — G4 rAF timing as documented target · **SOUND as a measurement decision; the gate is not passable as written**

Using rAF delta rather than a binary sub-16.7 ms assertion is defensible and pre-authorised by Kieran: a rAF delta cannot resolve a one-frame target, and a signpost shim is genuinely out of spike scope. Recording it as a performance observation is the honest call, not a dressed-up failure. (For the record: 38–96 ms is *not* "well within" anything — it is a fine spike number, but P4 should treat it as a real budget, not a formality.)

**But G4's other pre-registered criterion is "Visual parity target: full-page screencapture vs native bubble chrome reference," artefact `G4-reference-light.png`.** That file does not exist — not in `spike/transcript-webview`, not in the working tree, not anywhere in the repo. The evidence file references it twice, including "Mel to compare against native bubble chrome." Mel has not compared anything, because there is nothing to compare.

G4's verdict reads **"PASS (visual parity + fontScale variable swap works)."** The fontScale half is evidenced. The visual-parity half is asserted with a missing artefact and an uncompleted comparison. **G4 is not PASS.**

### Deviation 5 — G6 first-responder: `=== composer` → `=== fieldEditor(for: composer)` · **SOUND**

Technically correct and not a loosening. `NSTextField` is not itself the first responder while editing; AppKit installs the window's shared field editor (an `NSTextView`) and makes *that* the first responder. Asserting `firstResponder === composer` would fail on a perfectly healthy app. Accepting either is the right check.

Residual limitation (not a deviation, worth noting for P-series): G6 types into a hidden `NSTextField` in a spike window while messages append. It does not test the case that actually worries me — the `WKWebView` attempting to take first responder on click, DOM focus, or process recovery. G6 as run shows AppKit doesn't spontaneously hand focus to a quiescent web view. That is worth something, but it is the easy half.

---

## 3. Undisclosed deviations found in review

These are not in the build report's list of five. Three of them materially affect verdicts.

### 3.1 G2 bounce probe hardcodes its own conclusion · **serious**

`main.swift:791–794`, the probe's own doc comment:

> *"We don't try to **cause** the bug here; we just record baseline behaviour so any future regression has a comparator."*

The probe scrolls up 500 px, then calls `pinToBottom()` **synchronously in the same JS block**, then measures. A bounce is a spontaneous movement across subsequent frames; measuring immediately after an imperative scroll in the same task can only return ≈0. The probe is structurally incapable of observing the phenomenon it is named for.

Worse, `main.swift:821` writes the string `(no P0 — within tolerance)` into the evidence log **unconditionally**, regardless of the measured value.

BUILD-REPORT §7's standing-rule claim — *"No bottom whitespace… the explicit bounce-probe logged `dfb=0px` after scrolling up 500px and re-pinning"* — rests entirely on this probe. **The claim "no P0 observed" is not supported.** Nothing in WP-0 could have detected a P0.

### 3.2 G5's white-flash criterion was announced but never implemented as a gate · **serious**

`main.swift:1211` logs the pre-registered criterion: *"white_flash = non-white background pixels during swap, sampled at 60 Hz."* Three separate problems:

1. **Never gated.** In `evaluateAndExit()` the `fails` array only ever receives `max_swap_ms > 100`. The white-flash result is not consulted in the verdict — at all.
2. **40/40 samples came back pure white (255,255,255)** and were annotated "recorded, not gated — interpretation depends on theme baseline." The detector tripped on 100% of samples and was rationalised in the comment block (`main.swift:1289–1293`) rather than investigated.
3. **Not 60 Hz.** The implementation samples twice per swap (`pre-i`, `post-i`, 50 ms apart) and reads `getComputedStyle(document.body).backgroundColor` — a *style* value, not a rendered pixel. A style read cannot observe a transient composite frame, and pre/post sampling brackets the very interval a flash would occupy.

G5 therefore passes on swap timing alone (4–27 ms, plausible and fine for a 25-node DOM swap). **"No white flash" was not tested.** Given that topic-switch flash is one of the named symptoms, this needs to be a real check at P1.

### 3.3 G3 never touched the pasteboard · **serious**

The gate's own logged criterion (`main.swift:981`) is `paste_target=TextEdit (textedit://) OR NSPasteboard readback`. The evidence file's criteria say *"Cmd+C → paste → plain text must equal the documented oracle."* The build report says *"paste-verify."* The review prompt says *"Cmd+C; paste into TextEdit."*

What the code does (`main.swift:999–1010`): builds a `Range` programmatically, calls `window.getSelection()`, and returns `window.bc.selectionText()` — a JS-side `String(window.getSelection())`. **No `Cmd+C`, no `NSPasteboard`, no TextEdit, no readback.**

This matters because they are different code paths. WebKit writes several pasteboard flavours on copy (RTF, HTML, `public.utf8-plain-text`), and the plain-text flavour is generated by pasteboard serialisation — not by `Selection.toString()`. Table cell → tab conversion and `<pre>` indentation survive differently between them. The v1→v2 oracle discussion even reasons *about* "standard NSPasteboard copy behaviour" (`main.swift:947–949`) while never invoking it.

**FR-MULTICOPY A5 is literally "paste-verified." That is the one requirement WP-0 did not verify**, while reporting that it had.

### 3.4 G1 plateau: the registered criterion is not the criterion evaluated

The 22-minutes-vs-30 disclosure understates this. From `main.swift:597–613`:

```swift
let plateauStart = samples[0].0.addingTimeInterval(TimeInterval(host.config.windowSeconds - 600))
if Date() < plateauStart { return }
let recent = samples.filter { $0.0 >= plateauStart }
if recent.count < 3 { return }              // ← 3 samples = 2 minutes
…
if elapsed >= Double(host.config.windowSeconds) || plateauStable { evaluateAndExit() }
```

- `plateauStart` = start + 1200 s. Earliest possible exit = 1200 s + 3 samples × 60 s = **exactly 22 min**. Both runs terminated at exactly 22 min because the early exit is *structurally guaranteed* on any flat run. The registered `soak_seconds=1800` can therefore never be satisfied by a passing run — the criterion is unreachable by design.
- S5 registers a **600-second** plateau window. The evidence records `plateau_window samples=3 … app_spread_mb=0.0` — a **120-second** window. That is one fifth of the registered observation period.
- **The plateau check reads app RSS only** (`appsOnly = recent.map { $0.1 }`). It structurally cannot detect WebContent growth — the quantity G1 exists to bound.
- The +29 MB WebContent step occurred at 13:38–13:39, i.e. minute 16 — *before* `plateauStart` at minute 20. The gate's plateau window excluded the only growth event in the run, and would not have seen it in any case per the previous point.

Kieran's acceptance ("genuine early-PASS mechanism, not a skip-failure") is right about *intent* and I agree the code is not gaming anything. But intent is not the question: the criterion evaluated is materially weaker than the criterion registered, and nobody has said so.

**On the +29 MB event itself: not a leak signature.** Single bounded step, then six consecutive samples at exactly 103.5 MB (five minutes flat). Leaks are monotonic or sawtooth. Q's guess (JIT warm-up / layout-cache expansion) is plausible. It does **not** undermine the premise. It is unexplained rather than alarming — but note it happened during an *idle* soak with nothing driving the page, which is the genuinely odd part and worth one explanatory pass.

---

## 4. Harness defects (carry into WP-2/WP-3 test code)

| # | Location | Defect |
|---|---|---|
| H1 | `main.swift:218` | `sampleRSSHeldByOurWebContent(appPID:)` discards `appPID` and returns a system-wide tally. Rename or implement attribution; this name produced the 920 MB "PASS". |
| H2 | `main.swift:858` | `worstDFB` parsing splits on `=`, takes the last segment, `dropLast(2)`. For `resize` rows (`"dfb=0px size=760x720"` → `"760x7"`) and `image_inject` rows (`"…url=g2-img-0.png"`) this yields `nil`, coerced to `0`. The tolerance check is inoperative for two of three assertion families. Verdict was carried by `pinOk`, so no wrong result — but a broken assertion in gate scaffolding. |
| H3 | `G1-rerun-pre-registration.log` | Cites source as `Experiments/TranscriptSpike/Sources/.../GateG1.swift`. **No such file exists** — the spike is a single `main.swift`; the class is `G1MemoryGate` (line 553). Nobody verified the provenance claim against the source it cites. |
| H4 | cross-document | G4 rAF values differ three ways: BUILD-REPORT (67/39/75/97), `G4-evidence.md` (71/38/96/96), review prompt (39–97). BUILD-REPORT §4 says G5 had "one -1 race"; `G5-evidence.md` shows no `-1` in any of 20 swaps. |
| H5 | `G1-rerun-pre-registration.log` | An E3 provenance artefact should be a raw extract. This file is majority argumentative prose defending its own validity, wrapped around a 7-line quote. Keep the raw block; move the advocacy to the evidence doc. |

---

## 5. Process and evidence-integrity findings

**5.1 — Evidence was destroyed during this review.** Between two tool calls minutes apart, `Docs/Reviews/optionb/` lost `BUILD-REPORT.md`, `G1-evidence.md`, `G2`–`G6-evidence.md`, `spike-run.log`, and `fixtures/`. Cause: the working tree was switched from `spike/transcript-webview` to `feat/transcript-boundary`. I recovered the committed files from git.

**The re-run's raw log is not recoverable.** The committed `spike-run.log` spans 11:32:30 → 12:12:07 — the *original* run only. The re-run's raw output (13:22–13:44), including the pre-registration block cited as lines 371–377, existed solely as an untracked working-tree file and is now gone. What survives is a written-up document, an annotated excerpt, and a CSV. **The primary raw artefact for the single load-bearing gate no longer exists.**

**5.2 — Gate evidence lives on a branch designated "throwaway — never merged."** It will be garbage-collected. Evidence for a kill gate must outlive the branch that produced it.

**5.3 — Zero gates are signed.** Every evidence file names a verifier *prospectively*. E5 (implementer ≠ signer) is directly violated on two: `G3-evidence.md` and `G5-evidence.md` both list **Operator: Q / Verifier: Q**. "All six gates PASS" is currently one person's self-assessment of their own work.

**5.4 — G2–G6 ran inside G1's original soak window.** G1 started 11:50:07; G2 at 11:50:37, G3 11:50:42, G4 11:50:51, G5 11:51:07, G6 11:51:16 — all five inside the first 70 seconds. BUILD-REPORT §7 attributes the 29→30 blip to this and calls it "transient system state." It is more than that: the original G1 soak was contaminated by five concurrent gates, then measured 20 minutes of an idle window. Resolved for the re-run (run alone), but it explains why the original numbers were never interpretable.

**5.5 — WP-1 has already started.** `feat/transcript-boundary` is checked out and `a008278` is committed, before the kill gate is signed. Low risk in substance — WP-1 is engine-agnostic and has standalone value by design — but the programme's own sequencing says the kill gate gates everything. Either honour it or amend it; don't let it lapse silently.

---

## 6. What is genuinely good

Real credit, without hedging:

- **The G1 re-run is good work.** Kieran's rejection was correct, the response was a proper re-engineering rather than a re-argument, the clean-environment protocol is documented with PIDs and methods, the container-path substitution is disclosed with the reason it was necessary, and the empirical note explaining *why* lsof can't see the spike's WebContent is exactly right.
- **1 WebContent PID, zero spawns, 103.5 MB bounded** is the single most important number in this programme. It directly refutes the Round-3 failure (12.9 GB across ~500 webviews) that killed per-bubble rendering. The expensive risk is retired.
- **G5 swap timings** (max 27 ms, avg 11.85 ms against a 100 ms budget) are plausible for a 25-node DOM swap and are real evidence that atomic topic swap is cheap.
- **Data provenance is exemplary** (BUILD-REPORT §3): DB path, the `BeeChat.sqlite`/`beechat.sqlite` case discrepancy, topic ID, session key, exact SQL, exclusions, ordering, read-only mode, and the re-derived 427 replacing the stale 422. This is the standard the rest of the evidence should meet.
- **E6 was honoured where it was tested** — the G3 v1 artefact is durable and the original G1 was restored rather than overwritten.

---

## 7. Required corrections

Blocking. Ordered by cost.

| # | Correction | Cost |
|---|---|---|
| **C-1** | **Commit all WP-0 evidence to a durable branch** (`main` or a `docs/wp0-evidence` branch), including the re-run artefacts. Re-run G1 if the raw log is considered load-bearing — it currently does not exist. | 15 min |
| **C-2** | **Implement the route-plan §4.4 scroll engine in `transcript.html`** — `pinned` state, scroll listener with 50/120 hysteresis, `ResizeObserver` repin, `window.resize` repin. | ~1 hr |
| **C-3** | **Re-run G2 with all explicit `pinToBottom()` calls removed** from the append / image / resize paths. Pin once at the start; then assert the transcript *stays* pinned as content grows. This is the actual gate. | ~1 hr |
| **C-4** | **Rewrite the bounce probe to try to cause the bug**: scroll up, hold, inject content above and below, wait ≥10 frames, then measure without re-pinning. Remove the hardcoded `(no P0 — within tolerance)` string. Retract the BUILD-REPORT §7 no-P0 claim until this runs. | ~1 hr |
| **C-5** | **Re-run G3 through the real pasteboard**: dispatch `Cmd+C`, read `NSPasteboard.general` `public.utf8-plain-text`, compare against the oracle. Keep the content-in-order oracle (Deviation 1 stands). | ~1 hr |
| **C-6** | **G4: produce `G4-reference-light.png` and have Mel actually perform the comparison**, or restate G4's verdict as "fontScale swap PASS; visual parity NOT ASSESSED." Do not leave a PASS resting on a missing file. | Mel-dependent |
| **C-7** | **G5: either implement white-flash detection properly** (sample during the swap, not pre/post; rendered pixels or a `requestAnimationFrame`-driven readback, not `getComputedStyle`) **or explicitly de-scope it to P1** and remove it from the pre-registered criteria print. Currently it is announced and not evaluated. | ~1 hr or 0 |
| **C-8** | **Correct `G1-evidence-rerun.md`**: state that the attribution overlay is the load-bearing evidence and S3 is system-wide; remove the "≈262 MB spike-attributable" description; drop the "stricter, not loosened" claim for C1. | 20 min |
| **C-9** | **Fix the G1 plateau logic** so the evaluated window matches the registered one (600 s, not 3 samples), and include WebContent RSS — not app RSS alone — in the plateau check. Then either re-run, or amend the spec to register what the code actually does. | ~1 hr + re-run |
| **C-10** | **Obtain real signatures** (E5). At minimum G3 and G5 need a verifier who is not Q. | Scheduling |

**C-2 and C-3 are the ones that gate WP-2/WP-3.** The rest can proceed in parallel.

---

## 8. Improvements to carry into the build phases

1. **Promote the corrected G2 into T-series.** Once C-2/C-3 exist, that harness *is* T1/T2 — an automated assertion that the transcript stays pinned under growth without imperative help. Land it in CI at WP-2 rather than rebuilding it later.
2. **Make the pasteboard round-trip a permanent test.** FR-MULTICOPY has five acceptance criteria; A5 is the only one a headless test can't fake. Build it once in WP-2 and reuse at P6.
3. **Add T5 as previously recommended** — assert no height-reporting protocol exists in the bridge surface. Cheap, and it prevents a future contributor reintroducing `bcHeight` "just for one case."
4. **Retire `sampleRSSHeldByOurWebContent` or make it honest.** The baseline-delta + lsof attribution from the re-run should become the reusable memory-census tool for P12 and post-ship telemetry.
5. **Gate-evidence hygiene rule for the rest of the programme:** raw artefacts are committed *before* the write-up is authored, and the write-up cites committed paths. Two of this milestone's problems (deleted re-run log, `GateG1.swift` citation) are the same root cause — documents written about artefacts nobody re-opened.
6. **One reviewer should grep every gate's pass criteria against its verdict logic** before sign-off. G5's white-flash criterion was printed as pre-registered and never appeared in `fails`. That check takes two minutes and would have caught it.

---

## 9. Confidence

**On the findings: high.** Every claim above is verified against the spike source or git, not inferred from the write-ups. The absent `ResizeObserver`, the absent `G4-reference-light.png`, the absent pasteboard call, the white-flash criterion missing from `fails`, the 22-minute structural exit, and the discarded `appPID` are all directly checkable at the cited lines.

**On the verdict: high.** CORRECTIONS REQUIRED rather than REJECT, because the failures are of *test construction*, not of the architecture. Nothing observed contradicts the premise; G1 actively supports its most expensive claim. But four of six gates do not currently test what they assert, and the one that matters most tests a mechanism the spike never built.

**On the premise itself: moderate-to-high, unchanged by this spike.** My confidence in Option B rests where it did on 2026-07-12 — on the architectural argument that unifying layout and scroll in one engine makes the failure mode unrepresentable, plus WebKit's well-understood behaviour. WP-0 has now added real memory evidence. It has not yet added scroll evidence. After C-2/C-3, it should.

---

## 10. One process observation

This is the second consecutive milestone where the review layer found that a stated criterion was not the criterion evaluated — Round 7's unpersisted `Logger.debug`, and now G5's unreached white-flash check and G2's unimplemented pin state. In both cases the code was written in good faith, the write-up described the intent accurately, and nobody re-read the verdict logic against the criteria list.

The E-rules in the scope document were aimed at *runtime evidence over code inspection*. This milestone shows the complementary gap: **runtime evidence is only as good as the assertion that consumes it.** 100+ green `dfb=0px` lines are worthless if every one is preceded by a manual scroll.

Suggested addition to the evidence standard, for Adam's call:

> **E8 — Verdict-logic audit.** Before a gate is signed, one reviewer confirms that every criterion printed as "pre-registered" appears in the code path that computes the verdict. A criterion that cannot cause a FAIL is not a criterion and must not be printed as one.

---

*External super-check complete. Verdict: CORRECTIONS REQUIRED — C-2 and C-3 gate WP-2/WP-3; WP-1 may continue. — Fable, 2026-08-05*
