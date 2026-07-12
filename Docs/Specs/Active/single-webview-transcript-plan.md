# Single-WebView Transcript — Implementation Route (Option B)

**Author:** Fable
**Date:** 2026-07-12
**Status:** Route plan, approved direction (Adam, 2026-07-12) — build gates still apply
**Supersedes as direction:** per-bubble hybrid rendering (`html-rendering-architecture.md` §render paths). Sanitization, markdown conversion, theming tokens, and windowing are all retained.
**Relation to current work:** independent of the v0.9.5f self-heal clamp, which stabilizes the existing native transcript and remains the shipped path until Gate B-4 passes.

---

## 0. What we are building and why it ends the bug class

One `WKWebView` becomes the entire message transcript. Messages are DOM nodes inside a single document; the browser owns scrolling; SwiftUI keeps everything else (sidebar, composer, status bar, sheets, reset indicator).

The invariant this restores: **message height and scroll offset live in the same layout engine.** Every scroll bug since Round 1 — R1 empty-doc reports, R2 wrong-width reports, R4 handoff remounts, whitespace stranding, jump-stops-short — is a symptom of heights crossing a process boundary *after* native layout ran. In a single document, a ResizeObserver callback and a `scrollTop` write happen in the same layout pass. The failure class isn't fixed; it becomes **unrepresentable**:

| Long-standing pain | Why it can't exist in Option B |
|---|---|
| Async height → scroll jumps / whitespace | No height bridge exists. WebKit lays out and scrolls in one pass. |
| Topic-switch flash / stale offset (`.id(topicId)` world) | The WebView is never remounted. Topic switch = one synchronous DOM swap + `scrollTop = scrollHeight` inside a single JS task — no intermediate paint is possible. |
| R4 handoff chain (streaming → bridge → settled = 3 webviews, 2 cold remounts) | One document; settle = replace the streaming node with the settled node in one call. Zero remounts. |
| 17 live WebContent processes / 79 spawns per session | Exactly 1 WebContent process, app-lifetime. |
| Multi-line copy across messages | Native browser selection across the whole transcript. Free. |
| HTML fidelity (tables, code, anything) | Full WebKit, no converter subset, no bail-outs. |
| `defaultScrollAnchor` / LazyVStack estimation semantics | Not used at all. Pinning is ~15 lines of our own JS (spec §4.4). |

## 1. Design principles

1. **Modularity first (Adam's requirement).** The transcript becomes a swappable engine behind a single boundary (§2). The current native stack is Engine 1; the WebView transcript is Engine 2. A future Engine 3 (e.g. AppKit table view, or a different web stack) plugs into the same seam. Nothing outside the boundary knows which engine is rendering.
2. **Minimum new code; net-negative overall.** New: ~350 lines HTML/CSS/JS + ~300 lines Swift host + ~60 lines boundary. Deletable once the native engine retires: ~1,500 lines (accounting in §8). Reuse everything already proven (§1.1).
3. **Dumb document, smart Swift.** All *policy* (what to show, streaming visibility rules, link allow-list, time formatting, sanitization) stays in Swift where it's testable. The document only renders what it's told and reports user intent back. No business logic in JS.
4. **State is always reconstructible.** The Swift side holds the full `TranscriptState`; the document is a projection of it. WebContent process death recovery = reload template + replay state. Correct by construction — no tripwires needed.

### 1.1 Reuse inventory (zero changes required)

| Component | Role in Option B |
|---|---|
| `MarkdownToHTML` (124 loc) | Per-message markdown→HTML at inject time, unchanged |
| `HTMLSanitizer` (312 loc) | Sanitize per message *before* it enters the document, unchanged policy |
| `LinkPolicy` (115 loc) | `bcLink` handler target, unchanged |
| `ThemeManager.cssTokens` + `fontScale` | Already a flat `--bc-*` map with cache invalidation — feeds `setTheme`/`setFontScale` as today |
| `MessageListObserver` (70 loc) | 25-message window + `loadEarlierMessages()` — unchanged upstream; DOM renders whatever window it's handed |
| `MessageTemplate.html` patterns | Bridge helper, `setTheme`, `setFontScale`, `hydrate()` (table wrap + image load hooks), link/image click interception — lifted into the new template |
| `scripts/embed-template.swift` | Same embed pipeline for the new template constant |
| `MessageTemplateTests.swift` harness pattern | Headless-WKWebView test driving — extended to the transcript document (§9) |
| Composer, GatewayStatusBar, sidebar, reset indicator | Untouched — outside the boundary |

## 2. Phase B-1 — The transcript boundary (pure refactor, no behavior change)

**Goal:** the message window becomes a component you can swap with a flag. Ship this even if Option B stalls — it's the modularity insurance on its own.

New file `Sources/App/UI/Transcript/TranscriptBoundary.swift`:

```swift
/// Everything the message window needs to render. This mirrors the exact
/// parameter list of today's canvasWithMacOS15Chrome — the boundary already
/// exists de facto; this makes it a type.
struct TranscriptState: Equatable {
    var topicId: String?
    var messages: [Message]          // windowed slice from MessageListObserver
    var canLoadEarlier: Bool
    var isStreaming: Bool
    var streamingContent: String
    var completedContent: String
    var thinkingState: ThinkingState
}

struct TranscriptCallbacks {
    var onLoadEarlier: () -> Void
    var onOpenLink: (URL) -> Void    // → LinkPolicy.open
    var onTapImage: (URL) -> Void    // → future native viewer (parity with bcImage TODO)
}

enum TranscriptEngine: String { case native, web }

@ViewBuilder
func transcriptView(engine: TranscriptEngine,
                    state: TranscriptState,
                    callbacks: TranscriptCallbacks) -> some View {
    switch engine {
    case .native: NativeTranscriptView(state: state, callbacks: callbacks)
    case .web:    WebTranscriptView(state: state, callbacks: callbacks)
    }
}
```

Steps:
1. Add `transcriptEngine` to `FeatureFlags` (same `@Observable` + UserDefaults pattern as `htmlRenderingEnabled`; default `.native`).
2. Wrap the existing stack — `canvasWithMacOS15Chrome` + `MessageCanvas` + chrome — as `NativeTranscriptView` (a rename-and-wrap; zero logic changes).
3. `MainWindow.swift:234` calls `transcriptView(...)` instead of `canvasWithMacOS15Chrome(...)`.
4. Move the `showStreamingBubble` / `showCompletedBridge` policy computations (MessageCanvas.swift:37–60) into `TranscriptState` extension methods so **both engines** consume the same derived `streamingHTML: String?` / `settledBridgeHTML: String?` — policy written once.

**Exit criteria:** app byte-for-byte behaviorally identical; flag flips between `.native` and `.native` (web case stubbed to `EmptyView`); all existing tests pass.
**Estimate:** ~half a day.

## 3. Phase B-0 — Spike with pass/fail gates (runs in parallel with B-1)

Decision is made, but the gates protect against a silent disqualifier before real money is spent. Reuse the `Experiments/W4MemoryProbe` harness pattern: a bare window hosting one `WKWebView` + a prototype transcript document.

| Gate | Test | Pass |
|---|---|---|
| G1 memory | Load General's real 422 messages (pull via GRDB, bypass window), soak 30 min | Exactly 1 WebContent process; app+WebContent RSS < 400 MB; plateau (no monotonic growth) |
| G2 scroll | Pinned-at-bottom while: 5fps streaming appends, 10 image loads with late arrival, continuous live window resize for 10s | Never unpins, never strands, no visible jump |
| G3 selection | Drag-select across 5 messages incl. a table and a code block; Cmd+C; paste into TextEdit | Coherent multi-message plain text |
| G4 theme | Port 1 of the 8 themes + fontScale slider live | Visual parity with native bubble chrome, restyle < 1 frame |
| G5 topic swap | Swap between two 25-message topics 20× | No white flash, lands at bottom every time, < 100ms perceived |
| G6 input | Type in native composer while transcript streams | No focus theft, no dropped keystrokes |

**Any gate fails → stop, write up, fall back to Exit 1 (native `Grid` tables).** Estimate: 2–3 days.
Gotcha carried from Round 3: GUI probes launched from background shells need manual `NSWindow` + `orderFrontRegardless` (macOS 14+ cooperative activation).

## 4. Phase B-2 — The transcript document

New files: `Sources/App/Resources/TranscriptTemplate.html` + generated `TranscriptTemplate.swift` (same embed chain as `MessageTemplate.swift`, including the resource-bundle→embedded fallback).

### 4.1 DOM structure

```html
<body>
  <div id="scroller">          <!-- the ONE scroll surface; overflow-y:auto -->
    <div id="transcript">
      <button id="load-earlier" hidden>Load earlier messages</button>
      <!-- message nodes, oldest→newest -->
      <article class="msg" data-id="…" data-role="assistant">
        <div class="sender">Bee</div>
        <div class="badge" hidden>🛠 Q</div>
        <div class="bubble"><div class="content"><!-- sanitized HTML --></div></div>
        <time>14:32</time>
      </article>
      <article id="streaming" class="msg assistant" hidden>…</article>
      <div id="thinking" hidden><!-- indicator --></div>
    </div>
  </div>
  <button id="jump" hidden>⌄</button>   <!-- position:fixed overlay -->
</body>
```

`role="log"` + `aria-live="polite"` on `#transcript` for VoiceOver announcement of arrivals.

### 4.2 CSS — port map from `MessageBubble`/`ThemeManager`

All values arrive as CSS custom properties via the existing `cssTokens` channel — **no hardcoded colors**. New tokens needed beyond the current `--bc-*` set (add to `ThemeManager.cssTokens`): `--bc-bg-surface`, `--bc-bg-panel`, `--bc-accent-primary`, `--bc-text-on-accent`, `--bc-text-secondary`, `--bc-border-subtle`, `--bc-bg-elevated`, `--bc-shadow`, `--bc-radius-xl`, spacing tokens.

| Native (MessageBubble.swift) | CSS |
|---|---|
| 66% max width (`BubbleWidthModifier`) | `.bubble { max-width: 66%; }` — the document width IS the canvas width; the entire `measuredWidth`/PreferenceKey/1200-default machinery has no equivalent and no replacement |
| user right / assistant left | `.msg[data-role=user] { align-items:flex-end }` flex column |
| system centered italic caption | `.msg[data-role=system]` rule |
| sender name, agent badge capsule, timestamp caption | `.sender`, `.badge`, `time` rules (badge text computed in Swift — policy stays native, §1.3) |
| rounded rect + shadow | `border-radius: var(--bc-radius-xl); box-shadow: …` |
| content CSS (headings, code, tables, quotes, images) | **lift verbatim** from `MessageTemplate.html` — already themed and field-tested |

Streaming cursor: CSS blink animation on `#streaming .content::after`. ThinkingBee: start with a CSS three-dot pulse (`#thinking`); port `BeeWingsAnimation` (64 loc SwiftUI) as CSS keyframes in a later polish pass — logged as the one accepted temporary fidelity regression.

### 4.3 JS API (Swift → document), all under `window.beechat`

Message payloads are pre-rendered in Swift: `{id, role, senderName?, badge?, timeLabel, html}` — `html` already sanitized, `timeLabel` already locale-formatted.

| Call | Semantics |
|---|---|
| `setTopic({topicId, messages, canLoadEarlier})` | Atomic swap: build all nodes off-DOM, replace `#transcript` children, set `scrollTop = scrollHeight`, reset `pinned = true` — all in one JS task, so no intermediate frame can paint (this is the whole topic-switch fix) |
| `upsertMessages(messages, canLoadEarlier)` | Diff by `data-id`; append new (repin if pinned), replace changed innerHTML in place (edits, settle) |
| `prependEarlier(messages, canLoadEarlier)` | Record `scrollHeight` before, insert, then `scrollTop += (newScrollHeight − old)` — deterministic anchor, no reliance on `overflow-anchor` |
| `setStreaming(html \| null)` | Update/hide `#streaming` node contents; repin if pinned. Settle is `setStreaming(null)` + `upsertMessages([settled])` in the same evaluateJavaScript call — the R4 chain collapses to one atomic mutation |
| `setThinking(state)` | Show/hide `#thinking` (`thinking` / `streaming` / `idle` mapping mirrors MessageCanvas.swift:108–120 policy, computed Swift-side) |
| `setTheme(tokens)` / `setFontScale(n)` | Verbatim from current template |
| `scrollToBottom()` | Explicit jump (used by recovery/tests; the in-DOM `#jump` button calls it directly) |

### 4.4 The scroll engine — the ~15 lines that replace two months of fighting

```js
let pinned = true;                       // field-tested hysteresis: enter 50 / leave 120
scroller.addEventListener('scroll', () => {
  const d = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
  if (d < 50) pinned = true; else if (d > 120) pinned = false;
  jump.hidden = pinned;
}, { passive: true });
const repin = () => { if (pinned) scroller.scrollTop = scroller.scrollHeight; };
new ResizeObserver(repin).observe(transcript);   // any content growth: images, streaming, fonts
window.addEventListener('resize', repin);        // live window resize
```

Height changes and the pin run in the same layout engine — late-loading images, code-block reflow, font-scale changes all self-correct. `hydrate()`'s image `load`/`error` hooks (lifted from current template) call `repin` too, covering the paint-after-layout edge.

### 4.5 Events (document → Swift)

| Handler | Payload | Swift action |
|---|---|---|
| `bcReady` | — | Replay full `TranscriptState` (initial load *and* process-death recovery — same code path) |
| `bcLink` | href string | `LinkPolicy.isAllowed` → `callbacks.onOpenLink` (verbatim from today) |
| `bcImage` | src | `callbacks.onTapImage` (native viewer remains a TODO, unchanged) |
| `bcLoadEarlier` | — | `callbacks.onLoadEarlier` → `MessageListObserver.loadEarlierMessages()` |
| `bcPinned` | bool | Telemetry only (census successor); no native UI depends on it — jump button is in-DOM |

Gone forever: `bcHeight`. There is no height protocol.

### 4.6 Security posture (unchanged policy, one document)

- Sanitize every message with `HTMLSanitizer` before it enters a payload — same trust boundary as today.
- CSP meta in the template: `default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'` (own inline template script only; parity with current image loading).
- Navigation delegate: allow `.other` (template load) only — verbatim from `MessageWebView.Coordinator`.
- `loadHTMLString(_, baseURL: nil)`, local-only, no cookies/storage.

**Exit criteria B-2:** template renders a fixture transcript (the 18-case converter matrix reused as HTML fixtures + General's real window) correctly in headless tests; scroll engine invariants pass (§9 T1–T4).
**Estimate:** 2–3 days.

## 5. Phase B-3 — The Swift host

New file `Sources/App/UI/Transcript/WebTranscriptView.swift` (~300 loc, one `NSViewRepresentable` + controller):

- **One `WKWebView`, app-lifetime.** Created in `makeNSView`, never torn down by topic switches (the boundary view is stable in `MainWindow`; only `TranscriptState` changes). Reuse from `MessageWebView`: `WeakScriptMessageHandler`, `drawsBackground=false` + `underPageBackgroundColor`, transparent config, `dismantleNSView` handler cleanup.
- **State diffing in `updateNSView`:** controller keeps `appliedState: TranscriptState?` and emits the minimal JS call: topicId changed → `setTopic`; messages array changed → diff by id/content → `upsertMessages` (or `prependEarlier` when the head extends — detectable because windowing only ever grows backward); streaming/thinking fields changed → their setters; tokens/fontScale → theme setters. All writes via one `evaluateJavaScript` per update cycle (batch into a single `beechat.apply({...})` call if profiling shows chatter).
- **Content preparation off the render path:** markdown→sanitize per message memoized in an `NSCache<NSString, NSString>` keyed by **content hash** (adopting the Round 6b keying decision where it actually belongs — render output, not heights).
- **Process death:** `webViewWebContentProcessDidTerminate` → reload template; `bcReady` → replay `appliedState`. Delete the tripwire/fault plumbing — replay is unconditionally correct.
- **Scroll wheel forwarding hack:** *deleted*, not ported. The transcript is the scroller; `BubbleWebView.scrollWheel` inversion was only needed because bubbles sat inside a native scroll view.
- **Context menu:** unlike per-bubble (menu stripped), filter instead: keep Copy / Copy Link / Look Up / Share; remove Reload / Go Back / Inspect Element (filter `WKMenuItemIdentifier*` in `willOpenMenu`). This is what makes copy a first-class citizen.
- Housekeeping while in here: set the app's **bundle identifier** in the hand-assembled Info.plist (Bee's Round 6b finding) so `log show --predicate 'subsystem == "com.beebox.beechat"'` finally works.

**Exit criteria:** flag `.web` renders General end-to-end with streaming against the live gateway; kill `WebContent` via `kill -9` mid-session → transcript self-restores at bottom within 1s.
**Estimate:** 2 days.

## 6. Phase B-4 — Parity matrix and hardening

Must-pass (blockers for default-on):

| # | Scenario | Expectation |
|---|---|---|
| P1 | Topic switch ×20 incl. General | Lands at bottom, no flash, no whitespace — the original sin, gone |
| P2 | Streaming from ThinkingBee → stream → settle | One continuous bubble; no remount flash (R4 dead) |
| P3 | Load earlier ×3 | Viewport anchored on previously-visible message |
| P4 | All 8 themes + fontScale range | Full restyle, no reload |
| P5 | Live resize 10s | Pinned stays pinned; mid-scroll position tolerably stable |
| P6 | Cross-message selection + Cmd+C incl. table + code | Clean multi-line copy (Adam's requirement) |
| P7 | Links (allowed + blocked schemes), image tap | LinkPolicy parity |
| P8 | Archived read-only view, reset indicator overlay | Unchanged (outside boundary) |
| P9 | WebContent kill during streaming | Self-heal ≤1s, no blank bubble |
| P10 | VoiceOver walk + arrival announcement | Coherent order, `aria-live` fires |
| P11 | macOS 14 run | Identical path (no `#available` forks exist in the web engine — one code path for all OS versions, another entire dimension of the old matrix deleted) |
| P12 | Memory census after 1h mixed use | 1 WebContent process; RSS plateau; repurposed `WebViewCensus` asserts count==1 |

Should-have (post-default-on): Cmd+F via `WKWebView.find(_:)`, native image viewer for `bcImage`, ThinkingBee CSS wings port.
**Estimate:** 2–3 days incl. fixes.

## 7. Phase B-5 — Rollout and retirement

1. Ship one release with `transcriptEngine` default **`.native`**, `.web` available via settings/defaults toggle — Adam and Bee's agents dogfood `.web`.
2. Next release: default **`.web`**, native retained as the escape hatch (flip-back is one UserDefault, no reinstall).
3. After **two stable releases** on `.web`: delete the native engine (§8). Keeping two engines forever is a maintenance tax, and the boundary (§2) means a future engine can be rebuilt against a typed seam if ever needed — that's the modularity guarantee, not the dead code.

## 8. Deletion ledger (what "minimising unnecessary code" cashes out to)

At retirement, delete:

| File / area | LOC |
|---|---|
| `MessageWebView.swift` (per-bubble machine: height bridge, tripwire, coordinator) | 267 |
| `WebViewHeightCache.swift` | 36 |
| `HTMLMessageConverter.swift` + SwiftSoup dependency | 326 |
| `ConvertedMessageView.swift` | 206 |
| `MessageCanvas.swift` (chrome, hysteresis, `.id(topicId)`, clamp, compat shims, CompletedBridgeBubble) | ~470 |
| `MessageContent.swift` webview/converter branches; `StreamingBubble` webview path | ~120 |
| `MessageBubble.swift` + width plumbing (recreated as ~60 lines of CSS) | 155 |
| Converter/rendering test files tied to the above | ~300 |
| **Total removed** | **~1,900** |
| **Total added** (template ~350 + host ~300 + boundary ~60) | **~710** |

Net: **−1,200 lines**, one rendering pipeline instead of three (native / per-bubble webview / bridge bubbles), one OS code path instead of macOS 14/15 forks, zero undocumented SwiftUI scroll semantics in the dependency set.

## 9. Test and verification plan

- **T1–T4 headless document tests** (extend the `MessageTemplateTests` harness): T1 `setTopic` lands `scrollTop == scrollHeight − clientHeight` before first paint callback; T2 pin hysteresis across scripted scrolls (50/120); T3 `prependEarlier` preserves anchor offset exactly; T4 streaming settle produces zero node-count flicker (MutationObserver assert).
- **Fixture corpus:** the 18 converter matrix cases + General's real 25-message window exported as JSON — render, screenshot-diff across all 8 themes.
- **Soak:** scripted 30-min stream/switch/resize loop; assert census==1 and RSS plateau (reuse W4 probe thresholds discipline).
- **Manual matrix:** §6 P1–P12, signed off per the team's review-cycle convention.
- **Instrumentation that stays:** `bcPinned` transitions and census at `.info` (persisted — and with the bundle-id fix, `log show` finally works for post-hoc audits).

## 10. Risks and mitigations

| Risk | Judgment | Mitigation |
|---|---|---|
| Theme port fidelity across 8 themes | Real work, not risky | Tokens already flat `--bc-*`; screenshot-diff per theme in T-fixtures |
| Focus/keyboard interplay (composer native, transcript web) | Medium | Gate G6 day one; composer never loses first-responder except on explicit transcript click |
| Streaming `innerHTML` replace at 5fps on long messages | Low (single small node, WebKit's bread and butter) | If profiling objects: append-only fast path for the common suffix-growth case |
| VoiceOver regression vs native bubbles | Medium, honest cost | `role=log`/`aria-live` + P10; accept "good web-area a11y" as the trade for everything else |
| Very long windows (user hammers load-earlier) | Low | Window already capped upstream; DOM handles hundreds of nodes; G1 tests 422 |
| WKWebView API drift | Low | Smaller API surface than today (no height bridge, no KVO hacks beyond `drawsBackground`) |
| Hidden dependency of some feature on native bubbles (e.g. future per-message actions) | Design-time | Per-message actions become DOM buttons → bridge events — same pattern as `bcLoadEarlier`; note in boundary doc |

## 11. Sequence and effort summary

```
B-1 boundary refactor            0.5 day   ─┐ can run same week as
B-0 spike gates G1–G6            2–3 days  ─┘ the v0.9.5f clamp work
B-2 transcript document          2–3 days
B-3 Swift host + bridge          2 days
B-4 parity + hardening           2–3 days
B-5 rollout                      2 release cycles (calendar, not effort)
                                 ≈ 2 working weeks to flag-on
```

Team fit: B-1+B-0 are independent briefs (Kieran/Bee); B-2 and B-3 have a clean interface contract (§4.3/§4.5) so they can proceed in parallel after G-gates pass; Q reviews the bridge protocol; Mel owns the sanitizer/CSP review (her open sanitizer-location question from Round 3 resolves naturally here: sanitize-at-inject, one call site).

## 12. Decisions taken in this plan (flag if you disagree)

1. Jump-to-latest lives **in the DOM**, not as a native overlay (one source of truth for pin state; native overlay would need `bcPinned` round-trips).
2. ThinkingBee ships first as CSS dots; the winged bee is a polish-pass port.
3. The native engine **retires** after two stable `.web` releases; the boundary is the permanence, not the dead code.
4. Per-message HTML render cache keyed by **content hash** (Round 6b's keying, applied to render output where it belongs; heights no longer exist to cache).
5. `MessageListObserver`'s 25-window stays exactly as is — windowing is an upstream concern in both engines.

---

*Route plan only — no code changed. First actionable briefs: B-1 (boundary) and B-0 (spike gates). — Fable*
