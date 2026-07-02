# HTML Message Rendering Research — BeeChat macOS (SwiftUI)

**Date**: 2026-06-30  
**Goal**: Rich HTML rendering for AI agent response bubbles only (headers, tables, code blocks, styled text). User input remains plain. Must be modular and reusable.

**Key Finding**: Strong existing packages exist. Primary recommendation is **transplanting `tomdai/markdown-webview`** rather than building from scratch.

---

## 1. Proven Swift Packages for HTML/WKWebView in SwiftUI Bubbles

### Primary Recommendation: `tomdai/markdown-webview`
- **Repo**: https://github.com/tomdai/markdown-webview
- **Why it fits perfectly**:
  - Auto-adjusting height (matches content exactly — critical for message bubbles).
  - WKWebView under the hood with `markdown-it` + `highlight.js`.
  - Syntax highlighting, tables, task lists, GitHub-flavored Markdown.
  - Text selection support.
  - Custom stylesheet injection.
  - `.onLinkActivation` handler (ideal for `file://` paths).
  - Dynamic content updates supported.
  - Surprisingly smooth in scroll views with multiple instances (per author benchmarks).
- **Platforms**: macOS 11+, iOS 14+.
- **macOS requirement**: Enable "Outgoing Connections (Client)" capability.
- **Usage pattern** (response bubble only):
  ```swift
  MarkdownWebView(agentMarkdown)
      .onLinkActivation { url in
          if url.scheme == "file" { handleFileLink(url) }
      }
  ```
- **Theme syncing**: Pass custom CSS via `customStylesheet` (light/dark + BeeChat palette).

### Strong Alternative: `NuPlay/RichText`
- **Repo**: https://github.com/NuPlay/RichText
- Direct HTML renderer (not Markdown).
- Dynamic height, async/await, theme support (`colorScheme(.auto)`), custom CSS, link/media handlers, error handling, placeholders.
- Excellent for cases where agents emit raw HTML.
- macOS 12+ / Swift 5.9+.
- Slightly heavier API but very polished.

### Others Considered
- Custom `UIViewRepresentable` + `WKWebView` wrappers (common pattern in tutorials) — avoid unless specific needs.
- `swift-markdown-ui` (native) — insufficient for complex HTML/tables/code highlighting per community reports.
- Stream Chat Swift AI components — rich (Markdown, code blocks, tables, thinking indicators) but tied to Stream SDK. Not a standalone transplant.

---

## 2. Architecture: Single WKWebView vs Per-Bubble

**Production reality**:
- **ChatGPT macOS**: Primarily native SwiftUI/AppKit. Rich responses use native components or hybrid OWL (OpenAI Web Layer) for complex web content. Not per-bubble webviews.
- **Claude Desktop**: Full Electron (Chromium). Everything is one web context.
- **Community consensus for SwiftUI chat apps**: **Single shared WKWebView** for the entire message list is strongly preferred for performance.

**Why per-bubble is problematic**:
- Each `WKWebView` spawns heavy WebKit processes + significant memory.
- `LazyVStack` does not efficiently reuse/release views → memory bloat, stuttering.
- Height calculation is non-trivial (no intrinsic content size).

**Recommended pattern for BeeChat**:
- Use `markdown-webview` (or custom wrapper) **per response bubble** only if message count stays moderate (< ~50 visible).
- For high-volume chats: Consider single embedded `WKWebView` + JS-driven incremental rendering for the whole list (more complex but scales better).
- Start with per-bubble `markdown-webview` (modular, quick win) and profile.

---

## 3. Performance Characteristics

- **Memory**: High per instance. Multiple concurrent `WKWebView`s in `LazyVStack` can cause rapid growth and scroll jank.
- **Scroll performance**: `markdown-webview` author claims smooth scrolling even with many instances. Real-world testing required.
- **Height calculation** (required for bubbles):
  - Disable internal scrolling: `scrollView.isScrollEnabled = false`.
  - Use `WKNavigationDelegate.didFinish` + `evaluateJavaScript("document.documentElement.scrollHeight")`.
  - Bind height back to SwiftUI `.frame(height: measuredHeight)`.
  - Add viewport meta tag for reliable sizing.
- **Best practice**: Cache measured heights, debounce updates, use `.id()` on bubbles when content changes.

**Strong advice**: Profile with Instruments (Allocations, Time Profiler) early. Prefer `List` over `LazyVStack` for heavy children.

---

## 4. Streaming (Token-by-Token) Updates

- **Full re-render** (`loadHTMLString` on every token): Causes flicker, scroll jumps, layout thrashing. Avoid for production streaming.
- **Incremental DOM injection** (`evaluateJavaScript`): Preferred. Append tokens or call a JS renderer function on a specific container div.
  - Load skeleton HTML once.
  - As tokens arrive: `webView.evaluateJavaScript("appendToken('\(escaped)')")`.
- Real AI chat apps use JS libraries (e.g., Marked.js with incremental support) inside the webview for partial Markdown rendering (code blocks, tables).
- Hybrid approach: Buffer tokens; full render on "complete" signal; incremental only for active streaming message.

---

## 5. SwiftUI ↔ WKWebView Bridging

- **Theme syncing**: Inject CSS via `customStylesheet` (markdown-webview) or `customCSS` (RichText). Use `colorScheme(.auto)` + semantic colors. Provide light/dark variants.
- **Link handling** (`file://` paths): Use `.onLinkActivation` or `WKNavigationDelegate.decidePolicyFor`. Intercept and route to native file handling.
- **Copy / select text**: Built into `markdown-webview`. RichText also supports selection.
- **Dynamic height**: JS measurement + binding + frame modifier (see §3).
- **Bidirectional comms**: `WKScriptMessageHandler` (JS → Swift) + `evaluateJavaScript` (Swift → JS).

---

## 6. Markdown → Styled HTML Conversion

- `markdown-webview` handles this internally (`markdown-it`).
- If agents send raw Markdown → use the package directly.
- If agents send HTML → use `RichText`.
- Alternative libraries (if needed): `cmark-gfm` (Swift wrapper) for server-side conversion before sending.

---

## 7. Security Considerations

- **Sandbox**: Enable "Outgoing Connections (Client)" for macOS App Sandbox (required for loading HTML strings).
- **CSP headers**: Add when possible (especially if any remote resources).
- **Arbitrary JS**: Limit via `WKContentWorld` (isolated vs default). Avoid executing untrusted scripts.
- **file:// links**: Never allow arbitrary navigation; intercept and whitelist.
- **Content isolation**: Prefer isolated content worlds for injected scripts.
- General rule: Treat response HTML/Markdown as semi-trusted (agent output) but still sanitize where practical.

---

## Recommended Next Steps (Reuse-First)

1. Add `tomdai/markdown-webview` as SPM dependency.
2. Create a thin `ResponseBubbleWebView` wrapper that:
   - Uses `MarkdownWebView`.
   - Handles BeeChat theming + `file://` links.
   - Exposes height binding if needed.
3. Integrate only into assistant message bubbles (modular boundary).
4. Add streaming support via incremental JS updates if agents stream Markdown.
5. Profile memory/scroll with realistic message volumes.
6. Consider single shared webview architecture only if per-bubble approach shows limits.

**This is largely transplant + thin wrapper work** — exactly as Adam suspected. No need to invent core rendering logic.

---

**Sources** (selected):
- https://github.com/tomdai/markdown-webview
- https://github.com/NuPlay/RichText
- Community reports on WKWebView + LazyVStack performance
- OpenAI engineering notes on ChatGPT macOS architecture
- Swift forums / Stack Overflow patterns for dynamic height + streaming