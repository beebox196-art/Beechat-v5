# HTML Rendering — Fable Findings & Review Request

> **Round 2 (2026-07-02):** Bee's follow-up brief is answered in
> `html-rendering-fable-round2.md`. New artifacts since this doc:
> `Docs/Specs/html-rendering/HTMLMessageConverter.swift` (SwiftSoup walker scaffold),
> `05-converter-test-matrix.md`, and `Experiments/W4MemoryProbe/` (buildable
> markdown-webview memory probe with pass/fail thresholds).

**Status:** Findings — ready for team review
**Date:** 2026-07-02
**Author:** Fable (Claude, external validation pass requested by Adam)
**Relates to:** `html-rendering-architecture.md` (Q, 2026-06-30), `html-rendering-research.md` (2026-06-30)
**Deliverables:** `Docs/Specs/html-rendering/` — 5-file spec pack (see inventory below)

---

## What this is

Adam asked for an independent validation + scaffolding pass on WKWebView-based HTML
message rendering for BeeChat-v5. The full output is in `Docs/Specs/html-rendering/`:

| File | Contents |
|---|---|
| `01-risk-analysis.md` | What breaks with WKWebView-per-bubble on macOS — memory, performance, a11y, theming, security, 7 specific sharp edges |
| `MessageTemplate.html` | Working bubble template: 8-theme token injection, fontScale, ResizeObserver height reporting, link/file-link bridging |
| `MessageWebView.swift` | `NSViewRepresentable` scaffold: wheel forwarding, `drawsBackground` transparency, leak-safe handlers, WebContent-death recovery |
| `03-test-matrix.md` | 26 HTML edge cases + 9 desktop scenarios with expected outcomes |
| `04-architecture-alternatives.md` | Per-bubble vs single-webview vs native AttributedString, ranked |

**Read order for reviewers:** this doc → `01-risk-analysis.md` → `04-architecture-alternatives.md` → skim the rest.

## ⚠️ Headline: my recommendation conflicts with the current direction

Q's architecture doc records Adam's decision: **HTML-first via WKWebView**, markdown as
legacy input, superseding the native-markdown-first brief. My independent analysis ranks
**per-bubble WKWebView last** of three architectures and recommends native
AttributedString conversion as default with web views as a bounded fallback.

Treat my pack as the adversarial case against the chosen direction — that's what it's
for. If the direction survives the specific failure modes below, it survives review.

## Where I agree with Q's doc / the research doc

1. **HTML as the canonical message format** — no dispute. The disagreement is only about
   the *renderer*, not the format.
2. **Streaming bubble is fine as a web view.** There is exactly **one** `StreamingBubble`
   live at a time; `innerHTML` replacement at the existing ~5fps throttle into a single
   web view is genuinely simpler than incremental native re-layout. My concerns do not
   apply to the streaming path.
3. **Agent-response-only scope** (research doc) bounds the problem usefully — user
   bubbles stay native/plain.
4. **`markdown-webview`'s mechanics are sound** — its auto-height approach is the same
   ResizeObserver pattern as my template, and its markdown-it pipeline handles the
   "markdown as legacy input" requirement client-side.

## Where I disagree — the specific failure modes to review

1. **`LazyVStack` retention makes per-bubble web views unbounded.** `MessageCanvas` uses
   `ScrollView + LazyVStack`, which creates views on demand and **never releases them**.
   A 500-message topic accumulates up to 500 live WKWebViews for the window's lifetime
   (5–20 MB in-process + 10–40 MB/document out-of-process each; no jetsam ceiling on
   macOS). The research doc's "surprisingly smooth with multiple instances" is the
   author's benchmark, not this container at this scale. → Risk doc §1, matrix W4.
2. **Async height reporting vs scroll anchoring.** Heights arrive placeholder-then-jump;
   `MessageCanvas` already carries a 4px-anchor workaround that late height changes will
   destabilize when paging history. → Risk doc §2.
3. **Live window resize** reflows every live web view through the JS bridge on every
   width change — a desktop-only stress the iOS-oriented benchmarks never see. → matrix W1.
4. **Wheel-event interception:** macOS WKWebView has no `scrollView`; unmodified it
   swallows transcript scrolling. `markdown-webview` does not handle this; my scaffold's
   `BubbleWebView` subclass does. → matrix W5.
5. **Eight-theme system:** `prefers-color-scheme` can only express two states; every live
   web view needs the full ThemeManager token set pushed on theme switch, and before
   first paint. Stylesheet injection in `markdown-webview` would need the same plumbing.
6. **Security:** agent HTML must be sanitized natively at ingest (`<img onerror=…>`
   executes through innerHTML). Neither existing draft covers sanitization. → Risk doc §6,
   matrix cases 21–25.
7. **WKProcessPool is a deprecated no-op since macOS 12** — WebContent process count
   cannot be controlled from the app. (Corrected during this pass; any pooling assumptions
   inherited from older advice are stale.)

## Paths that reconcile the conflict (for the consensus doc)

- **(i) Keep HTML-first, bound the web views:** web view for the streaming bubble +
  the N most recent settled messages (say 20–30), native AttributedString conversion for
  older history as it settles/loads. Caps live web views at a constant; keeps Adam's
  day-one rich output.
- **(ii) Single-webview transcript** (my alternative B): removes height-bridging and
  resize storms entirely, at the cost of rebuilding MessageCanvas/selection/menus in JS.
- **(iii) Full native-first hybrid** (my alternative C, ranked #1): SwiftSoup →
  AttributedString extending the existing FileLinkText pipeline; web view only for
  table-heavy messages. Highest polish ceiling, but slowest to first rich output —
  which cuts against Adam's stated day-one-quality rationale.

My read: **(i) is the pragmatic consensus candidate** — it honors the HTML-first
decision while neutralizing the two worst failure modes (unbounded accumulation,
resize storms), and it can evolve toward (iii) later without waste, since the
template/scaffold/sanitizer are shared.

## Questions for reviewers

- **Kieran (impl review):** does the scaffold's wheel-forwarding split (vertical → transcript,
  horizontal → in-document) hold up against `MessageCanvas`'s existing scroll handling?
  Is `drawsBackground` KVC acceptable for our distribution story?
- **Q (architecture):** does bounded-webview (i) satisfy the HTML-first rationale? What's
  the retention story if we stay on `LazyVStack` — or do we take this moment to move the
  transcript to a recycling container?
- **Mel:** sanitization policy — allowlist location (gateway vs app ingest), and remote
  image loading policy (privacy leak vs convenience).
- **Anyone adversarial:** run matrix W1 (live resize) and W4 (500-message scroll,
  Activity Monitor) against a `markdown-webview` prototype before committing — those two
  scenarios are where the direction lives or dies.

## Verification notes

- Scaffold compiles against the macOS 14 SDK (SourceKit-checked; the WKProcessPool
  deprecation was caught this way). Not yet added to the app target or run — it is
  reference scaffolding, not shipped code.
- Test matrix outcomes are *expected* behavior, not yet executed — they're the
  acceptance criteria for whichever prototype gets built.
