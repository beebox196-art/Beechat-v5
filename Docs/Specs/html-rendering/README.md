# HTML Message Rendering — Spec Pack (macOS)

Validation + scaffolding for rendering HTML message content in **BeeChat-v5** (macOS 14+,
SwiftUI/SPM), 2026-07-02. Grounded in the current codebase: `ScrollView + LazyVStack`
transcript (`MessageCanvas`), `MessageContent` → `FileLinkText` bubbles, eight-theme
`ThemeManager` with custom `fontScale`.

| File | What it is |
|---|---|
| `01-risk-analysis.md` | What breaks with WKWebView-per-bubble on macOS: LazyVStack retention (unbounded web views), live window-resize reflow storms, wheel-event interception, 8-theme token plumbing, VoiceOver/fontScale, security, known sharp edges. |
| `MessageTemplate.html` | Complete bubble template: theme-token injection (`beechat.setTheme`), `fontScale` support, height reporting via ResizeObserver → `bcHeight`, link/image/file-link bridging, hover affordances, wide-table handling, context-menu suppression. |
| `MessageWebView.swift` | `NSViewRepresentable` scaffold: `BubbleWebView` subclass (vertical wheel forwarding, WebKit menu stripping), `drawsBackground` transparency, per-theme `NSAppearance`, weak message-handler proxy (leak fix), process-death recovery, navigation lockdown. |
| `03-test-matrix.md` | 26 HTML edge cases + 9 desktop scenarios (live resize, 8-theme switch, fontScale change, Activity Monitor process checks, wheel forwarding, Cmd+F/selection). |
| `04-architecture-alternatives.md` | Per-bubble web view vs single web view vs native AttributedString — ranked; recommendation is native-first hybrid building on the existing `FileLinkText` pipeline. |

**TL;DR:** per-bubble WKWebView as the default renderer is the one configuration v5
should not ship — it stacks WebKit's async-height and paint problems on top of
LazyVStack's never-release behavior and desktop live-resize. Recommended: SwiftSoup →
`AttributedString` conversion at ingest for the common HTML subset (extending the
existing `FileLinkText` path, *not* `NSAttributedString(html:)`), with the web view
template here reserved for rare table-heavy messages.
