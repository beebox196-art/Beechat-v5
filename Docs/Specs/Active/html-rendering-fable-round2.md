# HTML Rendering — Fable Round 2 (response to Bee's follow-up brief)

**Status:** Response — all six items addressed
**Date:** 2026-07-02
**Author:** Fable
**Relates to:** `html-rendering-fable-findings.md` (bridge doc), Bee's round-2 brief

---

## 1. "Missing" bridge document — it exists; the gap is git

`Docs/Specs/Active/html-rendering-fable-findings.md` has been on disk since 09:19 today
(7 KB). It is **untracked in git**, as is the whole `Docs/Specs/html-rendering/` pack —
if you're locating files via `git ls-files` or a checkout, you won't see them. Adam holds
the commit decision (the working tree also has unrelated uncommitted changes:
HANDOFF.md, VERSION, VISION.md). Recommendation: commit the rendering docs as their own
commit, separate from those.

## 2. Execution risk: which path ships late vs ships broken

**Pure per-bubble WebView is more likely to ship *broken*. Native-first is more likely
to ship *late*, by a bounded amount. Broken costs more here.**

- Pure WebView's failure modes are **late-surfacing**: everything works in a 20-message
  demo; unbounded memory (LazyVStack retention), scroll-anchor fights, and resize storms
  appear with 500-message topics, long sessions, and real window usage — i.e., after the
  code has "worked" for weeks. Two of the seven failure modes have **no complete
  mitigation**: SwiftUI offers no row-height invalidation (scroll jumps can be reduced,
  not eliminated) and VoiceOver fragmentation is structural. The mitigation list is
  open-ended; that's the signature of ship-broken risk.
- Native-first's risk is **schedule, and it's enumerable**: the converter has a closed
  tag allowlist, a unit-test matrix that is an executable spec (`05-converter-test-matrix.md`),
  no UI-integration risk (plugs into the existing `MessageContent`/`FileLinkText`/theme
  path), and fail-closed behavior to the WebView for everything else. The tail risk is
  fidelity disappointment against Adam's day-one-quality rationale — mitigated because
  the WebView fallback already exists in scaffold form.
- The **bounded hybrid** (findings doc path i) neutralizes the "late" half: ship rich
  rendering *now* via web views for the streaming bubble + N most recent messages
  (bounded count = the risks stay demo-sized permanently), build the converter behind
  it, and let the fallback rate shrink. Build order: sanitizer → bounded WebView
  integration → converter.

## 3. W1/W4 experiments — probe built, thresholds proposed

- **Probe:** `Experiments/W4MemoryProbe/` — SPM app, **builds and links against the real
  tomdai/markdown-webview** (verified today). 500 mixed messages in the same
  `ScrollView + LazyVStack` shape as MessageCanvas, toolbar picker to flip between
  markdown-webview and native-Text baseline in the same harness, live phys_footprint
  readout, auto-scroll to force full instantiation. Also serves W1 (drag-resize the
  probe window). Nobody needs to build anything — `swift run` and read the numbers.
- **Thresholds:** in the probe README. Headline: after a full 500-message scroll,
  app ≤ 400 MB, app + Web Content processes ≤ 1.2 GB, plateau (not climb) at idle,
  no ≥ 100 ms hangs, and ≤ 4× the native baseline. W1 is not binary — pass = no
  stale/overlapping heights, settle ≤ 200 ms after drag end, no main-thread hang ≥ 100 ms
  during the drag.
- **Scope correction:** the brief's "4 GB iPhone SE" ceiling belongs to the
  **BeeChat-Mobile** cycle (that repo has its own iOS spec pack). This probe and these
  thresholds are macOS/BeeChat-v5; do not let the two cycles' numbers cross-contaminate.

## 4. SwiftSoup converter — scaffolded

`Docs/Specs/html-rendering/HTMLMessageConverter.swift`. Design decisions:

- **Block-based output** (`[MessageBlock]`), not one AttributedString: code blocks with
  backgrounds, native `AsyncImage` for images, and per-block theming don't fit a single
  attributed string. Inline styling uses semantic `InlinePresentationIntent`, so
  ThemeManager fonts/colors apply at render time — theme switches restyle without
  reconverting.
- **Fail-closed:** unknown tag, `<table>`, or any resource cap (5k nodes / depth 32 /
  200k chars) → `needsWebView = true` → render the original sanitized HTML in
  MessageWebView. Never partial output presented as complete.
- **Fidelity ceiling** — perfect: paragraphs, headings, bold/italic/strike/underline,
  inline + fenced code (with language), links (http/https/mailto/tel/file — file: routes
  through FileLinkText's existing policy), nested lists, blockquotes, hr, block images.
  Degrades: span styles ignored, inline images → alt text, data:/file: images dropped.
  Falls through: **tables** (the WebView's reason to exist), details/summary, any
  embedded media/forms, unknown tags. Estimate ~95% of agent traffic converts natively —
  **measure it**: log the needsWebView rate for the first week and let data set N.
- SwiftSoup is not yet in Package.swift — one-line SPM addition noted in the file header.

## 5. Converter test matrix — written

`Docs/Specs/html-rendering/05-converter-test-matrix.md`: 26 cases in four tiers
(perfect / degrade / fall-through / parser security) + 5 property-test invariants.
Key security points: converter output is **inert** — the innerHTML/onerror attack class
from the WebView path *does not exist* natively; the surface moves to parse-time DoS
(depth/node/length bombs — capped, fail-closed to the sandboxed WebView) and URL
handling (scheme validation on the parsed URL; `file:` gated by the app's file-open
policy, asserted at the OpenURLAction layer). Unlike the WebView matrix, all of it is
unit-testable — it's an executable spec for item 4.

## 6. Priority ranking of existing deliverables (for Q, assuming native-first/bounded)

1. **HTMLMessageConverter.swift** — the primary build effort; start here.
2. **05-converter-test-matrix.md** — its executable spec; write the tests alongside.
3. **MessageTemplate.html** — still needed day one: the streaming bubble is a web view
   in every candidate architecture, and it's the fallback renderer. No changes required.
4. **MessageWebView.swift** — needed **as-is**. "Few live instances" requires no
   adaptation inside the view: the cap is caller policy (MessageCanvas decides which
   messages get a web view; the representable doesn't care if it's 1 or 500). Optional
   later optimization: a pre-warmed instance pool, only if streaming-bubble creation
   latency ever shows up.
5. **04-architecture-alternatives.md** — remains the decision document until a
   CONSENSUS doc supersedes it; round-2 answers above amend it.
6. **01-risk-analysis.md** — stays relevant as the rationale record ("what we're
   avoiding and why") and as the gating checklist if anyone proposes raising N.
7. **03-test-matrix.md** — acceptance suite for the WebView path (fallback + streaming);
   now has its converter companion (05).

## Asks

- **Adam:** commit decision (item 1).
- **Q:** run the probe (steps in README), bring numbers to consensus; confirm whether
  bounded-webview satisfies the HTML-first rationale.
- **Kieran:** wheel-forwarding + `drawsBackground` questions from the bridge doc stand.
- **Mel:** sanitizer allowlist location (gateway vs app ingest) is now the only
  unowned prerequisite — it gates *every* architecture on the table.
