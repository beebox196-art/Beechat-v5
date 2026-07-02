# HTML→AttributedString Converter — Test Matrix

Companion to `03-test-matrix.md` (which remains the acceptance suite for the WebView
path). This matrix covers `HTMLMessageConverter` — the primary build effort under the
native-first/bounded architecture. Unlike the WebView matrix these are **unit-testable**:
input HTML → expected `[MessageBlock]` or `needsWebView`, no UI harness needed. Suggested
home: `Tests/BeeChatAppTests/HTMLMessageConverterTests.swift`.

## Tier 1 — Handle perfectly (exact block/attribute assertions)

| # | Input | Expected |
|---|-------|----------|
| C1 | `<p>Hello bee</p>` | `[.paragraph("Hello bee")]` |
| C2 | `<p>a</p><p>b</p>` + stray `<br>` | Two paragraphs; `<br>` → newline inside a paragraph, never an empty block |
| C3 | `<b><i>x</i></b>`, `<strong>`, `<em>`, `<s>`, `<del>`, `<u>` | Correct nested `inlinePresentationIntent`/strike/underline attributes |
| C4 | `bare text with <b>bold</b> tail` (no block wrapper) | One paragraph; **boundary spaces preserved** ("bold tail", not "boldtail") |
| C5 | `<code>let x</code>` inline | `.code` intent, single paragraph |
| C6 | `<pre><code class="language-swift">…\n…</code></pre>` | `.codeBlock(language: "swift", code:)` with **newlines preserved** (wholeText, not text()) |
| C7 | `<h1>`–`<h6>` | `.heading(level:)` 1–6 |
| C8 | `<ul>`/`<ol>` nested 3 deep | `.list(ordered:items:)` recursion; non-`<li>` children ignored |
| C9 | `<blockquote><p>a</p><blockquote>…` | Nested `.quote(blocks:)` |
| C10 | `<a href="https://…">`, `mailto:`, `tel:`, `file:///Users/openclaw/x.md` | `.link` attribute set; `file:` flows to FileLinkText's existing open policy |
| C11 | `<img src="https://…" alt="chart">` between paragraphs | `.image(source:alt:)` block; surrounding text splits into separate paragraphs |
| C12 | `<hr>`, whitespace-only input, empty string | `.rule`; `[]`; `[]` |
| C13 | Long unbroken 300-char token | Single paragraph, content intact (wrapping is Text's job, not the converter's) |
| C14 | RTL/bidi mixed text | Content preserved verbatim; direction is handled by native Text layout |
| C15 | HTML entities `&amp; &lt; &#128029;` | Decoded by SwiftSoup: `& < 🐝` |

## Tier 2 — Degrade gracefully (documented, asserted degradation)

| # | Input | Expected degradation |
|---|-------|----------------------|
| C16 | `<span style="color:red">x</span>` | Style ignored; plain text "x" (theme owns color) |
| C17 | Inline `<img>` mid-sentence | Alt text substituted inline (block images only) |
| C18 | `<img src="data:…">` / `<img src="file:…">` | Dropped (alt text if present) — policy: no data-URI/file images natively |
| C19 | `<sub>/<sup>/<small>/<mark>` | **Decision pinned (round 3):** in nativeTags as plain-text passthrough — content kept, sub/sup/small/mark effect dropped. |
| C20 | Malformed: unclosed `<b>`, stray `</div>`, `<p><ul>…` | SwiftSoup error-recovery tree converts without throwing; formatting may extend to message end; never crashes |
| C21 | `javascript:`/`data:` hrefs | Link attribute **not** set; inner text kept |

## Tier 3 — Fall through to WebView (`needsWebView == true`)

| # | Input | Why |
|---|-------|-----|
| C22 | Any `<table>` | Grid layout is the WebView's entire reason to exist |
| C23 | `<details>/<summary>` | Interactive disclosure has no attributed-string equivalent |
| C24 | `<video>/<audio>/<iframe>/<svg>/<form>` | Should already be sanitizer-stripped; if one survives, fallthrough is defense-in-depth |
| C25 | Unknown/custom tags | Allowlist is closed — unknown means "render with the engine that understands it" |
| C26 | Input > 200k chars | Resource cap |

## Tier 4 — Parser security (different attack surface than innerHTML)

The converter's output is **inert** — no script execution surface at all; that's the
native path's core security win. The attack surface moves to (a) the SwiftSoup parse
itself (DoS) and (b) what we do with extracted URLs. All caps must fail **closed to the
WebView path** (whose WebContent process is sandboxed and crash-isolated), never crash
the app.

| # | Input | Expected |
|---|-------|----------|
| S1 | 10,000 nested `<div>`s (depth bomb) | Bails at maxDepth=32 → needsWebView; **no stack overflow** (recursion depth is capped before the walk recurses) |
| S2 | 100,000 sibling `<b>x</b>` (node-count bomb) | Bails at maxNodes=5,000 within bounded time (< 50 ms) |
| S3 | Single 5 MB text node / attribute value | Length cap rejects before parse |
| S4 | Entity flood `&amp;amp;amp;…` | SwiftSoup decodes once, no recursive expansion (HTML ≠ XML: no custom entities / billion-laughs); assert linear time |
| S5 | Invalid UTF-8 / mixed encodings in content | Parse succeeds or bails; never traps on String conversion |
| S6 | `<a href="  javascript:alert(1)">`, `<a href="JAVASCRIPT:…">`, `<a href="java\tscript:…">` | Scheme check happens on the **parsed URL**, case-insensitively; whitespace/control-char smuggling doesn't produce a live link |
| S7 | `<a href="file:///etc/passwd">` | Link attribute set BUT open action must route through the app's file-open policy (FileLinkText) — asserted at the OpenURLAction layer, not the converter |
| S8 | Attribute flood: one tag with 10,000 attributes | Counts against node budget or parses in bounded time; no quadratic blowup |
| S9 | Deeply nested `<blockquote>` (recursive block type) | Same depth cap as S1 — the *block* recursion is the stack risk, not just inline |
| S10 | Fuzz corpus (SwiftSoup round-trip of /dev/random snippets, 1k cases) | Zero crashes; every case returns blocks or needsWebView |

## Invariants (property tests)

1. **Totality:** for any string input, `convert` returns without throwing or crashing.
2. **Fail-closed:** any cap/unknown-tag exit yields `needsWebView == true`, never partial blocks presented as complete.
3. **Idempotent display:** converting the same input twice gives equal `ConvertedMessage` (safe to cache).
4. **No active content:** output blocks contain only text, semantic attributes, validated URLs — grep-level assertion that no block carries executable/HTML payloads.
5. **Time bound:** any input under the length cap converts in < 50 ms on the slowest supported Mac (protects the ingest path; conversion is off-main but backpressure still matters for streaming settle).
