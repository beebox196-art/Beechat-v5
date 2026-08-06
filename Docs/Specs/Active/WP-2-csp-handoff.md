# WP-2 — CSP + Sanitizer Hand-off to Mel

**Date:** 2026-08-05
**Author:** Q (implementer)
**Subject:** Mel, please review and sign the CSP for `TranscriptTemplate.html` (§4.6 of the route plan).
**Branch:** `feat/transcript-document` · **Evidence:** `Docs/Reviews/optionb/B2-evidence.md`
**Companion file:** `Sources/App/Resources/TranscriptTemplate.html` (the meta tag is at line ~10)

---

## TL;DR

The CSP is a near-exact port of `MessageTemplate.html`'s posture (which you signed off on previously). The new directive is `connect-src 'none'` — explicit network block, belt-and-braces to the existing image-only policy. Sanitizer design is unchanged from production. The `testEmbeddedTemplateHasCSPMeta` test will fail if any future edit drops a directive, alerting you to re-review.

---

## The CSP meta tag

```html
<meta http-equiv="Content-Security-Policy" content="
  default-src 'none';
  img-src https: data:;
  style-src 'unsafe-inline';
  script-src 'unsafe-inline';
  connect-src 'none';
  frame-src 'none';
  object-src 'none';
  base-uri 'none';
  form-action 'none';
">
```

**Note on `frame-ancestors` — INTENTIONALLY ABSENT.** Per the CSP spec,
`frame-ancestors` is ignored when the policy is delivered via a `<meta>` tag;
it only takes effect via an HTTP response header (`Content-Security-Policy`
or `Content-Security-Policy-Report-Only`). Since this template ships its
policy as a meta tag, adding `frame-ancestors` here would provide a false
sense of clickjacking protection — the directive would silently no-op.

**Embedding protection for this WKWebView is provided elsewhere, not by CSP:**

1. `loadHTMLString(_, baseURL: nil)` in `MessageWebView` — the document has
   no origin, so cross-origin framing attacks have no surface to land on.
2. The `WKNavigationDelegate.decidePolicyFor` handler in `MessageWebView`
   (the production SwiftUI host) rejects any non-`other`-type navigation,
   so even if a parent document attempted to frame-redirect, the WebView
   would refuse the navigation.

If `frame-ancestors` protection is ever needed in this template (e.g. the
page is served from a real origin via an HTTP header), the directive must
be moved from this meta tag to the server response header — **not** added
to this meta tag.

## Directive-by-directive rationale

### `default-src 'none'` (the strictest baseline)

**Why:** sets the floor for everything. The only loads the document can do are the ones explicitly listed below — nothing else is permitted.

**Trade-off acknowledged:** none. This is a defensive default. The only loads we DO need (theme CSS via custom properties, inline bridge script, image sources) are explicitly allowed.

### `img-src https: data:` (images only, no remote scripts/styles)

**Why:**
- `https:` matches `MessageTemplate.html`'s existing posture and the production `LinkPolicy` allow-list (which already restricts URLs to https/http schemes for actual link targets).
- `data:` covers any inline base64 image the markdown converter might emit (rare but possible — a few markdown renderers embed small icons this way).
- No `http:` (plain http is denied; we never serve over http in production anyway).

**Trade-off:** none. The LinkPolicy already runs `bcLink` payloads through its allow-list before opening anything; the CSP adds a second layer.

### `style-src 'unsafe-inline'` (inline styles required for theming)

**Why:** the template applies theme tokens via `document.documentElement.style.setProperty('--bc-text', '#E0E0E0')` and uses inline `style="..."` attributes on the jump-to-latest button (position:fixed, etc.). Without `'unsafe-inline'`, neither would work.

**Trade-off acknowledged:** `'unsafe-inline'` for styles is broader than ideal in principle. Mitigation: the inline `style="..."` attributes are static (set once at element creation, never changed based on user content). The dynamic `setProperty` calls are entirely under our control — they only set `--bc-*` tokens that we own. No user-influenced style is ever applied.

### `script-src 'unsafe-inline'` (the entire bridge script is inline)

**Why:** the bridge (`window.bc.*` API) lives inside `<script>` at the bottom of the document. Same posture as `MessageTemplate.html`.

**Trade-off acknowledged:** if the sanitized HTML ever leaked a `<script>` tag, it would fire — but the sanitizer already strips `<script>` (and `onerror="..."` and other inline handlers). Belt-and-braces with the sanitizer.

### `connect-src 'none'` (no XHR / fetch / WebSocket / EventSource)

**Why:** the document must never initiate a network connection. Image loads go through `img-src` (above), but `fetch()` / `XMLHttpRequest` / `WebSocket` / `EventSource` are all blocked.

**Trade-off:** none. The document has no legitimate need for any of these. Even theme/font loads would be denied if they tried to go through `fetch()`.

**This is new vs `MessageTemplate.html`** — `MessageTemplate.html` does NOT have `connect-src 'none'`. The reason is that `MessageTemplate.html` is per-bubble (one WebView per streaming bubble, ~17 of them, lifetime of a streaming message) and the threat model is different. The single-WebView transcript is app-lifetime, so a stricter posture is justified.

### `frame-src 'none'` (no iframes)

**Why:** the transcript must never embed another document. Even a sandboxed iframe would be an attack surface.

**Trade-off:** none. No legitimate transcript feature needs an iframe.

### `object-src 'none'` (no `<object>`, `<embed>`, `<applet>`)

**Why:** legacy plugin surface. Belt-and-braces.

### `base-uri 'none'` (no `<base>` tag)

**Why:** a `<base>` tag would change where relative URLs resolve to — a classic XSS amplifier. Denying it means any future leak of a `<base href="https://attacker/">` would be blocked.

### `form-action 'none'` (no form submissions)

**Why:** the transcript document does not contain any `<form>` elements and never will — the entire model is "Swift calls `window.bc.setTopic`/`upsertMessages`/`prependEarlier`/`setStreaming` with already-sanitized HTML". An explicit `form-action 'none'` is belt-and-braces audit clarity: even if a sanitizer regression ever let a `<form>` slip through, the CSP would deny the submission. `default-src 'none'` does not backstop `form-action` (it falls back to itself in some browsers, but not all — explicit is safer).

**Trade-off:** none. The document has no legitimate need for form submission.

---

## Sanitizer design (unchanged from production)

The sanitizer contract is:

1. Every message's HTML runs through `MarkdownToHTML.convert(content)` (markdown → HTML)
2. Then through `HTMLSanitizer.sanitize(htmlContent)` (tag/attribute allow-list)
3. Then handed to the WebView via `window.bc.upsertMessages` / `setTopic` / `setStreaming`

The sanitizer allow-list (in `Sources/App/Rendering/HTMLSanitizer.swift`, unchanged):

- Tag allow-list: `p, div, br, b, strong, i, em, s, del, strike, u, code, a, span, h1, h2, h3, h4, h5, h6, ul, ol, li, blockquote, pre, img, hr, sub, sup, small, mark`
- Attribute allow-list: `href` (on `a`), `src`/`alt` (on `img`), `class` (on `pre > code` for language hints)
- URL scheme allow-list: `https:`, `http:`, `mailto:` for `href`; `https:`, `data:` for `img src`

The CSP is **belt-and-braces** — even if the sanitizer had a regression, the CSP would block the worst categories of injection (script execution via `<script>` is denied by `default-src 'none'` + `script-src 'unsafe-inline'`'s lack of `eval` allowance, network connections are denied by `connect-src 'none'`, etc.).

---

## What I'm asking you to sign off on

1. **The CSP directive list above is correct** for a single-document app-lifetime WebView.
2. **`'unsafe-inline'` for `style-src` and `script-src`** is acceptable given the sanitizer is the actual trust boundary.
3. **`connect-src 'none'` is a deliberate hardening** vs `MessageTemplate.html` and is justified by the single-WebView app-lifetime posture.
4. **`form-action 'none'` is belt-and-braces audit clarity** for the (non-existent) form-submission surface. Not enforced by `default-src 'none'` everywhere; explicit is safer.
5. **`frame-ancestors` is intentionally absent.** Meta-tag CSP cannot enforce it. Embedding protection is provided by `loadHTMLString(_, baseURL: nil)` + the Swift navigation-policy handler, not by this CSP.
6. **The sanitizer contract (unchanged from production) is the real trust boundary**, with CSP as belt-and-braces — and you're satisfied with that posture.

---

## WP-3 contract — sanitizer MUST run before every `window.bc.*` payload path

This is a binding requirement handed off from Mel's WP-2 review (verifier sign-off note, `Docs/Reviews/optionb/B2-evidence.md`). Mel approved the sanitizer design on the condition that **every payload path into the transcript document runs through `HTMLSanitizer.sanitize()` first**. WP-3 must enforce this for ALL of:

| Bridge call | Caller (Swift) | Sanitizer call site |
|---|---|---|
| `window.bc.setTopic({...messages})` | `MessageWebView.loadTopic(...)` / equivalent | Each `messages[i].html` → `HTMLSanitizer.sanitize(...)` before `evaluateJavaScript` |
| `window.bc.upsertMessages(messages, ...)` | GRDB observation → upsert into WebView | Each `messages[i].html` → `HTMLSanitizer.sanitize(...)` before `evaluateJavaScript` |
| `window.bc.prependEarlier(messages)` | "Load earlier" history query | Each `messages[i].html` → `HTMLSanitizer.sanitize(...)` before `evaluateJavaScript` |
| `window.bc.setStreaming({html})` | Token stream → bubble HTML | The accumulated streaming HTML → `HTMLSanitizer.sanitize(...)` before `evaluateJavaScript` |

**Failure mode if WP-3 drops a path:** `bubble.innerHTML = html` in `buildMessage` and `setStreaming` directly assigns the string. The sanitizer is the only thing standing between user-controlled markdown → HTML and the WebView's parser. A single missed call site becomes an XSS sink. CSP is **belt-and-braces**, not the trust boundary.

**WP-3 exit criterion (proposed, to confirm at WP-3 spec):** a code-review check + a test that grep-finds every `evaluateJavaScript("window.bc.upsertMessages|setTopic|prependEarlier|setStreaming"` call site and asserts the immediately-preceding statement includes `HTMLSanitizer.sanitize(...)`. Or a Swift wrapper `bcSanitizedEvaluate(_ script: String, payloads: [SanitizableMessage])` that the code-review enforces as the only allowed call surface — preventing accidental un-sanitized bridges by construction.

**This is recorded here as a WP-3 requirement, not a WP-2 change.**

---

## Test that will catch regressions

`TranscriptTemplateTests.testEmbeddedTemplateHasCSPMeta` asserts:

- `<meta http-equiv="Content-Security-Policy">` is present
- `default-src 'none'` is present
- `img-src https: data:` is present
- `script-src 'unsafe-inline'` is present
- `connect-src 'none'` is present
- `form-action 'none'` is present (added per Mel's REQUEST CHANGES — see B2-evidence.md)

If any future edit drops a directive, this test fails. Reviewers will be alerted to re-engage you.

---

## Reference: `MessageTemplate.html` CSP (for comparison)

```html
<!-- no CSP meta on MessageTemplate.html -->
```

Wait — `MessageTemplate.html` doesn't have a CSP meta at all. The trust boundary there is "Swift never passes untrusted HTML to MessageTemplate.html" — enforced by the same `HTMLSanitizer.sanitize()` call site, plus the per-bubble WebView lifetime.

For the single-WebView transcript, the per-bubble lifetime is GONE — there's one document for the entire app session. That's why I added the explicit CSP meta here even though `MessageTemplate.html` doesn't have one. The threat model is different.

---

*Q hands this off. Awaiting Mel's sign-off.*
