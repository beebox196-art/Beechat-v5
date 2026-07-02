# HTML Message Rendering — Test Matrix (macOS)

26 input cases + 8 desktop scenarios for the bubble renderer (MessageTemplate.html +
sanitizer + MessageWebView). "Sanitizer" = the native allowlist pass before `beechat.setContent()`.

Run each input case across **at least three themes** (light, dark, starfleetLCARS — the
extremes of the palette range), at **fontScale 1.0 and the max setting**, and verify:
(a) rendering matches Expected, (b) exactly one settled `bcHeight` matching visual height,
(c) no horizontal bubble overflow, (d) no JS console errors, (e) theme tokens applied
before first paint (no fallback-palette flash).

| # | Case | Input sketch | Expected outcome |
|---|------|--------------|------------------|
| 1 | Plain paragraph | `<p>Hello bee</p>` | Body size = 13 × fontScale px; first/last margins stripped so height has no phantom padding. |
| 2 | Multiple paragraphs + `<br>` | 3 `<p>`, stray `<br><br>` | 0.6em gaps; `<br>` honored; no trailing gap in reported height. |
| 3 | Inline formatting | `<b><i><s><u><code>` mix | All render; inline `code` pill uses theme's code-bg token; baseline unchanged. |
| 4 | Headings h1–h6 | One of each | Capped scale (h1 = 1.35em) — headings don't shout in a bubble. |
| 5 | Nested lists 4 deep | `ul>ol>ul>ol`, long items | Indentation preserved; wrapped lines align after markers; no overflow. |
| 6 | Long unbroken token | 300-char URL / `AAAA…` | Breaks mid-token; bubble width unchanged. Re-verify during window resize (case W1). |
| 7 | Code block, long lines | `<pre>` 200-col lines | Pans horizontally *inside* the pre via horizontal wheel/trackpad (deltaX stays in-document); vertical wheel over the block still scrolls the transcript. |
| 8 | Code block, huge | 500-line `<pre>` | Renders fully; multi-thousand-px height reported once settled. |
| 9 | Nested blockquote | `blockquote>blockquote` | Stacked accent bars (theme accent token), dimmed text. |
| 10 | Wide table | 10 columns, long cells | JS wraps in `.bc-scroll-x`; horizontal pan in-document; bubble width fixed. |
| 11 | Table with colspan/rowspan | Irregular grid | Renders without layout explosion; borders use theme token. |
| 12 | Image with width/height attrs | `<img width=2000 height=1000>` | Scales to bubble width, aspect kept; height re-reported once after load. |
| 13 | Image without dimensions | Bare `<img src>` | One reflow on load; transcript anchor (MessageCanvas spacer) must not visibly jump. |
| 14 | Broken image src | 404 / bad host | `.bc-broken` placeholder + alt text; height settles; no spinner. |
| 15 | Data-URI image (1 MB+) | Base64 png | Renders; check WebContent process memory in Activity Monitor; sanitizer may cap size (policy). |
| 16 | Animated GIF | Looping GIF | Animates; with Reduce Motion, CSS animations stop (GIFs still animate — document or block). |
| 17 | Emoji-only message | `🐝🐝🐝` | Renders at body size (decide jumbo-emoji parity with native bubbles). |
| 18 | RTL text | Arabic paragraph | `dir=auto` right-aligns; punctuation correct. |
| 19 | Mixed RTL/LTR | Arabic + English + numbers | Bidi runs correct; bubble layout not mirrored. |
| 20 | Malformed HTML | Unclosed `<b>`, stray `</div>`, `<p><table>` | HTML5 error recovery; formatting may bleed within the message but never crashes; sanitizer should re-serialize balanced markup. |
| 21 | Script injection | `<script>alert(1)</script>` | Stripped by sanitizer. (innerHTML wouldn't execute it anyway — never rely on that.) |
| 22 | Event-handler injection | `<img src=x onerror=alert(1)>` | **Sanitizer must strip `on*` attributes** — this executes via innerHTML. The most important security case. |
| 23 | Scheme abuse in links | `javascript:`, `data:`, raw `file:///etc/…` | Sanitizer neuters; Swift bridge allows http/https/mailto/tel and routes `file:` through the app's file-open policy only — a message cannot open arbitrary local files. |
| 24 | Embedded frames/media | `<iframe>`, `<object>`, `<embed>`, `<video autoplay>` | Removed by allowlist; zero network requests (verify with proxy). |
| 25 | Style abuse | `<style>` tag, `style="position:fixed"` | Stripped/allowlisted; content cannot escape flow or fake UI outside its bubble. |
| 26 | Very long message | 10,000 words | Renders; height correct; transcript scroll stays smooth; consider native "Show more" truncation (product decision). |

## Desktop scenarios (macOS-specific)

| # | Scenario | Expected |
|---|----------|----------|
| W1 | **Live window resize** with 30+ mixed bubbles visible | Heights track width continuously; no stale/overlapping bubbles after drag ends; main thread stays responsive during the drag. This is the stress test the architecture most likely fails — measure before committing. |
| W2 | Theme switch across all 8 themes, transcript populated | Every live bubble flips atomically with the native chrome (tokens + `NSAppearance` both pushed); no white/fallback-palette flash; scrollbars in code blocks match. |
| W3 | fontScale change while chat open | All bubbles resize via `setFontScale`; heights re-report; anchor doesn't jump to a random message. |
| W4 | Scroll 500-message history end to end | Memory: expect monotonic growth (LazyVStack retention — this scenario *quantifies* the risk doc's core claim); count "Web Content" processes in Activity Monitor. |
| W5 | Wheel/trackpad scroll starting over a bubble | Transcript scrolls (vertical forwarding works); momentum uninterrupted crossing bubble boundaries; horizontal pan over code blocks stays in-document. |
| W6 | Right-click on bubble content | No WebKit menu ("Reload"/"Inspect Element"); the app's own menu (if any) appears. |
| W7 | Cmd+A / Cmd+F / cross-bubble drag-select | Document expected behavior: selection is per-bubble, Find doesn't search web content — known regressions vs native `Text` + `.textSelection(.enabled)`. |
| W8 | Kill a "Web Content" process in Activity Monitor | Affected bubbles blank momentarily then recover via `webViewWebContentProcessDidTerminate` reload with correct theme + content. |
| W9 | VoiceOver pass over 10 mixed messages | Every message reachable; VO doesn't trap inside a web area; order stable. |
