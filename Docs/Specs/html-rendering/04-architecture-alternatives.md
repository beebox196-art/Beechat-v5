# HTML Message Rendering — Architecture Alternatives (macOS)

Three candidate architectures for rendering HTML message content in BeeChat-v5, plus the
recommended hybrid. Context: macOS 14+ SwiftUI app; transcript is `ScrollView + LazyVStack`
(`MessageCanvas`); bubbles already render via `MessageContent` → `FileLinkText`
(**AttributedString**); theming is eight custom hex-token themes (`ThemeManager`) with a
user `fontScale`.

---

## A. Per-bubble WKWebView (the proposed approach)

Each bubble embeds a `WKWebView` via `NSViewRepresentable`; JS reports intrinsic height.

- **Memory: poor — and unbounded in this codebase.** `LazyVStack` never releases created
  views, so scrolling a long topic accumulates live web views for the window's lifetime
  (5–20 MB in-process + 10–40 MB/document out-of-process each). No jetsam ceiling on
  macOS — the app just bloats. `WKProcessPool` is a deprecated no-op since macOS 12, so
  WebContent process count isn't even controllable.
- **Performance: poor.** Async height round-trip → placeholder-then-jump rows that defeat
  `MessageCanvas`'s scroll anchoring; out-of-process paint pop-in per bubble; and the
  macOS-specific killer: **live window resize** reflows every live web view through the
  JS bridge on every width change. Wheel-event forwarding hacks required just to scroll.
- **Accessibility: poor.** VoiceOver fragments into per-bubble web areas; the app's
  `fontScale` must be manually injected everywhere; Cmd+F/cross-bubble selection break.
- **Maintenance: medium-high.** Template + bridge are contained (see scaffold), but you
  own sanitization, wheel forwarding, context-menu stripping, 8-theme token plumbing,
  process-death recovery, and resize-storm mitigation forever.

## B. Single WKWebView renders the whole transcript

One web view is the chat surface; messages are DOM nodes; SwiftUI keeps the shell
(sidebar, composer, sheets). The email-client architecture applied to chat.

- **Memory: good.** One document regardless of message count; needs JS DOM windowing for
  very long histories.
- **Performance: good.** Heights are internal document layout — no bridging, no jumps;
  window resize is one ordinary document reflow, which WebKit is extremely good at. This
  single-handedly removes A's two worst defects.
- **Accessibility: fair.** One coherent web area with stable order; but everything is
  web-flavored rather than native, and Full Keyboard Access / VO interop needs real work.
- **Maintenance: high.** `MessageCanvas`, `MessageBubble`, `Composer` scroll integration,
  jump-to-latest, streaming bubbles, ThinkingBee, selection — all reimplemented in
  HTML/JS. Two UI stacks, two theme implementations (the 8 themes would need full CSS
  ports), JS tooling in an SPM repo. Effectively a rewrite of the app's core surface.

## C. Native conversion — HTML → AttributedString / TextKit

Convert HTML to `AttributedString` at ingest and render in native `Text`/`NSTextView`
inside the existing bubbles. **v5 is already halfway here:** `FileLinkText` builds
AttributedStrings with link attributes, and `ThemeManager.font(_:)`/`fontScale` apply to
native text for free.

- **Memory: best.** Kilobytes per message; no extra processes; LazyVStack retention
  becomes harmless (retained `Text` views are cheap).
- **Performance: best.** Synchronous layout → heights known up front → no scroll jumps,
  and window resize reflows natively in-frame. Conversion runs off-main at receive time
  and caches (GRDB row or in-memory).
- **Accessibility: best.** Native text keeps VoiceOver order, `.textSelection(.enabled)`,
  fontScale, and all eight themes exactly as today.
- **Maintenance: medium.** The cost is the converter. **Do not use `NSAttributedString(html:)`**
  — on macOS it is also WebKit-backed, main-thread-only, slow (~50–200 ms/message), and
  crash-prone. Use SwiftSoup (SPM) → DOM walk → `AttributedString`, mapping tags to
  ThemeManager tokens/fonts at render time so theme switches restyle instantly. Real
  limitation: **fidelity ceiling** — tables and arbitrary CSS don't map to attributed
  strings; those need a fallback path.

---

## Rankings (1 = best)

| Dimension | A: per-bubble web view | B: single web view | C: native conversion |
|---|---|---|---|
| Memory | 3 | 2 | **1** |
| Performance (scroll + window resize) | 3 | 2 | **1** |
| Accessibility | 3 | 2 | **1** |
| HTML fidelity | 1 (tied) | 1 (tied) | 3 |
| Maintenance cost | 2 | 3 | **1** (converter is bounded; and v5 already has the AttributedString pipeline + theme/font plumbing) |
| **Overall** | **3rd** | **2nd** | **1st** |

## Recommendation: C as default, A as bounded escape hatch

The gap between C and the alternatives is *wider* on macOS than iOS: live window resize
punishes per-bubble web views harder, the eight-theme system makes native token styling
much cheaper than CSS plumbing, and `FileLinkText` means the AttributedString rendering
path already exists.

1. **Classify at ingest.** If a message's HTML uses the native-friendly subset (paragraphs,
   inline styles, links, lists, blockquotes, code, images), convert off-main via
   SwiftSoup → `AttributedString`, cache, and render through the existing
   `MessageContent`/`FileLinkText` path. Expect ~95%+ of real traffic.
2. **Complex messages (tables, heavy markup)** render per-message with
   `MessageTemplate.html` + `MessageWebView.swift` from this folder — as the exception,
   so only a handful of web views are ever live, neutralizing A's memory and resize
   problems.
3. **Sanitize once, natively, at ingest** regardless of render path.

**If product requires pixel-perfect HTML in every bubble**, choose **B** over A — it
converts per-bubble height bridging (A's worst defect) into ordinary document layout.
Per-bubble WKWebView as the default renderer for every message is the one configuration
BeeChat-v5 should not ship: it stacks WKWebView's weaknesses directly on top of
LazyVStack's retention behavior and the desktop resize model.
