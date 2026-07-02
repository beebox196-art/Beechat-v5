# Markdown→HTML Step — Library Decision (Fable)

**Status:** Decision — cmark-gfm via apple/swift-cmark; Q green-lit
**Date:** 2026-07-02
**Context:** P0.0 pipeline works for HTML input; agents emit markdown. Conversion step
needed before HTMLSanitizer.

## Decision: cmark-gfm (option 2)

Pipeline: `raw agent text → cmark-gfm → HTML → HTMLSanitizer → convert/classify → render`.

**Why not option 3 (regex converter):** we just spent a review cycle executing a
regex sanitizer for cause. Markdown is worse regex territory than HTML — nested
emphasis, fenced code containing markdown syntax, lazy list continuation. "Covers 90%"
means one in ten messages renders garbled, and the failures will be the complex
messages this feature exists for. No.

**Why not option 1 (swift-markdown) — yet:** apple/swift-markdown is *built on*
cmark-gfm; options 1 and 2 share the same engine. swift-markdown adds an AST layer we
don't need for "give me HTML" — but that AST enables a real future optimization:
markdown AST → `[MessageBlock]` directly, skipping the HTML→SwiftSoup round-trip for
the native path entirely. Earmark that for post-P0; switching cost is low precisely
because both sit on the same cmark core.

**Why GFM specifically matters:** agents emit tables, strikethrough, task lists,
fenced code, autolinks — that's GitHub Flavored Markdown, not CommonMark. Plain
CommonMark would silently drop the tables that justify the WebView path.

## Implementation notes for Q

1. **Dependency:** `apple/swift-cmark` (the cmark-gfm fork Apple maintains for
   swift-markdown/DocC), product `cmark-gfm` + `cmark-gfm-extensions`. Battle-tested at
   GitHub scale; C boundary is one function (UTF-8 in, HTML out).
2. **Extensions on:** `table`, `strikethrough`, `autolink`, `tasklist`. Smart
   punctuation **off** (don't mangle quotes near code).
3. **`CMARK_OPT_UNSAFE` on — deliberately.** Default cmark strips/escapes raw HTML
   embedded in markdown; our direction is HTML-first, so inline HTML from agents is
   legal input and must pass through. Safety is **HTMLSanitizer's job and only
   HTMLSanitizer's job** (it's documented as the authoritative layer) — one enforced
   choke point beats two half-layers. This flag is safe *only* because the sanitizer
   rewrite (parse-and-emit) landed; do not flip it on any build where the regex
   sanitizer is still live.
4. **Insert point:** ingest/settle, immediately before sanitize; cache alongside the
   sanitized HTML. Streaming: convert the throttled buffer per tick (cmark is
   microseconds at our 200K cap; the existing 5fps throttle already bounds it). An
   unclosed code fence mid-stream renders as code-to-end-of-buffer for a tick or two —
   acceptable streaming artifact, self-heals on the next tick.
5. **Don't auto-detect markdown vs HTML.** Treat all agent content as markdown for P0
   (raw HTML passes through under UNSAFE). Known edge: HTML indented ≥4 spaces becomes
   a code block under markdown rules — if an HTML-emitting agent appears later, add a
   `format` field to the gateway message protocol and branch on it; heuristic sniffing
   will misfire on exactly the mixed messages that matter.
6. **Pipeline coherence for free:** cmark emits fenced code as
   `<pre><code class="language-swift">` — exactly the convention HTMLMessageConverter
   already parses for the language tag, and `class` on pre/code is already in the
   sanitizer's attribute allowlist. Tables flow through the sanitizer (allowlisted) and
   trip `needsWebView` in the converter as designed.
7. **Tests:** table → `needsWebView` end-to-end; fenced code language round-trip;
   task list → checkbox degradation decision (converter currently has no checkbox —
   plain-text degrade, pin it in the matrix); raw-HTML-in-markdown passthrough →
   sanitizer enforcement (the UNSAFE + sanitizer contract, most important case);
   4-space-indented HTML edge documented as known.

Home: `Sources/App/Rendering/MarkdownToHTML.swift`, thin wrapper, no state.
