# P0.0 HTML Rendering — Fable Review of Fix Plan

**Status:** APPROVE WITH CHANGES — sequence is sound; one correction is load-bearing
**Date:** 2026-07-02
**Reviewer:** Fable (architecture author)
**Scope:** commit `b38882b` + the team's four-blocker fix plan. Code-verified, not just
plan-reviewed: HTMLSanitizer.swift, HTMLContentClassifier.swift, MessageWebView.swift,
StreamingBubble.swift, scripts/build-and-install.sh.

---

## Verdict on the four questions

1. **Does the sequence align with the architecture?** Yes — flag-off freeze, sanitizer
   as a blocker, native wiring before flag-on is exactly the designed order. Two
   resequencing changes below.
2. **Concerns on #2 and #3?** Yes, both — detailed below. Neither changes the approach,
   both change the implementation.
3. **Missed issues?** Six, one of which is a correction to your own fix wording that
   would otherwise reintroduce the crash.
4. **ConvertedMessageView?** Implement it, but not verbatim from my sketch — design
   notes below.

---

## Blocker 1 — bundle resolution: fix plan has a bug of its own

Verified: `build-and-install.sh:39` copies only the binary; `MessageWebView.swift:40`
uses `Bundle.main`; the `assertionFailure` at line 42 is inherited from my reference
scaffold — my miss for not flagging it as reference-only behavior. Agreed it must never
crash in shipped code.

**⚠️ Correction to the proposed fix:** "try `Bundle.module` → `Bundle.main` → build
path, never crash" **cannot be implemented as written**. `Bundle.module` is a generated
accessor that itself `fatalError`s when the bundle is absent — it cannot be "tried."
If it's first in the chain, you've reimplemented the crash. Safe resolver order:

1. `Bundle.main.url(forResource:)` (works if the script copies the bundle's contents)
2. Manual probe: `Bundle.main.resourceURL` + known bundle names (`*_BeeChatApp.bundle`),
   checked with `FileManager.fileExists` before touching any Bundle API
3. Embedded fallback template string — log via OSLog, render degraded, never trap

**Stronger recommendation — eliminate the failure class:** the template is one small,
rarely-changing file, and the hand-assembled `.app` makes resource bundles permanently
fragile (this WILL recur with the next resource). Embed the template as a checked-in
Swift string constant (`MessageTemplateHTML.swift`, optionally regenerated from the
.html by a script step). That deletes blocker 1 *and* blocker 4 outright — the resolver
becomes "use the constant." Keep the build-script bundle copy fix anyway for future
resources, but don't let this feature depend on it.

## Blocker 2 — MessageContent wiring: right goal, two implementation constraints

- **Don't route through HTMLContentClassifier — delete it.** Verified: it calls
  `HTMLMessageConverter.convert()` and discards the blocks (its own doc admits it).
  Classification was never a separate component in the design: `convert()` returning
  `needsWebView` IS the classifier. The fix is: **convert once per message at settle
  time, cache the `ConvertedMessage` keyed by message id, branch the view on
  `.needsWebView`.** A "lightweight" classifier would be a second parser to maintain
  — worse, not better.
- **Convert off-main, never in `body`.** SwiftSoup parsing inside a SwiftUI view body
  is scroll-jank by design. Convert where messages settle/load (MessageMapper or the
  view model), store alongside the message. Conversion output is theme-independent
  (semantic attributes; ThemeManager styles at render), so theme switches don't
  invalidate the cache.
- **The streaming→settled "snap" won't fully disappear.** After wiring, the transition
  changes *renderer* (WebView → native), so fonts/margins will shift slightly even when
  both are correct. Acceptable for P0 — but make "transition is visually stable, no
  scroll jump" an explicit smoke criterion so it's judged deliberately, not noticed in
  production.
- Estimate note: 1–2 hr excludes ConvertedMessageView, which this step depends on.
  Budget a half day for wiring + view + selection/a11y parity.

## Blocker 3 — sanitizer: agree emphatically; the regex version is worse than reported

Code-verified bypasses beyond the unenforced allowlist:

1. `NSRegularExpression` `.` does not match newlines by default — a multi-line
   `<script>\n…\n</script>` misses the open+content+close pattern; only the tags get
   stripped and the payload text survives (inert, but garbage in bubbles).
2. Entity-encoded URLs pass: `href="javascript&#58;alert(1)"` — the regex sees no
   `javascript:`, the WebView decodes entities. (Currently saved by the JS-side click
   bridge + navigation delegate — two accidental layers deep is not a security posture.)
3. Single-pass replacement enables tag splicing: `<scr<script>ipt>` → strip inner →
   `<script>` reconstituted.
4. Unquoted `on*` values: the `\S+` arm can eat the closing `>` and corrupt adjacent
   markup.
5. `srcset`, `formaction`, `xlink:href` etc. aren't covered — irrelevant once the
   allowlist is actually enforced, which is the point.

**Parse-and-emit design requirements** (agree with SwiftSoup; these are the sharp edges):

- Walk the parsed DOM: disallowed-but-harmless tags → unwrap (keep children);
  dangerous set (`script/style/iframe/form/object/embed/...`) → remove with content.
- Attributes: strip everything not in `tagAttributes[tag]`; validate `href`/`src`
  schemes on the **parsed, entity-decoded, trimmed URL** (case-insensitive), which
  kills bypass #2 structurally.
- **Set `outputSettings().prettyPrint(pretty: false)` before emitting** — SwiftSoup's
  default pretty-printer reflows whitespace and will corrupt `<pre>` content. This is
  the one that will pass every test except the code-block one and then bite.
- Length-cap before parse (existing `prefix()` mid-tag truncation becomes safe — the
  parser recovers).
- Keep the sanitizer's allowlist ⊇ converter's `nativeTags` relationship documented
  (it's correct today: tables/details survive sanitization for the WebView path).

## Blocker 4 — never crash: agree

Covered by blocker 1's fix (embedded template makes it moot). Pattern for all
feature-flagged rendering code: OSLog error + plain-text fallback. No `assertionFailure`
even in Debug for content-dependent paths — a crash you can only hit with real message
data is a crash in production.

## Confirmed lower-priority items + two additions

- **Links (verified):** `StreamingBubble.swift:35` raw `NSWorkspace.shared.open(url)` —
  directly under MessageWebView's comment saying never to do that. Fix: one shared
  `OpenURLAction`/link-policy used by FileLinkText, ConvertedMessageView, and both
  WebView call sites. Single choke point, and `file:` URLs get FileLinkText's existing
  policy for free.
- **FeatureFlags:** inject the `@Observable` instance via `.environment` instead of
  the singleton + dead `@State`; flag flips then propagate live.
- **cssTokens:** cache per theme change (it's called per WebView update). The
  `#FFFFFF` P3 fallback is a real bug for the more saturated of the 8 themes — convert
  via `NSColor.usingColorSpace(.sRGB)` (clamps correctly), or emit
  `color(display-p3 …)` strings, which modern WebKit accepts.
- **NEW — markdown legacy input is undefined in P0.0.** Q's architecture doc says the
  renderer must accept markdown as legacy input; the shipped pipeline is HTML-only
  end-to-end. Where does markdown→HTML happen — gateway, ingest, or a cmark step
  before sanitize? If agents emit markdown today, the flag-on demo will show literal
  `**asterisks**`. Needs an owner before step 7's smoke test, or the smoke test will
  discover it for you.
- **NEW — converter drops `ol start`/`type`.** The sanitizer allowlists these
  attributes but the converter ignores them — an ordered list resuming at 4 renders
  1-2-3. Cosmetic, matrix-worthy, fine to defer; recording it so it's a decision.

## Sequence — two changes

Proposed → amended:

1. Build script bundle copy — yes (5 min is right) — **plus the embedded-template
   decision (step 0), which may make step 2 trivial**
2. Template resolver — yes, with the `Bundle.module` correction above
3. **Sanitizer rewrite moves here** (was 4) — the native wiring consumes sanitizer
   output; land the real sanitizer before building on it, with its tests written
   *in the same step* (the 05 matrix Tier 1–4 cases are the spec; my 18-assertion
   scratch runner is checked into `Docs/Specs/html-rendering/ConverterSmokeTests.swift`
   as a starting point — it's already matrix-shaped)
4. MessageContent wiring + ConvertedMessageView (was 3) — with the convert-once-cache
   constraint, classifier deleted
5. Link policy unification — yes
6. Remaining tests (bundle resolution, flag round-trip) — converter/sanitizer tests
   should already exist from steps 3–4
7. Smoke: 8 themes, streaming→settled transition stability, links, **plus: kill a
   WebContent process mid-stream (recovery path), theme switch + fontScale change
   mid-stream, and a full regression pass with the flag OFF** (prove "additive" is true)
8. Flag ON for human testing — agreed, gated on all of the above

## ConvertedMessageView — implement, with these deviations from my sketch

The comment sketch was illustrative, not a spec. Design points that matter:

- **Fonts/colors through ThemeManager tokens only** — headings map to a scale on the
  body token (or new typography tokens), never hardcoded sizes, so fontScale keeps
  working.
- **Code blocks: native beats the WebView here** — mono font, horizontal scroll,
  theme `codeBg`, and a copy button (part of the original HTML-first rationale; native
  delivers it more cheaply than JS).
- **Lists:** `HStack(alignment: .firstTextBaseline)` marker + content; ordered markers
  from position (plus `start` if/when the converter carries it); recurse for nesting.
- **Quote:** accent-bar + inset, recursive over child blocks.
- **Images:** `AsyncImage`, height-capped, tap → native viewer/QuickLook. Remote-image
  loading policy is still Mel's open decision — until then images load; flag it in the
  smoke checklist.
- **Selection regression to accept consciously:** per-block `Text` means cross-block
  selection breaks (today's single `FileLinkText` selects the whole message). Option
  for later: merge consecutive paragraph-only blocks into one `Text`. Don't solve in P0;
  do write it down as a known regression.
- **A11y:** `.accessibilityAddTraits(.isHeader)` on headings; blocks give VoiceOver a
  clean element order — this is where the native path starts visibly beating the
  WebView, worth demoing.
- **One `OpenURLAction` environment value** for links — the same policy object as
  everywhere else.

## Bottom line

The halt was the right call and the fix plan is 85% correct as written. The 15%:
`Bundle.module` can't be safely "tried" (embed the template and delete the problem),
the classifier should be deleted rather than optimized, conversion must be cached
off-main, SwiftSoup emit needs pretty-print off, and markdown legacy input needs an
owner before smoke. Flag stays OFF until step 7 passes in full. — Fable
