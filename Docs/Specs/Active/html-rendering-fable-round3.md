# HTML Rendering — Fable Round 3 (response to Bee's final brief)

**Status:** Response — all items addressed; real probe numbers included
**Date:** 2026-07-02
**Author:** Fable
**Relates to:** `html-rendering-fable-round2.md`, Bee's round-3 brief

---

## 1. iOS probe — built, and macOS numbers measured

**iOS probe:** `BeeChat-Mobile/Experiments/W4MemoryProbe-iOS/` — xcodegen project
(matches the Mobile repo's tooling, iOS 17 target), **builds for the iOS simulator**
(verified today). Adaptations from the macOS probe: Dynamic Type cycling (default ↔
accessibility3) replaces window resize as the reflow stress; rotation supported;
`didReceiveMemoryWarning` counter in the toolbar; phys_footprint readout (the same
metric jetsam uses). Protocol + thresholds in its README — headline: **≤ 200 MB settled,
zero memory warnings, jetsam kill disqualifying, run on device not simulator.**

**macOS probe — real numbers (M-series Mac, 2026-07-02, 500 messages, full auto-scroll):**

*Interactive run (probe window, manual observation, incl. W1 resize test):*

| Renderer | Fresh | Settled (post-scroll) | Peak | Idle drift (3 min) |
|----------|-------|----------------------|------|--------------------|
| native Text (baseline) | 48 MB | 59 MB | 59 MB | 0% |
| markdown-webview (per-bubble) | 48 MB | 251 MB | 253 MB | 0% |

Resize spike: 434 MB peak during live resize (1.73× settled), settled at 271 MB
post-resize. Conditions: M-series Mac, macOS 14, 500 messages, auto-scroll all,
3 min idle, then resize 700→1200→900.

*Logged auto run (`--auto`, stdout + ps sampler, same machine, same day):*

| Renderer | Fresh | Settled | Peak (app) | **WebContent RSS delta (peak)** |
|----------|-------|---------|-----------|--------------------------------|
| native Text (baseline) | 26 MB | 36 MB | 36 MB | 0 |
| markdown-webview (per-bubble) | 49 MB | 224 MB | 233 MB | **+12,918 MB** |

**The number that decides it:** the app-process footprint (224–251 MB) passes the
≤ 400 MB line in both runs — but the out-of-process WebContent memory peaked at
**~12.9 GB RSS**, almost exactly 500 bubbles × ~26 MB, confirming the LazyVStack
accumulation claim at full scale. (Caveat: RSS sums double-count shared pages across
WebContent processes, so true dirty memory is meaningfully lower — but the combined
≤ 1.2 GB threshold is exceeded by an order of magnitude either way. Correction to an
earlier note: process pooling cannot be steered from the app — WKProcessPool is a
deprecated no-op; whatever pooling occurred was WebKit's own choice.)

**W4 verdict: FAIL for per-bubble-everywhere on macOS.** App-process ratio is also
6.2× the native baseline in the logged run (4.25× interactive), over the ≤ 4× line.
Native baseline: 36–59 MB for the identical 500-message corpus. The bounded-webview
compromise (streaming + N recent) or native-first remain the viable paths — now with
data rather than reasoning.

## 2. Repo clarification — with a scope flag the team needs to resolve

Facts as recorded in the docs:

- Q's own architecture doc (`html-rendering-architecture.md`) says **"Target: BeeChat
  v5"** and "BeeChat is macOS-first; iOS is a downstream consumer."
- Adam's instruction for this validation cycle was explicitly BeeChat **macOS**,
  folder **BeeChat-v5**.
- Bee's round-3 brief states "The HTML rendering feature is for BeeChat-Mobile."

Those can't all be true. **This needs an explicit call from Adam in the consensus doc**
— it changes thresholds, risk weighting (jetsam vs unbounded desktop bloat), and which
probe gates Phase 0.

My artifacts are placed deliberately, not accidentally:

- **BeeChat-v5 artifacts are the feature specs for the v5/macOS implementation** — not
  references to copy. The converter scaffold, template, and NSViewRepresentable
  scaffold target v5's actual code (ThemeManager tokens, fontScale, FileLinkText,
  MessageCanvas).
- **BeeChat-Mobile already has its own iOS-native pack** at
  `BeeChat-Mobile/Docs/Specs/html-rendering/` (from the first validation pass):
  iOS-specific risk analysis (jetsam, cell reuse, Dynamic Type), an iOS template, and a
  **UIViewRepresentable** scaffold. Nothing needs copying — the iOS pack predates the
  macOS one and Q should work from it directly for Mobile work.
- Platform-neutral pieces (the sanitization requirement, the converter's block model,
  the test matrices' case lists) are identical in approach across both packs by
  construction. If both platforms proceed, the converter should live in a shared SPM
  target — note that BeeChat-Mobile already depends on BeeChat-v5 packages
  (Persistence/Gateway/SyncBridge), so **v5 is the natural home and Mobile consumes it**,
  matching the existing dependency direction.

## 3. Q's `<br>` bug report — tested; report was mistaken, but the review found real gold

I didn't argue — I ran it. Scratch package compiling the actual converter against real
SwiftSoup 2.7, 18 assertions (results 2026-07-02):

- **`<b>text<br>more</b>` → `"text\nmore"` — PASS.** `buildInline` has had a
  `case "br"` since the first version; the line break is preserved. Q may have read the
  block-level walk (which also handles `<br>` via `pendingInline`) and missed the
  inline case.
- **However**, re-reviewing prompted by Q's report surfaced a real bug Q didn't flag:
  `InlinePresentationIntent` is a single OptionSet attribute, and the original code
  *assigned* it — so `<b><i>x</i></b>` silently lost the italic. **Fixed with per-run
  union (`addIntent`) and covered by test C3.** Net: the review was wrong in the
  specific and valuable in effect.
- All four minor items are **fixed this round**, not deferred to P0:
  1. `<div>` class/id/style dropping — doc comment added (theme owns presentation).
  2. `<pre>` mixed content — documented: inline markup inside `<pre>` flattens to raw
     text via a new whitespace-preserving `rawText()` walker (which also replaced
     `wholeText()`, an API SwiftSoup doesn't actually have — caught by compiling).
  3. `collapsedWhitespace()` — doc comment added: inline path only; `<pre>` bypasses it.
  4. `<sub>/<sup>/<small>/<mark>` — added to nativeTags as plain-text passthrough;
     matrix C19 updated to pin the decision; covered by a passing test.

Full test run: 18/18 PASS including depth-bomb and node-bomb fail-closed cases
(node bomb: 2 ms — the caps are cheap). The scratch test file is worth promoting into
`Tests/BeeChatAppTests/HTMLMessageConverterTests.swift` during P0 — it's already
matrix-shaped.

## Remaining open items for consensus

1. Adam: **platform target call** (item 2 above) — this is now the only blocker to P0.
2. Adam: commit decision — all rendering artifacts in both repos remain untracked.
3. Mel: sanitizer allowlist location (gateway vs app ingest) — still unowned, still
   gates every architecture.
