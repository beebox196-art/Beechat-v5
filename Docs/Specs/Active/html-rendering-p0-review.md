# P0.0 HTML Rendering — Review

**Commit reviewed:** `b38882b` — `feat(html-rendering): P0.0 — streaming WebView bubble + sanitizer + feature flag`
**Reviewer:** Q (P0.0 review subagent)
**Review date:** 2026-07-02
**Verdict:** ❌ **DO NOT FLIP THE FLAG ON.** Two showstopper bugs + several secondary issues. P0.0 ships functional additive code but the **flag is wired to a hard-crash path** in the assembled `.app` bundle.

---

## 0. Summary of findings

| # | Severity | Issue | Status |
|---|---|---|---|
| 1 | **CRITICAL** | `Bundle.main.url(forResource: "MessageTemplate", withExtension:)` will always fail in the assembled `.app` — see §1 | Showstopper |
| 2 | **CRITICAL** | Even if `Bundle.module` is used, SPM's generated accessor calls `Swift.fatalError` if both paths fail → hard-crash in **Release** too | Showstopper |
| 3 | **HIGH** | `assertionFailure` on missing template fires in Debug builds → SIGTRAP | Showstopper for Debug, masks bug in Release |
| 4 | **HIGH** | Feature flag has **zero effect on completed messages** — `MessageContent` still renders through `FileLinkText`. The flag gives a false sense of "HTML rendering on" | Spec/UX bug |
| 5 | **MEDIUM** | `build-and-install.sh` copies only the binary into `BeeChatApp.app/Contents/MacOS/`. The SPM-generated `BeeChatPersistence_BeeChatApp.bundle` (which contains `MessageTemplate.html`) is **never copied** into the assembled `.app` | Build script gap |
| 6 | **MEDIUM** | `@State private var featureFlags = FeatureFlags.shared` in `AppRootView.swift` is declared but never used and never injected into the environment. Dead code | Cleanup |
| 7 | **MEDIUM** | `HTMLSanitizer` uses regex-based stripping for dangerous content. Several known bypass classes (CDATA, HTML entities in attribute names, broken tag nesting) are not handled. Future-proofing risk | Security |
| 8 | **LOW** | `HTMLContentClassifier.needsWebView(html:)` always calls the full `HTMLMessageConverter.convert()` — defeats its own "lightweight check" docstring | Perf / doc bug |
| 9 | **LOW** | No tests added for any of the new code (sanitizer, converter, classifier, flags, webview bundle resolution). FC-10 ("155 existing tests pass + new tests added") is not met | Process |
| 10 | **LOW** | `ThemeManager.cssTokens` recomputes 16+ dictionary entries on every read; called from `MessageWebView.updateNSView` and inside the streaming hot path | Perf |
| 11 | **LOW** | `Color.toHex()` uses `.usingColorSpace(.sRGB)` which can return nil for catalog colors that aren't sRGB-representable (extended sRGB / P3) → falls back to `#FFFFFF`. Visible as a white flash on some custom themes | Theming |

---

## 1. Root cause analysis — the bundle resolution crash

### 1.1 What `Bundle.main` actually sees in the assembled `.app`

I inspected the actual installed `.app` bundle on disk:

```
BeeChatApp.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── BeeChatApp            ← binary only (30 MB)
    └── Resources/
        └── AppIcon.icns
```

There is **no** `MessageTemplate.html` anywhere in the bundle. There are **no** `.bundle` subdirectories either.

Yet `MessageWebView.swift:40` does:

```swift
guard let url = Bundle.main.url(forResource: "MessageTemplate", withExtension: "html"),
      let s = try? String(contentsOf: url, encoding: .utf8) else {
    assertionFailure("MessageTemplate.html missing from bundle — check Resources group")
    return "<html><body><div id=\"content\"></div></body></html>"
}
```

`Bundle.main` resolves to `BeeChatApp.app`. Its resource path is `Contents/Resources/`. That path contains `AppIcon.icns` and nothing else. **`Bundle.main.url(forResource: "MessageTemplate", withExtension: "html")` returns `nil` on every launch.**

The `else` branch is taken:

1. **Debug builds**: `assertionFailure(...)` is a debugger trap → SIGTRAP → instant crash, no stack trace Adam can read.
2. **Release builds**: `assertionFailure` is a no-op. The fallback HTML is loaded. The streaming bubble appears as a blank white rectangle (the fallback has no `setContent`/`setTheme` API surface so the WebView stays empty). User sees a silent regression — no crash, just broken output.
3. **Both builds**: the static `template` cache is now poisoned with the fallback string for the lifetime of the process. Even if `Bundle.main` later becomes valid (it never will), the cache doesn't reload.

### 1.2 Why SPM resource bundles don't end up in `Bundle.main`

`Package.swift` declares:

```swift
resources: [
    .process("Assets.xcassets"),
    .process("Resources"),     // ← MessageTemplate.html lives here
],
```

When SPM builds the `App` target, the processed resources are placed in a **separate bundle** named after the **package + target**: `BeeChatPersistence_BeeChatApp.bundle`. This lives in `.build/arm64-apple-macosx/debug/` next to the binary, NOT inside `BeeChatApp.app/Contents/Resources/`.

`Bundle.main` only searches `Contents/Resources/` of the host `.app`. It will **never** see the SPM bundle. This is the entire reason `Bundle.module` exists — to provide a static accessor that finds the SPM bundle.

### 1.3 The actual `Bundle.module` accessor (the second problem)

I extracted the SPM-generated accessor:

```swift
extension Foundation.Bundle {
    static nonisolated let module: Bundle = {
        let mainPath = Bundle.main.bundleURL
            .appendingPathComponent("BeeChatPersistence_BeeChatApp.bundle").path
        let buildPath = "/Users/openclaw/Projects/BeeChat-v5/.build/arm64-apple-macosx/debug/BeeChatPersistence_BeeChatApp.bundle"

        let preferredBundle = Bundle(path: mainPath)

        guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
            Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
        }

        return bundle
    }()
}
```

Two distinct problems here:

1. **The build-path fallback is hard-coded to the absolute path on Adam's machine.** It works during `swift build && open .build/.../BeeChatApp`, but breaks the moment the binary is relocated (rsync to `/Applications/`, Xcode "Run" copies to DerivedData, any developer with a different home directory).
2. **The fallback then calls `Swift.fatalError`** — so `Bundle.module` is no safer than `Bundle.main` + `assertionFailure`. In a hand-assembled `.app` where neither path resolves, both calls crash. The error message is more informative ("could not load resource bundle: from X or Y") but the outcome is the same: SIGTRAP in Debug, SIGABRT in Release, no recovery.

### 1.4 Root cause, in one sentence

**`build-and-install.sh` copies only the binary into `BeeChatApp.app/Contents/MacOS/`. It never copies `BeeChatPersistence_BeeChatApp.bundle` from `.build/.../debug/` into `BeeChatApp.app/Contents/Resources/`. The Swift code was written assuming the bundle would be in `Bundle.main`, which is structurally impossible for SPM-processed resources.**

The build script is the upstream cause; the Swift code is the downstream symptom. Both must be fixed before the flag is safe.

---

## 2. Recommended fix approach for bundle resolution

The right fix is **two changes, not one**. Either alone leaves a sharp edge.

### 2.1 Fix the build script (root cause)

`scripts/build-and-install.sh` must copy the SPM bundle into the `.app`:

```bash
# After copying the binary:
SPM_BUNDLE=".build/arm64-apple-macosx/debug/BeeChatPersistence_BeeChatApp.bundle"
if [ -d "$SPM_BUNDLE" ]; then
    rsync -av --delete "$SPM_BUNDLE/" "$APP_SRC/Contents/Resources/BeeChatPersistence_BeeChatApp.bundle/"
else
    echo "✗ SPM resource bundle missing — check swift build output" >&2
    exit 1
fi
```

Without this, **no fix to `MessageWebView.swift` will work in the installed `.app`** — not `Bundle.main`, not `Bundle.module`, not the `PACKAGE_RESOURCE_BUNDLE_PATH` env var trick. The bundle literally isn't where anything can find it.

Consider also wiring this into a single-source launcher (`scripts/launch.sh` or similar) if one exists, so dev runs and installed runs share the same plumbing.

### 2.2 Fix the Swift lookup (defense in depth)

Once the bundle is being copied, `MessageWebView.swift`'s lookup should:

1. **Try `Bundle.module` first** — this is the canonical accessor for SPM resources. It searches `Bundle.main.bundleURL/<bundle-name>/`, which after the build-script fix above is exactly `BeeChatApp.app/Contents/Resources/BeeChatPersistence_BeeChatApp.bundle/`. Works without any env var.
2. **Fall back to `Bundle.main.url(forResource: ...)`** as a secondary path — useful for ad-hoc Xcode runs where the bundle may end up directly in `Contents/Resources/MessageTemplate.html` if anyone ever moves it there.
3. **Fall back to `Bundle(path:)` of the build-path bundle** — useful for `swift run` / local dev where the user runs the binary from `.build/.../debug/` and the absolute path still resolves.
4. **Never crash.** If all three fail, log the resolution chain and return the fallback HTML. **The streaming bubble renders blank, the user sees plain text via the off-path** (see §4 below), and the diagnostic message in logs tells Adam where to look. No SIGTRAP.

A concrete shape (sketch — adjust to local conventions):

```swift
private static let template: String = {
    // Order: SPM module bundle (canonical) → main bundle (legacy/adhoc) → build path (dev)
    let candidates: [Bundle?] = [
        Bundle(path: Bundle.main.bundleURL.appendingPathComponent("BeeChatPersistence_BeeChatApp.bundle").path),
        Bundle.main,
        Bundle(path: ".build/arm64-apple-macosx/debug/BeeChatPersistence_BeeChatApp.bundle"),
    ]
    for bundle in candidates.compactMap({ $0 }) {
        if let url = bundle.url(forResource: "MessageTemplate", withExtension: "html"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
    }
    Logger(subsystem: "beechat", category: "rendering")
        .error("MessageTemplate.html missing — checked \(candidates.count) bundles. See build-and-install.sh.")
    return "<html><body><div id=\"content\"></div></body></html>"
}()
```

### 2.3 Should we use `PACKAGE_RESOURCE_BUNDLE_PATH`?

**No.** The `PACKAGE_RESOURCE_BUNDLE_PATH` env var trick is a hack for tools (like `swift test` or some CI configurations) that can't relocate resource bundles. It's:

- Not set by `swift build` for normal runs.
- Not set by Xcode when launching an `.app`.
- Not portable to release builds.
- Specific to one resource bundle at a time.

`Bundle.module` is the canonical accessor and works correctly once the build script copies the bundle. Don't add env-var logic unless you have evidence `Bundle.module` is genuinely broken — and after the build-script fix, it isn't.

---

## 3. `assertionFailure` / `fatalError` in production resource loading

**Neither is appropriate for resource loading.** Both are bugs:

### 3.1 `assertionFailure`

- Debug: SIGTRAP (crash). For a feature-flagged path that defaults OFF, the trap is exactly the wrong thing — the user opted into a partial feature; the app should degrade.
- Release: silent no-op. The fallback string is used. The streaming bubble appears blank. No log, no telemetry. **The user gets a silently broken feature with no signal.**

`assertionFailure` is for invariant violations that should never happen if the program is correct. "Resource file is missing" is an **environmental** failure (build script didn't run, user permissions wrong, bundle path relocated) — not an invariant.

### 3.2 `Swift.fatalError` (in the SPM-generated accessor)

- Hard crash in **both Debug and Release**.
- No graceful degradation possible — you can't even catch it.
- The error message includes the path it tried, which is helpful for developers but means nothing to users.

### 3.3 What to use instead

- Log via `os.Logger` (already imported in `AppRootView.swift`).
- Return a fallback value.
- Surface a one-time user-visible notification if the feature flag is ON and the resource is missing — "HTML rendering temporarily unavailable, falling back to plain text."

For the SPM `Bundle.module` accessor, you **cannot** override the `fatalError` — it's generated. The fix is to never invoke `Bundle.module` in a context where its failure is fatal. Use a guarded wrapper, as in §2.2.

---

## 4. Streaming-only gap — the feature flag is half-wired

### 4.1 What the spec said

`html-rendering-architecture.md` is unambiguous (line 124-135):

> | `MessageContent.swift` | **REPLACE** | Becomes a thin router: `RichMessageContent(message:)` |
> | `StreamingBubble.swift` | **EDIT** | Body switches to a streaming-capable WebView wrapper |
> ...
> ### 5.3 How StreamingBubble adapts
> `StreamingBubble.swift` changes **only its body**...
>
> RichMessageContent(message: message, streamingOverride: true)

The plan was: **both** `MessageContent` (settled messages) and `StreamingBubble` (live messages) get HTML rendering, with the same `RichMessageContent` view doing both via a `streamingOverride` flag.

### 4.2 What shipped

`MessageContent.swift` was **not touched**:

```swift
struct MessageContent: View {
    @Environment(ThemeManager.self) var themeManager
    let message: Message
    var body: some View {
        if let content = message.content, !content.isEmpty {
            FileLinkText(content: content)            // ← plain text, always
                .font(themeManager.font(.body))
                .textSelection(.enabled)
        } else {
            Text(" ")
                .font(themeManager.font(.body))
        }
    }
}
```

`StreamingBubble.swift` got the WebView path. `MessageContent.swift` didn't. **The feature flag has zero effect on the settled message stream.**

### 4.3 What this means in practice

If Adam flips the flag ON:

- **While the AI is streaming**: rich WebView rendering. Looks great.
- **The moment streaming completes**: the bubble switches from `StreamingBubble` to `MessageBubble → MessageContent → FileLinkText`. The bubble **snaps** from formatted HTML to raw markdown text.

That's not a partial rollout — it's a visual regression. A user who sees `<b>Hello</b>` rendered bold mid-stream will see the literal text `<b>Hello</b>` once streaming completes. Worse than not flipping the flag at all.

### 4.4 Why this matters beyond the obvious

The architecture doc's **FC-8** ("plain-text messages render with parity to today's `FileLinkText` output") and **FC-6** ("bubble shape unchanged") **cannot be satisfied** while `MessageContent` is on the old path. The bubble shape will change on every streaming completion. This is a spec violation that the commit message glosses over with "Architecture C: streaming bubble is ALWAYS a WebView, completed messages will use native AttributedString via HTMLMessageConverter" — the second half of that sentence is **a future promise, not delivered code**.

`HTMLMessageConverter.swift` and `HTMLContentClassifier.swift` are scaffolds — the render sketch at the bottom is a comment, the `ConvertedMessageView` is not implemented, `MessageContent` is not wired to consume `needsWebView`. None of it ships.

### 4.5 What needs to change before the flag flips ON

**Minimum to safely enable the flag:**

1. `MessageContent.swift` must call into `HTMLContentClassifier` (or directly `HTMLMessageConverter.convert`) and route to:
   - `ConvertedMessageView(converted:)` if `needsWebView == false` — native AttributedString path.
   - `MessageWebView(html: ...)` if `needsWebView == true` — WebView path for tables, etc.
2. Implement `ConvertedMessageView` (the comment sketch at the bottom of `HTMLMessageConverter.swift`). It's small (~50 lines: paragraph, code block, list, quote, image, rule) but it doesn't exist.
3. The flag default stays OFF until both paths are exercised end-to-end.

**The feature flag is a tool, not a gate.** It gates the *risk surface* of turning on a feature, but it cannot gate a feature that is half-implemented. Either ship both paths or ship neither.

---

## 5. What else needs to change before the flag is safely ON

Beyond §1-§4:

### 5.1 Build script must copy the SPM bundle (see §2.1)

Without this, the fix in §2.2 is dead code.

### 5.2 Dead `@State` on `AppRootView`

```swift
@State private var featureFlags = FeatureFlags.shared
```

This is declared but never read, never bound into the environment. `StreamingBubble` reads `FeatureFlags.shared` directly via the singleton — which works but **bypasses the `@Observable` propagation model entirely**. When the user flips the flag at runtime via `FeatureFlags.shared.htmlRenderingEnabled = true`, no view will re-render because nothing is observing the singleton's mutation. The flag has to be toggled at app relaunch for changes to take effect. That's not what `@Observable` promises.

**Recommended:** either (a) actually inject `featureFlags` into the environment and consume it via `@Environment(FeatureFlags.self) var featureFlags` in `StreamingBubble` and `MessageContent`, or (b) remove the unused `@State` declaration. The current state is the worst of both worlds.

### 5.3 Sanitizer regex is not a sanitizer

`HTMLSanitizer.swift` uses regex to strip `<script>`, `<style>`, etc. Regex cannot correctly parse HTML. Known issues:

- **CDATA sections**: `<![CDATA[<script>...]]>` defeats the regex strip in some configurations.
- **Attribute names with spaces or newlines**: `<a href="javascript:alert(1)" target="_blank">` — the URL-stripping regex looks at `href` and `src` but if the attribute is split across lines (`<a\nhref="javascript:...">`) the regex misses it.
- **Encoded attribute values**: `&#x6A;avascript:alert(1)` — the regex matches `javascript:` literally; entity-decoded equivalents slip through.
- **Malformed nesting**: `<<script>script>` — `replacingOccurrences` with a non-greedy `.*?` may produce invalid output on pathological input.
- **`<noscript>` removal**: stripping `<noscript>` is correct for WebView (which has JS enabled), but the regex strips its content. If a sanitizer-upstream allows `<noscript>` text as accessibility content, that's lost.

**This is a v1 acceptable compromise only if the WebView is the final defense** (which it is — WebKit's renderer will not execute `<script>` tags regardless of what reaches it, and the WKNavigationDelegate blocks navigation). But the doc comment "the sanitizer runs *before* `HTMLMessageConverter` ... the *authoritative* sanitizer at the app ingest layer" overstates its guarantees.

**Recommended:** swap to SwiftSoup for sanitization too. It's already a dependency. The sanitizer becomes "parse → walk → emit only allowed nodes/attributes". About 60 lines of real code, replaces 200 lines of regex.

### 5.4 `HTMLContentClassifier.needsWebView` is not lightweight

```swift
static func needsWebView(html: String) -> Bool {
    // ...
    let result = HTMLMessageConverter.convert(html)
    return result.needsWebView
}
```

This calls the full converter, builds all `[MessageBlock]` values, then throws them away to read one boolean. The docstring says "This runs a lightweight check — it parses the HTML and walks for unknown tags, but doesn't build the full `[MessageBlock]` output." That is a lie.

**Either:** implement the docstring (a fast tag-only scan that exits early on the first non-native tag) — `SwiftSoup.parseBodyFragment(html)` then walk `body.getChildNodes()` and check each element's tag against `HTMLMessageConverter.nativeTags`. Bail on first miss.

**Or:** delete the classifier and inline `result.needsWebView` at the call site.

### 5.5 No tests

FC-10 in the spec says:

> **FC-10:** 155 existing tests pass + new tests added (sanitiser, CSS, memory gate).

The commit added **zero tests**:

- `HTMLSanitizer.sanitize` — test cases for `<script>`, `onerror`, `javascript:`, `data:`, oversized input, balanced/inbalanced tags.
- `HTMLMessageConverter.convert` — test cases for each native tag, table→needsWebView, depth/node/length caps, `<pre>` whitespace preservation, intent unioning.
- `HTMLContentClassifier.needsWebView` — boundary cases.
- `FeatureFlags` — UserDefaults round-trip.
- **Bundle resolution** — most important. A test that fails the build if `MessageTemplate.html` can't be found in `Bundle.module`. This would have caught the b38882b bug before it shipped.

The BeeChat-v5 test discipline (155 tests passing on every commit) is the reason this project doesn't have regressions. Skipping it on a new module is exactly when the new module ships bugs.

### 5.6 `ThemeManager.cssTokens` allocates 16 entries on every call

This is called inside `MessageWebView.updateNSView` and inside the streaming hot path. Most calls don't change tokens — only `fontScale` does. Consider caching the static entries, or splitting into `staticThemeTokens()` and `dynamicFontScaleToken()`.

### 5.7 `Color.toHex()` falls back to `#FFFFFF`

`NSColor(self).usingColorSpace(.sRGB)` returns nil for colors outside the sRGB gamut (extended sRGB / Display P3). BeeChat's 8 themes use accent colors that may be wider gamut (the spec mentions "eight custom themes"). Falling back to `#FFFFFF` produces a visible white flash on the WebView's first paint for those themes. Resolve via `.extendedSRGB` or use `NSColor` directly without `.usingColorSpace` and accept whatever the working color space is.

---

## 6. Other P0.0 issues spotted

### 6.1 File-link routing diverges from FileLinkText

`StreamingBubble`'s WebView path does:

```swift
onLink: { url in
    NSWorkspace.shared.open(url)
}
```

…while the docstring claims "routes through FileLinkText's open logic". `FileLinkText` does much more than `NSWorkspace.shared.open` — it dispatches file paths through `FilePathParser`, validates against the path allowlist, and gates via the `openURLAction` policy. Streaming bubbles bypass all of that. A WebView-rendered link to a `.swift` file will open via the OS default app (probably Xcode or TextEdit), not through BeeChat's previewer.

The WKNavigationDelegate blocks navigation; the `bcLink` channel is the right escape hatch — but the handler must be the **same** `onLink` that `FileLinkText` uses, not a one-liner.

### 6.2 Feature flag is a `static let` singleton

```swift
final class FeatureFlags {
    static let shared = FeatureFlags()
    var htmlRenderingEnabled: Bool { didSet { ... } }
}
```

Three issues:

1. **`@MainActor` + `static let`** — first access from a non-main thread (e.g. a background message ingest task) will trip the actor check. The `htmlRenderingEnabled` setter is implicitly main-actor-isolated.
2. **Mutable singleton** — global mutable state. Tests that flip the flag have to remember to flip it back, or use a separate process.
3. **No Combine / AsyncSequence bridge** — `@Observable` is fine for SwiftUI consumers, but anything reading the flag from a non-SwiftUI context (background sanitizer task, accessibility client) won't observe changes.

For a single-flag v1 this is fine. For the next 5 flags it isn't.

### 6.3 `BaseURL` is `nil` on the WebView

`webView.loadHTMLString(Self.template, baseURL: nil)`. This is correct from a security standpoint (no network access from `file://` etc.) but means:

- `<base href="...">` inside the template is ignored.
- Any relative URL in `bcLink` resolves against the current document, not a known base.
- WebKit's default origin policy treats `nil` baseURL as `about:blank` — fine for this use case, but worth documenting.

### 6.4 ResizeObserver on every CSS recompute

`MessageTemplate.html` declares a `ResizeObserver` that fires on every content mutation. With 5fps streaming and a 200-token response, that's ~25 ResizeObserver callbacks per response, each round-tripping to the Swift side. Consider debouncing in JS (`requestAnimationFrame`) to one callback per frame.

### 6.5 `allowsMagnification = false` is correct but worth a comment near `setValue(false, forKey: "drawsBackground")`

The latter is undocumented KVO. It works but it's load-bearing. A one-line comment noting the WebKit version compatibility (or a defensive `setValue` that catches the exception if Apple removes the keypath) would help future maintenance.

### 6.6 `Color.darken(by:)` is not used in the WebView path

`cssTokens["--bc-link"] = isDark ? accent.toHex() : accent.darken(by: 0.2).toHex()`

`darken(by:)` is only called when the appearance is light. If a dark-theme user picks a light link accent, the darker variant is never applied. Probably fine, but the asymmetry should be deliberate — add a comment.

---

## 7. Recommended sequencing for the fix

Given the architecture decision (Architecture C, native-first hybrid), the cleanest path forward is:

1. **Fix the build script** to copy `BeeChatPersistence_BeeChatApp.bundle` into `Contents/Resources/`. (5 min, unblocks everything.)
2. **Fix the template lookup** in `MessageWebView.swift` per §2.2 — `Bundle.module` first, fallback to `Bundle.main`, never crash. (15 min.)
3. **Wire `MessageContent.swift`** to `HTMLContentClassifier` → either `ConvertedMessageView` or `MessageWebView`. (1 hour, including the `ConvertedMessageView` implementation.)
4. **Add tests** for the bundle resolution, the sanitizer, and the converter. The bundle-resolution test alone would prevent this regression class forever. (2 hours.)
5. **Validate FC-1 through FC-10** end-to-end with the flag ON in dev. Smoke-test in all 8 themes. Run the full 155-test suite to confirm no regressions.
6. **Then** flip the flag ON in UserDefaults for Adam to smoke-test.
7. **Only after Adam confirms** is the feature ready to be turned ON by default.

P0.0 ships a feature that's 60% done. The 40% is exactly the half (settled messages + tests + build plumbing) that makes the difference between "looks great while streaming, broken when it completes" and "works end to end."

---

## 8. Verdict

**Do not flip `BeeChat.feature.htmlRendering` to `true` until §1, §4, and §5.1-§5.2 are fixed and verified.** The current state is a footgun that:

- Hard-crashes on Debug installs (SIGTRAP).
- Hard-crashes on Release installs if any future change adds `Bundle.module` without the build-script fix (SIGABRT).
- Silently breaks settled-message rendering (no crash, just wrong output).
- Has no test coverage to catch regressions.

The code that did ship is reasonable, well-commented, and structurally sound. The path to "ready" is short — it's plumbing (build script, bundle lookup, MessageContent wiring) and tests, not redesign.

---

*Reviewed by Q subagent, session `agent:q:subagent:fd0834a9-5867-488a-b385-4a9fd2bff6a1`. Findings based on `git show b38882b` + on-disk inspection of `BeeChatApp.app/`, `.build/.../BeeChatPersistence_BeeChatApp.bundle/`, the SPM-generated `resource_bundle_accessor.swift`, and the relevant source files. No build was performed; review is static + filesystem analysis.*