# HTML Message Rendering Architecture

**Status:** Architecture Assessment — DRAFT
**Date:** 2026-06-30
**Author:** Q (assessment), Adam (direction: HTML-over-markdown)
**Target:** BeeChat v5, post-v0.9.4 stability window
**Supersedes:** `message-rendering-upgrade-brief.md` (which targeted native SwiftUI Markdown via Textual/MarkdownUI)

---

## 1. Context & Decision

BeeChat currently renders agent responses as **plain text with file-link detection only**. The brief `message-rendering-upgrade-brief.md` (2026-06-30) proposed a native-SwiftUI markdown phase first, with WKWebView deferred to v2. Adam has **reversed** that order: **go straight to WKWebView HTML rendering**, treating HTML as the primary format and Markdown as a legacy input the renderer must also accept.

**Why HTML-first (per Adam):**

- Agent output quality — real tables, real code blocks with copy buttons, real blockquotes, collapsible sections — is what HTML gives you on day one. Native SwiftUI markdown (Textual / MarkdownUI) gets us 70% of the way and stalls on the long tail.
- Streaming is simpler with one renderer: replace `innerHTML` on each token, no incremental SwiftUI re-layout.
- BeeChat is macOS-first; iOS is a downstream consumer. WKWebView works on both. The platform split is not the binding constraint anymore.
- Maintenance burden consolidates: one rendering path, one CSS layer, one place to fix regressions.

**Non-goal for v1:** Other AI chat features (voice, attachments inline, MCP rendering). This spec is **rendering only** — turn raw agent strings into rich HTML inside the existing 66%-width bubble.

---

## 2. Current Architecture (What We Read)

### 2.1 Pipeline

```
Message (GRDB row, role + content + agentId + senderName + timestamp)
   │
   ▼
MessageBubble                       (Sources/App/UI/Components/MessageBubble.swift, ~148 lines)
   ├─ HStack layout, 66% width via BubbleWidthModifier + canvasWidth env
   ├─ RoundedRectangle background (bgPanel for assistant, accentPrimary for user)
   ├─ Renders senderName, optional agentBadge, message body, timestamp
   └─ body = MessageContent(message)
            │
            ▼
         MessageContent               (Sources/App/UI/Components/MessageContent.swift, ~16 lines)
            └─ FileLinkText(content: message.content ?? " ")
                     │
                     ▼
                  FileLinkText         (Sources/App/UI/Components/FileLinkText.swift, ~180 lines)
                     ├─ FilePathParser.parse(content) → [ContentSegment]
                     │     5 regex patterns: backtick absolute, backtick home-rel,
                     │     file://, bare absolute, bare home-relative
                     ├─ Cache (FileExistenceCache, 30s TTL) for file-exists coloring
                     └─ Builds AttributedString with .link attributes + OpenURLAction
                        → Text(attributedString) with font + textSelection
```

### 2.2 Streaming path (distinct)

```
MessageCanvas (Sources/App/UI/Components/MessageCanvas.swift)
   ├─ polling, throttled to ~5fps (200ms) — see `streamingContent: String` param
   ├─ LazyVStack contains either MessageBubble (settled) or StreamingBubble (live)
   └─ StreamingBubble                    (Sources/App/UI/Components/StreamingBubble.swift, ~50 lines)
         ├─ Plain Text(content) + animated "▌" cursor (3 styles, theme tokens)
         ├─ Same RoundedRectangle bubble background as MessageBubble
         ├─ Same BubbleWidthModifier (66% width)
         └─ textSelection(.enabled) — already on
```

### 2.3 Theme system (read for mapping)

```
ThemeManager                          (Sources/App/UI/Theme/ThemeManager.swift)
   ├─ @Observable, @MainActor, has currentTheme + fontScale + availableThemes
   ├─ 8 themes: artisanal-tech, dark, light, starfleet-lcars, minimal,
   │            holographic-imperial, water-fluid-ui, living-crystal
   └─ Resolves tokens via:
         color(.token)  → SwiftUI.Color
         font(.token)   → SwiftUI.Font (size × weight × mono × scale)
         spacing(.t)    → CGFloat
         radius(.t)     → CGFloat
         animation(.t)  → Animation
         shadow(.t)     → ShadowDefinition (not exposed in HTML today)

Tokens:
   ColorToken (18 cases):       bgSurface, bgPanel, bgElevated,
                               textPrimary, textSecondary, textOnAccent,
                               accentPrimary, accentSecondary, accentTertiary,
                               success, warning, error, info,
                               borderSubtle, borderDefault,
                               shadowLight, shadowMedium, shadowStrong
   TypographyToken (7):          display, heading, subheading, body,
                                caption, caption2, mono
   SpacingToken (7):             xxs(5), xs(4), sm(8), md(12), lg(16), xl(24), xxl(32)
   RadiusToken (5):              sm(4), md(8), lg(12), xl(16), full(9999)
   ShadowToken (4):              sm, md, lg, glow
   AnimationToken (5):           fast(.15), micro(.2), normal(.3), slow(.5), slower(.6)
```

### 2.4 Persistence layer

```
Message (Sources/BeeChatPersistence/Models/Message.swift)
   - role: String          ("user" | "assistant" | "system")
   - content: String?      ← raw agent output, no format field, no HTML/Markdown marker
   - agentId, senderName, timestamp, sessionKey, topicId, ...
```

**Critical constraint:** the storage layer has **no `contentType` / `format` field**. Today the renderer must *infer* format from content. We will preserve this for v1 (accept mixed input) and flag as a follow-up improvement.

### 2.5 Test baselines

- `FilePathParserTests` (148 lines) — 9+ tests on `FilePathParser.parse()` covering backtick priority, bare paths, file://, home-relative, punctuation stripping. **These tests MUST continue to pass** because the detection logic either stays where it is (HTML render branch) or is shared with the HTML branch.
- `FontScaleTests` — verifies `setFontScale` clamping/rounding behaviour.
- `TopicViewModelTests` — unrelated.
- 155 tests total across the package. Zero regressions allowed.

---

## 3. Module Boundary — Where the HTML Renderer Plugs In

### 3.1 One-line summary

The HTML renderer is a **drop-in replacement** for `MessageContent.swift` + `FileLinkText.swift`. The bubble, canvas, and theming layers do not change.

### 3.2 What changes vs. what stays

| Component | Status | Reason |
|---|---|---|
| `MessageContent.swift` | **REPLACE** | Becomes a thin router: `RichMessageContent(message:)` |
| `FileLinkText.swift` | **REPLACE** (extracted) | Parser logic moves into shared module; FileLinkText as a SwiftUI view goes away |
| `StreamingBubble.swift` | **EDIT** | Body switches to a streaming-capable WebView wrapper |
| `MessageBubble.swift` | **UNCHANGED** | Bubble width, alignment, background, senderName/agentBadge/timestamp stay |
| `MessageCanvas.swift` | **UNCHANGED** | LazyVStack + defaultScrollAnchor + 5fps streaming poll still work |
| `ThemeManager.swift` | **UNCHANGED** (small add) | New `htmlStyleSheet(_:)` extension that emits CSS for current theme |
| `Theme.swift` / tokens | **UNCHANGED** | Token *resolution* is the same; only a new CSS-emission utility is added |
| `FilePathParser` logic | **EXTRACT** | Move into new `RichMessageRenderer` module; tests keep their import path (`@testable import BeeChatApp`) |
| `Message` model | **UNCHANGED** for v1 | Add `contentType` in v1.1 follow-up (see §7.2) |

### 3.3 The interface boundary

The renderer is one SwiftUI view that takes a `Message` (or just a `String`) and emits a theme-aware, height-aware, WKWebView-backed HTML surface. Nothing else in the app needs to know whether the renderer is WKWebView, SwiftUI Text, or an NSView.

```
┌──────────────────────────────────────────────────────────────┐
│  MessageBubble  (unchanged)                                  │
│    ├─ senderName / agentBadge / timestamp (unchanged)         │
│    └─ MessageContent(message)                                │
│         │                                                   │
│         ▼                                                   │
│       RichMessageContent ←────── NEW (replaces MessageContent)│
│         │  decides: is it plain / markdown / HTML?           │
│         │  builds CSS from current ThemeManager tokens       │
│         │  loads HTML or runs markdown→HTML conversion       │
│         ▼                                                   │
│       RichMessageWebView ←────── NEW (NSViewRepresentable)   │
│         │  WKWebView, hidden scrollbars, transparent bg     │
│         │  observes height → reports back to SwiftUI frame  │
│         ▼                                                   │
│       FilePathBridge ←────────── NEW (file-path detection   │
│         │  reuses FilePathParser; injects <a> tags/handlers) │
└──────────────────────────────────────────────────────────────┘
```

**The bubble stays a SwiftUI bubble.** Only the *body* swaps to a WebView. This means the 66% width, the rounded background, the shadow, the alignment, the senderName/badge/timestamp group — all of that keeps working unchanged.

### 3.4 Why this boundary is "modular"

- **No entanglement:** the renderer does not import `BeeChatPersistence` in any non-trivial way (it takes the message as a value type). It does not depend on the canvas, the bubble, the composer, or the topic VM.
- **Self-contained module:** all renderer files live under `Sources/App/UI/Rendering/` (new directory). One folder to delete to roll back.
- **Testable in isolation:** the renderer can be unit-tested without SwiftUI (CSS string generation, markdown conversion, sanitisation). Integration tests still go through the existing `BeeChatAppTests` target.
- **One way to extend later:** add a new mode by adding a case to the `RichContentFormat` enum; no existing code touches the bubble or canvas.

---

## 4. Risks

### 4.1 WKWebView memory per instance in LazyVStack

**Risk:** `LazyVStack` recycles views as the user scrolls. WKWebView instances are heavy — each one holds a JavaScript context and a backing store of ~20–40 MB. Even when recycled, the WKWebView *process* can linger.

**Severity:** Medium-High. BeeChat topic history can grow to hundreds of messages. If every `MessageBubble` ever had a WKWebView instantiated, memory would balloon.

**Mitigations (apply all three):**

1. **Cap rendered web views in window.** Keep a recycling pool of at most N WKWebView instances (suggest N = visible-bubble-count + buffer ≈ 8). Above N, fall through to `AttributedString` rendering for that bubble — same visual shape, less richness. Users rarely scroll fast enough to perceive the swap.
2. **Detach the web view when out of viewport.** Use `WKWebView`'s `pause` API plus `WKUserContentController` messaging to release JavaScript state when `LazyVStack` recycles the cell. Re-attach on re-render.
3. **Profile on a 200-message topic before shipping.** Add a `RichMessageRendererMemoryTests` that creates 200 renderers, scrolls them through visibility, and asserts process RSS stays under 400 MB on a baseline 16 GB machine.

**Gate:** if memory gate fails, fall back to native-SwiftUI markdown (Textual / MarkdownUI) per the original brief. Do not ship the WKWebView path until it passes the gate.

### 4.2 Streaming: incremental injection vs. full re-render

**Risk:** Agent output streams ~5–20 tokens/second. Each token currently triggers a SwiftUI redraw of the `StreamingBubble`. With WKWebView, each redraw could either replace `innerHTML` (cheap, but resets cursor position and selection) or append a text node (preserves cursor but is fiddly with HTML parsing of half-written markdown).

**Decision:** **Full re-render on each poll, but throttled.** The existing `MessageCanvas` already throttles streaming to ~5fps (200ms). We honour that throttle and do `loadHTMLString(...)` on each tick. With a small HTML body (one message worth of tokens), `loadHTMLString` on a paused WKWebView is sub-10ms on Apple Silicon.

**Edge case — incomplete tags mid-stream:** if the agent is mid-way through writing a `<table>` or `**bold`, the resulting HTML may be invalid. **Solution:** detect "unbalanced HTML tags" via a small parser; if unbalanced, defer rendering and append a hidden `<span class="pending">…</span>` containing the raw incomplete fragment. Once balanced, flush. For markdown, render through `cmark` (or Apple `AttributedString(markdown:)`) which already handles incomplete input gracefully.

**Cursor:** drop the visible `▌` cursor inside the web view (HTML+CSS blink). The existing SwiftUI `▌` animation can stay outside the web view as a small overlay aligned to the bubble's right edge — this decouples streaming UX from WebView lifecycle.

### 4.3 Height calculation: WKWebView → SwiftUI layout

**Risk:** WKWebView has its own intrinsic content size that does NOT propagate cleanly to SwiftUI. SwiftUI cannot measure a `NSViewRepresentable` until it has laid out the host `NSView`, and the `WKWebView` itself only knows its height *after* it has parsed and rendered the HTML.

Without intervention, the bubble's `fixedSize(horizontal: false, vertical: true)` (in MessageBubble.swift line ~88) collapses the web view to its frame size, not its content size — text gets clipped.

**Mitigation — three-layer approach:**

1. **Compute height host-side** by running the same HTML through `WKWebView`'s `pageSize` callback (`document.documentElement.scrollHeight`) and reporting it back via a `RichMessageHeightCallback` closure on the SwiftUI side.
2. **Cap height** with a max-height CSS (e.g. `max-height: 70vh; overflow-y: auto`) so absurdly long code blocks don't push the canvas out — turn long content into an internal-scrolling block.
3. **Reserve + reconcile:** set an initial placeholder height (estimate from `content.count / 60 ≈ lines × 24pt`), then refine as the WebView reports its true size via the closure. The placeholder avoids a flash of zero-height on first render.

**Critical detail:** the height-reporting flow runs on `MainActor` and uses `NSViewRepresentable.updateNSView` to set the `frame` to the reported height. Two-frame flicker is acceptable for v1; one-frame if we use a height-caching dictionary keyed by content hash.

### 4.4 Interactions: link taps, text selection, copy

**Link taps:** WKWebView intercepts `<a href="file:///…">` clicks via `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)`. We return `.cancel` and forward the URL to `NSWorkspace.shared.open(url)` — *the same call site used today in `FileLinkText`*. **No change to file-opening behaviour.**

**Text selection / copy:** WKWebView supports native selection by default. We **enable** it. The existing `textSelection(.enabled)` modifier in `MessageBubble`'s content area still works because the SwiftUI bubble itself selects — but selections inside the WebView are a *WKWebView selection*, not a *SwiftUI Text selection*. Two selections are independent; that's fine.

**Right-click / context menu:** WKWebView shows a default context menu (Copy, Look Up, etc.) for free. **No code needed.**

**Accessibility:** the existing `accessibilityElement(children: .combine)` + `accessibilityLabel` on `MessageBubble` (line ~96) continues to work because the *bubble* is still a SwiftUI view; only the body is a WebView. We will add a supplementary `accessibilityLabel` derived from the plain-text content so VoiceOver users still hear the message.

**Tap on streaming bubble:** the existing tap doesn't do anything in `StreamingBubble.swift` — it just exists. Status preserved.

### 4.5 Sanitisation (XSS) — *new risk*

**Risk:** rendering agent output as HTML opens a class of injection issues. Even though the source is "trusted" (our own agent), a compromised or buggy gateway could send `<img onerror="…">` or `<script>` tags.

**Mitigation:** run all agent output through a **whitelist HTML sanitiser** before handing to WKWebView. Specifically:
- Allow: structural tags (`p`, `h1`-`h6`, `ul`, `ol`, `li`, `blockquote`, `pre`, `code`, `table`, `thead`, `tbody`, `tr`, `th`, `td`, `hr`, `br`, `strong`, `em`, `a`, `img`-with-https-only), attributes (`href`, `title`, `alt`, `src`, `class` for our own theme classes only).
- Strip: `<script>`, `<style>`, `<iframe>`, event handlers (`on*`), `javascript:` URLs, `style` attributes with `url(`, `expression(`, etc.
- Use an existing Swift library (e.g. `SwiftHTMLParser` is not enough; we need a sanitiser). Options: vendored `python-bleach` equivalent, or wrap NSAttributedString HTML init with strict filtering. **Recommend:** add a single-purpose `HTMLSanitiser` Swift module with a hand-rolled allowlist parser — agent output is well-formed, we do not need a full HTML5 parser. Bundle ~150 lines.

**Code blocks specifically:** `<pre><code class="language-…">` must survive sanitisation, since that is the dominant agent output. Highlight.js (or Prism) is loaded inside the WKWebView from an in-bundle JS asset — see §5.4.

---

## 5. Proposed Module Architecture

### 5.1 New files

All new code lives under **one new directory**, **`Sources/App/UI/Rendering/`**, so the renderer is a self-contained module that can be deleted in one move:

```
Sources/App/UI/Rendering/
├── RichContentFormat.swift          enum RichContentFormat { case plain, markdown, html }
├── RichMessageContent.swift         public SwiftUI view, replaces MessageContent
├── RichMessageWebView.swift         NSViewRepresentable wrapping WKWebView
├── RichMessageStreamingView.swift   NSViewRepresentable variant with throttled reload
├── RendererCSS.swift                ThemeManager → CSS string (one func per theme scope)
├── HTMLSanitiser.swift              whitelist tag/attribute filtering
├── MarkdownToHTML.swift             Optional: convert markdown→HTML using Apple's markdown parser
├── FilePathBridge.swift             reuses FilePathParser; injects <a> tags in plain/markdown
└── RichMessageHeightCache.swift     content-hash → height cache to avoid re-measure flicker
```

That's 9 files, ~600–900 LoC total. Plus tests:

```
Tests/BeeChatAppTests/RichMessageRendererTests/
├── RendererCSSTests.swift           8 themes × ~6 token checks
├── HTMLSanitiserTests.swift         allowlist/denylist, scripts, on*, javascript:
├── FilePathBridgeTests.swift        plain-text → HTML with file:// links
├── MarkdownToHTMLTests.swift        bold/italic/heading/list/table/code
└── RichMessageRendererMemoryTests.swift  placeholder, run only when env var set
```

### 5.2 Public interface

```swift
// RichMessageContent.swift — the only public entry point consumed by MessageBubble
public struct RichMessageContent: View {
    @Environment(ThemeManager.self) private var themeManager
    let message: Message
    let streamingOverride: String?       // when non-nil, render this string instead (live streaming)
    var maxHeight: CGFloat?              // optional cap; nil = no cap
    var onHeightChanged: ((CGFloat) -> Void)? = nil
    // body: classifies format, sanitises, builds CSS, hosts the WebView
}

// RichContentFormat.swift
public enum RichContentFormat: Sendable {
    case plain           // no markdown, no HTML
    case markdown        // contains markdown tokens but no HTML tags
    case html            // already HTML (verified by sanitiser pass)

    static func detect(_ s: String) -> RichContentFormat { … }
}

// RendererCSS.swift
extension ThemeManager {
    /// Returns a complete `<style>` block sized for our message bubble.
    /// Includes: typography (body, mono), colour palette, code-block theme,
    /// link colour, table styles, blockquote.
    func htmlStyleSheet(for role: MessageRole) -> String
}

// HTMLSanitiser.swift
public enum HTMLSanitiser {
    /// Returns a sanitised copy with dangerous tags/attributes stripped.
    /// Always preserves: headings, lists, tables, code blocks, links (http/https/file).
    /// Always strips: script, style, iframe, object/embed, on*-handlers, javascript: URLs.
    public static func sanitise(_ html: String) -> String
}

// FilePathBridge.swift
public enum FilePathBridge {
    /// Re-runs FilePathParser on text, returns HTML with `<a href="file://…">` injected
    /// for detected paths. Pure function; no cache.
    public static func annotatePlainText(_ text: String) -> String
}
```

### 5.3 How StreamingBubble adapts

`StreamingBubble.swift` changes **only its body**. The bubble outer chrome (HStack, VStack, padding, background, shadow, BubbleWidthModifier) stays as-is. The body's two `Text` views are replaced by one `RichMessageContent`-with-`streamingOverride`:

```swift
// Before
HStack(spacing: 0) {
    Text(content)
        .font(themeManager.font(.body))
        .textSelection(.enabled)
    Text("▌")
        .font(themeManager.font(.body))
        .foregroundColor(themeManager.color(.accentPrimary))
        .opacity(cursorVisible ? 1 : 0)
        .animation(themeManager.animation(.slow).repeatForever(autoreverses: true), value: cursorVisible)
}

// After
RichMessageContent(
    message: nil,                  // streaming has no Message yet
    streamingOverride: content,    // raw string from gateway
    maxHeight: nil,
    onHeightChanged: nil
)
.overlay(alignment: .trailing) {
    Text("▌")
        .font(themeManager.font(.body))
        .foregroundColor(themeManager.color(.accentPrimary))
        .opacity(cursorVisible ? 1 : 0)
        .animation(themeManager.animation(.slow).repeatForever(autoreverses: true), value: cursorVisible)
        .padding(.trailing, 8)
}
```

**Throttling:** `MessageCanvas` already passes the throttled `streamingContent` (5fps). The renderer treats every update as full HTML re-render. The streaming `RichMessageStreamingView` (a thin subclass of `RichMessageWebView`) uses a debouncer: if `updateNSView` is called within 80ms of the last frame, queue the update; once a 80ms quiet window passes, apply. This protects against gateway micro-bursts even if the canvas throttle ever loosens.

**Streaming cursor separation:** the cursor lives *outside* the WebView (SwiftUI overlay) so it survives re-renders without flicker and can be styled with theme tokens directly.

### 5.4 How ThemeManager maps to CSS

A single function `ThemeManager.htmlStyleSheet(for: role)` produces the CSS injected into every message. The CSS uses CSS variables so theme switching flips in O(1) without re-rendering.

```css
:root {
    --bg-bubble:      <theme.color(.bgPanel)>;
    --bg-bubble-user: <theme.color(.accentPrimary)>;
    --fg-primary:     <theme.color(.textPrimary)>;
    --fg-secondary:   <theme.color(.textSecondary)>;
    --fg-on-accent:   <theme.color(.textOnAccent)>;
    --accent:         <theme.color(.accentPrimary)>;
    --link-exists:    <theme.color(.info)>;       /* blue */
    --link-missing:   <theme.color(.textSecondary)>; /* gray */
    --code-bg:        <theme.color(.bgElevated)>;
    --code-fg:        <theme.color(.textPrimary)>;
    --border-subtle:  <theme.color(.borderSubtle)>;
    --border-default: <theme.color(.borderDefault)>;

    --font-body:      -apple-system, "<theme.font(.body).family>", sans-serif;
    --font-mono:      "SF Mono", Menlo, Consolas, monospace;
    --size-body:      <theme.font(.body).size>pt;
    --size-mono:      <theme.font(.mono).size>pt;
    --line-height:    1.5;

    --radius-bubble:  <theme.radius(.xl)>px;
    --radius-code:    <theme.radius(.sm)>px;
    --spacing-md:     <theme.spacing(.md)>px;
    --spacing-lg:     <theme.spacing(.lg)>px;
}
body { font: var(--size-body)/var(--line-height) var(--font-body); color: var(--fg-primary); margin: 0; padding: 0; }
a { color: var(--accent); text-decoration: underline; }
a.file-link-exists   { color: var(--link-exists); }
a.file-link-missing  { color: var(--link-missing); text-decoration: line-through; }
code, pre { font-family: var(--font-mono); font-size: var(--size-mono); }
pre { background: var(--code-bg); color: var(--code-fg); padding: var(--spacing-md); border-radius: var(--radius-code); overflow-x: auto; }
table { border-collapse: collapse; width: 100%; margin: var(--spacing-md) 0; }
th, td { border: 1px solid var(--border-subtle); padding: var(--spacing-sm) var(--spacing-md); text-align: left; }
blockquote { border-left: 3px solid var(--accent); padding-left: var(--spacing-md); color: var(--fg-secondary); }
```

**Theme switch flow:**
1. `themeManager.currentTheme` change fires `@Observable` notification.
2. `RichMessageContent` recomputes the CSS string.
3. WebView's `userContentController` receives a JS message `themeChanged`; HTML's CSS variables are re-read on next paint (CSS Variables are reactive by default — no re-render needed).

**Result:** theme switching is sub-frame. No HTML re-parse. No WKWebView instance recreation. ✅

**Highlight.js (or Prism) for syntax highlighting:** loaded once per process from `Bundle.main.url(forResource: "highlight.min", withExtension: "js")` and reused. Allocated to ~50 KB minified; total JS cost is negligible. Languages: js, ts, py, swift, html, css, json, bash, sql, md. Disabled in `prefers-reduced-motion` contexts.

### 5.5 How FileLinkText path detection bridges to HTML

The path-detection logic in `FilePathParser` does not change. What changes is how the result is consumed:

| Mode | Plain text | Path-detected text |
|---|---|---|
| Today (SwiftUI Text) | `Text(segment.text)` | `Text(attributedString with .link)` |
| HTML renderer | raw text in `<p>` etc. | `<a href="file:///abs/path" class="file-link-exists">display</a>` |

**Implementation:** `FilePathBridge.annotatePlainText(_:)` runs the existing `FilePathParser.parse()`, then walks segments and emits HTML-escaped text + `<a>` tags for `.link` cases. The `<a>` class is `file-link-exists` or `file-link-missing` based on the existing `FileExistenceCache` (which moves into the new module unchanged).

**Bridge contract for HTML input:** if the input is already HTML (detected via the `RichContentFormat` heuristic), we **post-process** the sanitised HTML to inject `<a class="file-link">` around any bare path strings outside `<a>` tags. This is a regex pass on the rendered DOM, not a re-parse, which keeps the existing detector's priority semantics intact.

**Backward-compat for existing tests:** `FilePathParser.parse()` is the only test-covered contract. Its callers stay valid; the test file at `Tests/BeeChatAppTests/FilePathParserTests.swift` imports `@testable import BeeChatApp` and remains green because the symbol path is unchanged.

### 5.6 How height calculation works end-to-end

```
SwiftUI                                              WKWebView
─────────                                            ─────────
RichMessageContent (NSViewRepresentable)
  ↓ makeNSView
RichMessageWebView wrapper
  ├─ creates WKWebView with config + userContentController
  ├─ registers height script handler:
  │    "window.webkit.messageHandlers.bubbleHeight.postMessage(document.documentElement.scrollHeight)"
  │
  ↓ updateNSView(html, theme, …)
  ├─ sets CSS variables (theme change) or
  └─ loadHTMLString(html, baseURL: nil)
        ↓ (async)
      WKWebView parses + lays out
        ↓ (webThread callback)
      JS runs bubbleHeight bridge
        ↓ (MainActor dispatch)
      SwiftUI wrapper receives CGFloat
        ↓
      RichMessageHeightCache[hash(content)] = height
        ↓
      RichMessageContent passes onHeightChanged closure
        ↓
      updateNSView sets `frame.size.height = height`
        ↓
      SwiftUI re-lays out the bubble → bubble grows to fit
```

**Cache:** `RichMessageHeightCache` keys by `SHA256(content.prefix(4096))`. TTL = 60s. Streaming content (which changes) is keyed with `+ "_streaming"` and TTL = 0 (always re-measure during stream, cache on completion).

**Placeholder:** until first measurement arrives, the `NSViewRepresentable` uses a default height of `max(80, content.count / 60 * 24)`. This gives a usable-looking empty bubble during the first ~50ms before JS posts back.

---

## 6. Success Criteria

### 6.1 Functional

- [ ] **FC-1:** An assistant message containing markdown headers (`#`, `##`), bold, italic, bullet lists, ordered lists, GFM tables, and fenced code blocks renders correctly in all 8 themes (manual visual check).
- [ ] **FC-2:** Streaming assistant response renders incrementally without visible lag. Subjectively "no worse than current plain-text streaming".
- [ ] **FC-3:** File paths in any of the 5 existing detection patterns are clickable and open via `NSWorkspace.shared.open`. Existing `FilePathParserTests` pass unchanged.
- [ ] **FC-4:** Code blocks with language hints render with syntax highlighting. Copy button in the WebView's native context menu works.
- [ ] **FC-5:** Theme switching preserves all 8 themes plus light/dark/mixed-mode. Sub-frame switch. No bubble reflow.
- [ ] **FC-6:** `MessageBubble`'s 66% width, background, shadow, sender/badge/timestamp layout is **byte-identical** to today.
- [ ] **FC-7:** `MessageCanvas`'s LazyVStack + auto-scroll + Jump-to-Latest button work unchanged.
- [ ] **FC-8:** Plain-text messages (no markdown, no HTML) render with parity to today's `FileLinkText` output.
- [ ] **FC-9:** If `WKWebView` fails to instantiate for any reason (resource pressure, macOS 14 fallback not present), the renderer falls back to `AttributedString` rendering — *same visual shape, simpler content*.
- [ ] **FC-10:** 155 existing tests pass + new tests added (sanitiser, CSS, memory gate).

### 6.2 Non-functional

- [ ] **NFC-1:** Memory gate — after scrolling 200 messages, process RSS stays under 400 MB on a 16 GB Apple Silicon machine (measured via `RichMessageRendererMemoryTests`, gated by `BECHAT_PERF=1` env var).
- [ ] **NFC-2:** Streaming render latency — first paint of streaming content within 16ms of first token. Subsequent paints within 32ms of each token burst.
- [ ] **NFC-3:** Theme switch latency — under 16ms after `themeManager.currentTheme` flips.
- [ ] **NFC-4:** No regressions in **any** tests that don't directly touch the renderer.

---

## 7. Risks Beyond the Renderer

### 7.1 iOS parity

`WKWebView` is the same code on macOS and iOS. The macOS deployment target is `.v14` per `Package.swift`. iOS target is `.v17`. Both ship `WKWebView`. No platform-specific code paths.

**Outstanding gap:** BeeChat-Mobile does not yet exist as a packaged product per `VISION.md`. When it does, this renderer ships unchanged, but the iOS-side `MessageBubble` and `StreamingBubble` views need to be replicated/adapted. **Out of scope** for v1.

### 7.2 Storage layer enhancement (v1.1)

`Message` has no `contentType` field. Today the renderer must infer: did the agent send markdown, HTML, or plain text? For v1, we make `RichContentFormat.detect(_:)` heuristic (regex-for-`<[a-z]+>`, regex-for-`^#{1,6}\s`, default-to-markdown).

**v1.1 work item:** add `contentType` column + Migration010 to `Message`. The gateway already returns plain markdown today; once we add HTML output to the agent pipeline, it can self-declare the format. Out of scope for v1 renderer.

### 7.3 Apple `WKWebView` quirks on macOS 14

Two known issues to test before declaring v1 ready:

1. **`loadHTMLString` base URL:** without a `baseURL`, `<a target="_blank">` may behave unexpectedly. We'll set `baseURL: URL(fileURLWithPath: "/")` so file:// links resolve predictably.
2. **`prefersDarkMode` and `ThemeManager`:** WKWebView respects system appearance by default. We force `color-scheme` via a `<meta name="color-scheme" content="light dark">` tag and the body uses our CSS variables, ignoring WebView's `prefers-color-scheme`. Manually verify theme switching on system-dark machines.

### 7.4 Highlight.js or Prism licensing & bundle size

Both MIT. Highlight.js core ≈ 50 KB gzipped + per-language packs (~1 KB each). Prism core ≈ 6 KB gzipped. Recommend **Prism** for v1 — smaller, fewer surprises. Add as a SwiftPM dependency or vendored `.js` resource under `Sources/App/Resources/`. Verify with Kieran at design time.

### 7.5 The "fallback to AttributedString" trap

FC-9 says we fall back to `AttributedString` when WKWebView fails. We must keep `FileLinkText` (or its successor) **building and tested**, because the fallback path is the **only** renderer that survives an OOM kill of the WebView process. Don't delete the plain-Text branch — make it the explicitly-tested fallback.

---

## 8. Migration Plan (suggested, for Q/Kieran review)

### Step 0 — Scaffolding (no behaviour change yet)

Add `Sources/App/UI/Rendering/` skeleton + tests. Verify SPM build passes. Add new files only — no edits to existing code.

### Step 1 — Theme CSS emission (no UI change yet)

Implement `RendererCSS.swift` + `RendererCSSTests.swift`. CSS for all 8 themes. Unit-test only. No SwiftUI binding yet.

### Step 2 — Sanitiser + FilePath bridge (no UI change yet)

Implement `HTMLSanitiser.swift` + `FilePathBridge.swift` + their tests. Unit-test only.

### Step 3 — Markdown → HTML

If we keep markdown input compatibility (we do), we need a converter. Options:
- Apple's `AttributedString(markdown:)` is the path of least resistance; convert to HTML via an internal helper. Streaming-friendly: handles partial input.
- Vendor `cmark` or `markdown-it` (~30 KB Swift binary). More faithful to GFM, including tables.

**Recommend:** start with `AttributedString(markdown:)` and migrate to vendored `cmark` only if AttributedString fails on real agent output (it doesn't ship tables yet, last checked).

### Step 4 — WebView wrapper + height reporting

Implement `RichMessageWebView.swift` + `RichMessageHeightCache.swift`. Show a dummy bubble with a static HTML string. Verify height reporting flow.

### Step 5 — Wire RichMessageContent into MessageBubble

Change one line in `MessageBubble.swift`: `MessageContent(message: message)` → `RichMessageContent(message: message)`. Build, smoke-test, verify FC-6 (bubble shape unchanged) and FC-8 (plain text parity).

### Step 6 — StreamingBubble swap

Replace `StreamingBubble.swift`'s body. Verify FC-2.

### Step 7 — Memory gate

Run `RichMessageRendererMemoryTests` against a 200-message topic. If gate passes, ship. If gate fails, fall back to the original brief (native markdown) for v1.

### Step 8 — Kieran structured review

Per `AGENTS.md`, Standard tier triggers a `scripts/review/code-review.sh` pass. Plus an extra review pass because this is a Critical-tier change (architecture shift for the entire message surface).

### Step 9 — Adam manual smoke

All 8 themes, 20-message thread, streamed long response, file-link click, code-block copy, table render.

---

## 9. Open Questions for Kieran + Adam

1. **Textual/MarkdownUI fallback vs. plain `AttributedString` fallback** — if WKWebView fails, what's the *minimum-viable* fallback? (Recommend: `AttributedString` with `FileLinkText`-style path detection, keeping the existing test suite green.)
2. **Streaming render budget** — is 80ms debounce right, or should we tie it to the existing 200ms canvas poll and skip the extra debouncer? (Recommend: skip the debouncer; trust the canvas throttle.)
3. **Table rendering** — agents produce GFM tables. Are we okay shipping without tables for v1 if `AttributedString(markdown:)` proves insufficient, deferring tables to v1.1? (Recommend: yes, defer.)
4. **Image rendering** — out of scope for v1, but should `HTMLSanitiser` whitelist `<img src="https://…">` so v1.1 doesn't require a sanitiser rewrite? (Recommend: whitelist `<img>` with `https` URLs only.)
5. **Memory gate threshold** — is 400 MB on 16 GB the right ceiling, or should we go stricter (300 MB) and force the recycling pool smaller (6 vs. 8)? (Defer to Kieran review.)

---

## 10. References & Inputs Read

| Path | What it gave us |
|---|---|
| `Sources/App/UI/Components/MessageContent.swift` | Current 16-line router; replacement point |
| `Sources/App/UI/Components/FileLinkText.swift` | Regex patterns, `FileExistenceCache`, `AttributedString` build pattern |
| `Sources/App/UI/Components/MessageBubble.swift` | Bubble layout, `BubbleWidthModifier`, `CanvasWidthKey` env |
| `Sources/App/UI/Components/StreamingBubble.swift` | Streaming cursor, plain-Text body |
| `Sources/App/UI/Components/MessageCanvas.swift` | LazyVStack, defaultScrollAnchor, 5fps streaming throttle |
| `Sources/App/UI/Theme/ThemeManager.swift` | Token resolution API (color/font/spacing/radius/animation) |
| `Sources/App/UI/Theme/Theme.swift` | All 8 themes, hex initializer |
| `Sources/App/UI/Theme/Tokens/*.swift` | Token enums + definitions |
| `Tests/BeeChatAppTests/FilePathParserTests.swift` | 9+ tests on path detection (must stay green) |
| `Sources/BeeChatPersistence/Models/Message.swift` | No `contentType` field — confirmed |
| `Package.swift` | macOS `.v14` minimum, Swift 5 mode for App target |
| `Docs/Specs/Active/message-rendering-upgrade-brief.md` | Original direction (native markdown v1, HTML v2) — superseded by this spec |
| `STATUS.md`, `HANDOFF.md` | Project state, near-term priorities, review process |

---

*End of assessment. Hand-off to Q for Phase 1 build once Adam approves direction.*
