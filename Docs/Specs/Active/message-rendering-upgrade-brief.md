# Message Rendering Upgrade — Feature Brief

**Status:** SUPERSEDED — Direction changed to HTML-first. See `html-rendering-architecture.md` for the full spec.  
**Date:** 2026-06-30  
**Author:** Bee (research), Adam (direction)  
**Target:** BeeChat v5, post v0.9.4 stability window  
**Note:** This brief originally proposed Markdown-first (Textual/MarkdownUI) with HTML as v2. Adam reversed this: go straight to HTML via WKWebView. The detailed architecture is now in `html-rendering-architecture.md`.  

---

## 1. Problem

BeeChat currently renders **plain text only**. Every message — markdown, code blocks, tables, lists, links — comes through as raw strings with no formatting beyond our `FileLinkText` path detector. This is the single biggest UX gap vs. every other AI chat interface (ChatGPT, Claude, Telegram, Slack).

Agent output is overwhelmingly **markdown-formatted**: headers, bold/italic, code fences, bullet lists, tables, blockquotes. Right now Adam sees the raw syntax instead of rendered content.

## 2. Goal

Render markdown-formatted messages in the BeeChat message canvas so that headers, bold, italic, lists, code blocks, tables, and links display properly — matching the quality Adam expects from a modern chat app.

**Non-goal (for v1):** Full HTML rendering via WKWebView. That's a future consideration, documented here for context only.

## 3. Current Architecture (What We're Changing)

```
Message → MessageContent → FileLinkText → SwiftUI Text (plain)
```

- `MessageContent.swift`: checks `message.content`, falls back to empty `Text(" ")`
- `FileLinkText.swift`: regex-based path detection, renders plain `Text` for non-link content, `AttributedString` with `.link` for detected paths
- No markdown parsing, no code highlighting, no tables, no styled headers

**Target architecture:**

```
Message → MessageContent → RichMessageContent → Textual/MarkdownUI → styled output
                                                                  ↓
                                                          FileLinkText (merged)
```

## 4. Library Options

### 4A. Textual (gonzalezreal/textual) — ★ RECOMMENDED

| Aspect | Detail |
|---|---|
| **What** | SwiftUI-native rich text engine. Successor to MarkdownUI by same author. |
| **Latest** | v0.5.0 (June 15, 2026) — active development |
| **Stars** | 761 |
| **Rendering** | `InlineText` (inline formatted) + `StructuredText` (block-based: headings, lists, code blocks, tables, blockquotes) |
| **Markdown** | Built on Foundation's `AttributedString` parser |
| **Custom markup** | `MarkupParser` protocol for pluggable formats |
| **Attachments** | Images, math (LaTeX), GIF/APNG/WebP |
| **Syntax highlighting** | Built-in, customisable themes |
| **Styling** | `.textual.structuredTextStyle(.gitHub)` preset + per-block overrides |
| **Selection** | Native text selection with copy-paste |
| **Streaming** | Not explicitly documented for token-by-token; would need testing with our `StreamingBubble` |
| **Performance** | SwiftUI `Text` pipeline — no WKWebView overhead |
| **License** | MIT |
| **SPM** | `.package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0")` |

**Why Textual over MarkdownUI:** MarkdownUI is in maintenance mode (last release 2.4.1, late 2024). Textual is the active successor from the same author, with better architecture (separate inline vs. structured rendering, attachments, math support). However, Textual is v0.x — expect API churn.

### 4B. MarkdownUI (gonzalezreal/swift-markdown-ui) — Stable fallback

| Aspect | Detail |
|---|---|
| **What** | GFM markdown renderer for SwiftUI |
| **Latest** | v2.4.1 (stable, maintenance mode) |
| **Stars** | ~2,400 |
| **Rendering** | `Markdown { ... }` with theme system |
| **Streaming** | Proven in Stream Chat AI (character-by-character updates) |
| **Code highlighting** | Via Splash (Swift-only) or custom |
| **Performance** | Good for static; known stutter on streaming updates at scale |
| **License** | MIT |
| **Risk** | No new features; community moving to Textual |

**When to pick this:** If Textual's v0.x instability is too risky, MarkdownUI is the proven, stable option. Stream Chat Swift AI uses it in production for streaming LLM responses.

### 4C. HighlightSwift (appstefan/HighlightSwift) — Syntax highlighting add-on

| Aspect | Detail |
|---|---|
| **What** | SwiftUI code syntax highlighting (50+ languages, 30+ themes) |
| **Use case** | Add-on for code block rendering inside Textual/MarkdownUI |
| **Note** | Textual has built-in syntax highlighting; this would only be needed if we want highlight.js-level language coverage beyond what Textual provides |

### 4D. markdown-webview (tomdai/markdown-webview) — HTML fallback path

| Aspect | Detail |
|---|---|
| **What** | WKWebView wrapper with auto-height, syntax highlighting, text selection |
| **Use case** | Future v2 if we want HTML rendering for tables, embedded charts, etc. |
| **Trade-off** | Better HTML support but non-native feel, scroll issues, memory overhead per instance |

**Decision:** v1 = native SwiftUI (Textual or MarkdownUI). v2 = evaluate WKWebView hybrid only if markdown proves insufficient for agent output.

## 5. Proposed Implementation

### Phase 1: Markdown Rendering (v1 target)

**Scope:**
1. Replace `MessageContent` → `FileLinkText` → plain `Text` pipeline with `MessageContent` → `RichMessageContent` using Textual (preferred) or MarkdownUI (fallback)
2. Merge `FileLinkText` path detection into the new pipeline (parse markdown first, then run path regex on remaining text nodes)
3. Add BeeChat theme integration — map our `ThemeManager` tokens to Textual's styling system
4. Streaming support — ensure `StreamingBubble` updates render incrementally (test with real agent output)

**Files changed (estimated):**
- `Sources/App/UI/Components/MessageContent.swift` — rewritten
- `Sources/App/UI/Components/FileLinkText.swift` — merged into new pipeline
- `Sources/App/UI/Components/MessageBubble.swift` — width/layout adjustments for structured content
- `Sources/App/UI/Components/StreamingBubble.swift` — streaming markdown rendering
- `Package.swift` — add Textual or MarkdownUI dependency
- New: `Sources/App/UI/Components/RichMessageContent.swift` — main rendering view
- New: `Sources/App/UI/Theme/BeeChatMarkdownTheme.swift` — theme mapping

**Estimated effort:** 2-3 days for Q (spec → build → test), 1 day Kieran review.

### Phase 2: Code Highlighting & Polish (v1.1)

- Ensure code blocks render with syntax highlighting and copy button
- Verify table rendering (GFM tables from agent output)
- Blockquote styling
- Link handling (merge with existing `OpenURLAction` for file paths)

### Phase 3: HTML Fallback (Future, NOT v1)

- Detect HTML-tagged messages (contains `<table>`, `<html>`, etc.)
- Route to WKWebView only for those messages
- Native SwiftUI for everything else
- Requires architecture decision: per-message web view vs. single web view for message list

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Textual v0.x API breaking change | Medium | Medium | Pin version; MarkdownUI as fallback |
| Streaming performance (re-renders per token) | Medium | High | Profile early; debounce if needed |
| FileLinkText merge complexity | Low | Medium | Test path detection after markdown parsing, not before |
| Theme mismatch (BeeChat tokens → Textual styles) | Low | Low | Theme mapping is straightforward |
| Layout regressions (bubble width, scroll) | Medium | Medium | Keep 66% bubble constraint; test with long code blocks |
| Code block height in LazyVStack | Medium | Medium | Use fixed-height placeholders or dynamic height caching |

## 7. Open Questions (For Thursday)

1. **Textual vs. MarkdownUI?** Textual is newer, more capable, v0.x. MarkdownUI is stable, proven for streaming, maintenance mode. Recommendation: Textual with pinned version; fallback to MarkdownUI if API churn is problematic.
2. **Streaming strategy?** Textual doesn't document token-by-token rendering. Need to test: (a) can we feed partial markdown to `StructuredText` during streaming, or (b) do we need MarkdownUI's proven streaming approach for `StreamingBubble` only?
3. **Code highlighting depth?** Textual has built-in syntax highlighting. Is that sufficient, or do we need HighlightSwift for broader language coverage?
4. **HTML detection threshold?** At what point do we route to WKWebView? Just `<table>`? Or any HTML? (v2 question — but worth agreeing the trigger now.)
5. **Theme alignment?** Do we want a GitHub-like rendering style (Textual's `.gitHub` preset) or a custom BeeChat style matching our existing design system?

## 8. Success Criteria

- [ ] Messages containing markdown headers, bold, italic, lists, code blocks, and links render correctly
- [ ] Streaming messages render incrementally without visible lag or stutter
- [ ] File path detection still works (clickable links to local files)
- [ ] Code blocks have syntax highlighting and are visually distinct
- [ ] Existing 66% bubble width and theme system are preserved
- [ ] No regression in plain-text message rendering
- [ ] 155 existing tests pass + new rendering tests added
- [ ] Adam can read agent output without seeing raw markdown syntax

## 9. Reference

- Textual repo: https://github.com/gonzalezreal/textual (v0.5.0, MIT)
- MarkdownUI repo: https://github.com/gonzalezreal/swift-markdown-ui (v2.4.1, MIT, maintenance mode)
- HighlightSwift: https://github.com/appstefan/HighlightSwift
- markdown-webview: https://github.com/tomdai/markdown-webview
- Stream Chat Swift AI: https://github.com/GetStream/stream-chat-swift-ai (production reference for streaming markdown)
- BeeChat current rendering: `Sources/App/UI/Components/MessageContent.swift`, `FileLinkText.swift`, `MessageBubble.swift`