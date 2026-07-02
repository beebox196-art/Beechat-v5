# HTML Message Rendering — Risk Analysis: WKWebView per bubble (macOS)

**Scope:** each message bubble in BeeChat-v5 hosts a `WKWebView` via `NSViewRepresentable`.
Grounded in the actual codebase: the transcript is `ScrollView + LazyVStack`
(`Sources/App/UI/Components/MessageCanvas.swift`), bubbles are `MessageBubble` →
`MessageContent` → `FileLinkText` (AttributedString), theming is **eight custom themes**
with hex token palettes via `ThemeManager` (not system light/dark), and text size is a
custom `fontScale` in UserDefaults (macOS has no Dynamic Type).

---

## 1. Memory

| Risk | Detail |
|---|---|
| `LazyVStack` never releases — **direct hit on v5** | The transcript already uses `ScrollView { LazyVStack }`. Lazy stacks create views on demand and **never destroy them while in the hierarchy** ("lazy" = deferred creation, not recycling). Scroll a 500-message topic and up to 500 live `WKWebView`s accumulate for the lifetime of the window. On iOS jetsam would kill you; on macOS nothing stops it — the app just bloats to multi-GB and the WindowServer carries a layer tree per web view. |
| Per-instance cost | Each `WKWebView` carries a compositing layer tree plus a share of an out-of-process WebContent process: realistically **5–20 MB in-process + 10–40 MB per document** out-of-process (images dominate). Desktop RAM hides this longer than iOS, but Activity Monitor shows dozens of "BeeChatApp Web Content" entries and users notice. |
| Multiple windows/topics multiply it | v5 is a desktop app: several topic windows or a long session with topic switching multiplies web view counts. There is no cell reuse anywhere in this architecture to cap it. |
| WebContent process termination | Rarer than iOS jetsam but real (crashes, memory pressure): bubbles silently go **blank** until reload. Every web view must implement `webViewWebContentProcessDidTerminate(_:)` — v5's own `CRASH-sample-2026-05-13.txt` history says assume processes die. |
| WebContent process count is uncontrollable | `WKProcessPool` has been a deprecated no-op since macOS 12 — WebKit alone decides how documents map to WebContent processes. You cannot cap or consolidate them from the app; whatever process count WebKit chooses for N live bubbles, you live with. |

## 2. Performance

| Risk | Detail |
|---|---|
| **Live window resize — the macOS-specific killer** | Users resize windows constantly; bubble width tracks window width. Every width change reflows **every live web view**, each re-reports height asynchronously, each report is a `@State` write → LazyVStack relayout. During a continuous drag-resize that's a storm of cross-process layout + main-thread invalidation; native `Text` reflows synchronously in the same frame. Expect visible bubble "shimmer" and stale heights mid-drag. Split-screen and full-screen transitions hit the same path. |
| Async height round-trip → scroll jumps | Intrinsic height arrives via JS → message handler → binding, so rows lay out at placeholder height then jump. `MessageCanvas` already fights ScrollViewReader anchoring (see the "4px anchor" workaround at the bottom spacer) — late height changes above the viewport will defeat that anchoring while paging through history. There is no SwiftUI row-invalidation API to fix it. |
| Out-of-process first paint | Content pops in a few frames after the bubble appears; with the dark themes you get a background-colored flash only if transparency is configured exactly right (see §5), otherwise a **white flash** per bubble. |
| Creation cost | First `WKWebView` spawns the WebContent process (100–500 ms); each subsequent creation is ~10–50 ms of main-thread work — during fast trackpad scrolling through history, that's dropped frames on every newly-instantiated bubble (and with LazyVStack, every bubble is newly instantiated exactly once — at the worst possible moment). |
| Scroll-wheel interception | macOS `WKWebView` exposes **no `scrollView` property** (that's iOS-only) — you cannot simply disable its internal scrolling. The web view swallows trackpad/wheel events over bubbles, stalling the transcript scroll. Fix requires a `WKWebView` subclass that forwards `scrollWheel(with:)` to the next responder, which then conflicts with legitimate *horizontal* scrolling inside wide code blocks/tables (see scaffold for the deltaX/deltaY split compromise). |

## 3. Desktop interaction model

- **Right-click:** WKWebView ships its own context menu ("Reload", "Inspect Element" with dev extras). Must be stripped via `willOpenMenu(_:with:)` in the subclass or JS `contextmenu` handling, then bubble-level menus reimplemented.
- **Text selection:** v5 currently has `.textSelection(.enabled)` on message text. Web views give selection *within* one bubble but never across bubbles, and Cmd+A selects one document. Find (Cmd+F) can't search the transcript through per-bubble documents.
- **Keyboard/focus:** each web view is a key-view-loop participant; Tab and Full Keyboard Access users get trapped cycling through dozens of invisible web documents.
- **Hover:** links need `:hover`/`cursor: pointer` in CSS or the transcript feels dead compared to native links (`FileLinkText` currently gets this free).

## 4. Accessibility

- **VoiceOver fragmentation:** each bubble becomes an independent web-content accessibility subtree; the transcript stops being one coherent reading order, and VO users must "enter" each web area. Merged utterances ("Adam, 09:14, message…") become impractical.
- **No Dynamic Type on macOS — v5 has its own `fontScale`:** web content will ignore the app's font-size setting entirely unless the scale is explicitly injected into every live document (`beechat.setFontScale`) and re-injected on change. `FontScaleTests` exists precisely because this matters to the app; web views silently opt out of it.
- **Increase Contrast / Reduce Motion:** don't propagate into web content automatically; need explicit CSS media queries plus appearance plumbing.

## 5. Theme switching — hardest problem for BeeChat-v5 specifically

- The app has **eight bespoke themes as hex token sets**, not system light/dark. `prefers-color-scheme` can only distinguish two states, so it is *not* the theming mechanism here — every live web view must receive the full token set (`beechat.setTheme({...})`) whenever `ThemeManager` changes, and every *newly created* web view must get tokens before first paint or it flashes wrong-theme content.
- Transparency on macOS is awkward: there's no `isOpaque`/`backgroundColor` on `WKWebView`. You need `setValue(false, forKey: "drawsBackground")` — functioning KVC into non-public API that Apple has tolerated for a decade (flag for review if you ever sandbox/notarize more strictly) — plus `underPageBackgroundColor = .clear` (macOS 12+). Miss either and dark themes get white flashes on every bubble instantiation.
- `NSAppearance`: set `webView.appearance = NSAppearance(named: .darkAqua)` for dark-leaning themes so native-rendered form controls, scrollbars (in code blocks), and selection colors match; drive it from each theme's brightness, not the system setting.

## 6. Security

- Message HTML is remote, user-authored input in a JS-capable context. **Sanitize natively at ingest** (tag/attribute allowlist; strip `on*` handlers, `javascript:` URLs, `<script>`, `<iframe>`, `<object>`, `<style>`, forms). `innerHTML` injection doesn't execute `<script>`, but **`<img onerror=…>` executes** — sanitization is mandatory.
- macOS-specific: a compromised bubble is inside a desktop app with broader file access than iOS. Load the template with `baseURL: nil`, deny all navigation in the delegate, and validate schemes on bridged links. v5's file-link feature (`FileLinkText` path detection) means the link bridge will also carry file paths — route those through the app's existing file-open logic, never `NSWorkspace.open` on raw `file://` URLs from message content.
- Remote images leak IP/read-receipts; consider `WKContentRuleList` blocking with click-to-load.

## 7. Specific known bugs / sharp edges

1. **State write during view update:** posting JS height synchronously into a binding can land inside a SwiftUI update pass → `AttributeGraph: cycle detected` / "Modifying state during view update". Always hop through `Task { @MainActor … }`.
2. **`WKUserContentController` retain cycle:** `add(_:name:)` retains handlers strongly; coordinator + web view leak per message without a weak proxy or `dismantleNSView` cleanup. With LazyVStack retention *and* this leak, nothing is ever freed.
3. **`LazyVStack` retention** (documented behavior) — see §1; v5's transcript container.
4. **`ScrollViewReader.scrollTo` anchor drift:** late height changes above the viewport shift content; `MessageCanvas` already carries a spacer-anchor workaround that async web heights will destabilize.
5. **`NSAttributedString(html:)` is WebKit-backed and main-thread-only on macOS too** (documented) — relevant as the tempting "easy" alternative; it's slow (~50–200 ms/message) and unsuitable for a transcript. See architecture doc for what to use instead.
6. **`drawsBackground` KVC** is the only complete transparency route on macOS; `underPageBackgroundColor` alone doesn't cover pre-CSS paint.
7. **Occlusion/App Nap:** timers and rendering in occluded windows throttle; height reports from a hidden window can arrive late and land in a stale layout when the window reappears.

## Bottom line

On macOS the per-bubble approach inherits every iOS-class problem (async heights, paint
pop-in, VoiceOver fragmentation, sanitization burden) and adds three of its own: LazyVStack
means **unbounded accumulation** of live web views (v5's actual transcript container),
**live window resize** turns every drag into a cross-process reflow storm, and the
**eight-theme system** demands token injection into every document. Viable only as a
bounded fallback for rare complex-HTML messages — see `04-architecture-alternatives.md`.
