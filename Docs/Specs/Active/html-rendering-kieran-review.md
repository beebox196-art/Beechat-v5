# Kieran Review: P0.0 HTML Rendering

Reviewed commit: `b38882b1932593160fa62053b8e5658436588959`

Verdict: **do not flip `BeeChat.feature.htmlRendering` ON after only the bundle fix.** The crash is the first failure, not the only one. P0.0 landed useful pieces, but the runtime integration is not yet a safe feature.

## Findings

### P0: Resource lookup is wrong for an SPM executable target

`MessageWebView.template` looks for `MessageTemplate.html` directly in `Bundle.main`:

- `Sources/App/Rendering/MessageWebView.swift:38-46`

That is not the resource contract created by `Package.swift`. The app target declares `.process("Resources")`, so SwiftPM emits a named target bundle:

- `Package.swift:100-104`
- observed build output: `.build/arm64-apple-macosx/debug/BeeChatPersistence_BeeChatApp.bundle/MessageTemplate.html`
- generated accessor: `.build/arm64-apple-macosx/debug/BeeChatApp.build/DerivedSources/resource_bundle_accessor.swift` checks `Bundle.main.bundleURL.appendingPathComponent("BeeChatPersistence_BeeChatApp.bundle")` first, then the build path.

So the current approach is not fundamentally sound. It relies on the template being flattened into the main app bundle, while SPM put it in the target resource bundle. In Debug, the missing lookup hits `assertionFailure`, which explains the SIGTRAP crash when the flag is enabled.

The right fix is a single explicit packaging contract:

1. Code should load the template from the target resource bundle, not `Bundle.main`'s top-level resources.
2. The install script should copy SwiftPM's generated resource bundle intact from `.build/arm64-apple-macosx/<configuration>/BeeChatPersistence_BeeChatApp.bundle`.
3. The copied location must match the resolver. If using SwiftPM's generated `Bundle.module`, copy the bundle to the generated `mainPath` expectation for this executable. If choosing the normal macOS app convention under `Contents/Resources`, then write a deliberate app-aware resolver that opens `Bundle.main.resourceURL/BeeChatPersistence_BeeChatApp.bundle`.
4. Add an install-time assertion that the installed app can see `MessageTemplate.html` via the same resolver the app uses.

Do not manually sprinkle `MessageTemplate.html` or resource bundles into plausible-looking places. The current `scripts/build-and-install.sh` only copies the binary into the hand-assembled `.app` and then rsyncs the app; it does not copy the SwiftPM resource bundle at all (`scripts/build-and-install.sh:33-43`). The existing checked-in `.app` only contains `Contents/Resources/AppIcon.icns`, so it cannot satisfy this feature's resource lookup.

### P0: Crash-on-missing-resource is not acceptable runtime behavior

This pattern is unacceptable for an optional, feature-flagged renderer:

- `assertionFailure("MessageTemplate.html missing from bundle...")`
- implicit fallback to a minimal HTML string

In Debug, `assertionFailure` is a trap. In Release, the fallback silently loads a template without the JS API expected by `Coordinator.apply`, so the feature can degrade into blank or inert content rather than cleanly falling back to native text.

The acceptable behavior is:

- Resource loading returns `Result`/optional state, not a trap.
- Missing template disables the HTML path for that bubble and renders the existing native text path.
- A structured diagnostic is logged once with bundle paths checked.
- A packaging/smoke test fails before the app is installed or the feature flag is flipped.

`fatalError` would be even worse. It is only defensible for impossible programmer invariants during tests or startup of mandatory infrastructure. A renderer template behind an OFF-by-default feature flag is not mandatory infrastructure.

### P0: Completed messages are not wired into the new renderer

The commit message says Architecture C: streaming uses WebView, completed messages use native `HTMLMessageConverter`. The implementation does not do that.

Streaming content has the feature-flagged HTML path:

- `Sources/App/UI/Components/StreamingBubble.swift:26-38`

Settled messages still render through `MessageContent -> FileLinkText`:

- `Sources/App/UI/Components/MessageContent.swift:8-16`
- `Sources/App/UI/Components/FileLinkText.swift:164-181`

That means the user can see rich formatting while the answer streams, then see the same answer collapse back to plain text after persistence. This is a design oversight, not acceptable P0.0 scope, because it violates the architecture docs and the commit message's own contract. The architecture doc explicitly says the renderer replaces `MessageContent`/`FileLinkText`, and Step 5 is to wire `RichMessageContent` into `MessageBubble` before the streaming swap (`Docs/Specs/Active/html-rendering-architecture.md:121-129`, `535-541`).

If P0.0 intentionally scoped only streaming, it needed to say so and keep the UX invariant: no formatting that disappears on completion. The current state gives users a false preview of a renderer the completed transcript does not actually use.

### P0: The sanitizer is not the allowlist it claims to be

`HTMLSanitizer` documents an allowed tag and attribute policy, but the implementation never applies `allowedTags` or `tagAttributes`. It removes some dangerous elements and some dangerous attributes, then returns the remaining HTML unchanged:

- declared allowlist: `Sources/App/Rendering/HTMLSanitizer.swift:38-82`
- implementation: `Sources/App/Rendering/HTMLSanitizer.swift:100-131`, `136-199`

This matters because `MessageTemplate.html` injects the result with `innerHTML`, and the template comment correctly acknowledges inline handlers are dangerous if sanitization fails:

- `Sources/App/Resources/MessageTemplate.html:192-198`

The current regex pass is not a complete HTML sanitizer. It misses the advertised "strip all unknown tags/attributes" behavior, does not parse malformed HTML as a browser would, strips quoted `style` but not unquoted style, and leaves many attributes outside the intended allowlist. This is a blocker for treating WebView rendering as safe, independent of the bundle crash.

### P1: The WebView path bypasses the existing file-link policy

The comments say WebView links route through FileLinkText's logic, but `StreamingBubble` calls `NSWorkspace.shared.open(url)` directly:

- `Sources/App/UI/Components/StreamingBubble.swift:33-35`
- `Sources/App/Rendering/MessageWebView.swift:144-149`

That is not "the same logic as FileLinkText"; it only shares the final opener. The existing `FileLinkText` path has parser/existence behavior before attaching file URLs (`Sources/App/UI/Components/FileLinkText.swift:164-181`, `184-205`). The HTML path accepts any sanitized `file:` link that survives the regex sanitizer. If `file:` remains allowed, this needs a deliberate policy decision and tests.

### P1: The converter/classifier are dead code in P0.0

`HTMLMessageConverter` and `HTMLContentClassifier` were added, but no production rendering path calls them. `HTMLMessageConverter` even includes the intended next wiring as a comment:

- `Sources/App/Rendering/HTMLMessageConverter.swift:294-295`
- `Sources/App/Rendering/HTMLContentClassifier.swift:14-21`

Keeping this code is fine as scaffold, but it cannot be counted as delivered behavior. It also has no tests in `Tests/` for sanitizer behavior, converter fallback, bundle lookup, or settled-message parity.

## Process Failure

Three crash-inducing bundle attempts without diagnosis is the process smell. The guardrail is not "try harder"; it is "stop making runtime guesses."

Required guardrails before another fix attempt:

1. Capture the actual failing path and generated resource accessor before editing packaging.
2. Add a tiny resource-resolution test or CLI smoke check that uses the same resolver as `MessageWebView`.
3. Update `scripts/build-and-install.sh` to copy the SPM resource bundle and then assert the installed app contains the expected template.
4. Run with the feature flag ON in Debug and verify first paint before declaring success.
5. For any crash behind a feature flag, preserve OFF as the default until a structured code review and a clean smoke test pass.

This should have been caught by reading `.build/.../resource_bundle_accessor.swift` and by inspecting the installed `.app` contents. Guessing bundle locations in a hand-assembled app is exactly the failure mode the packaging script should remove.

## Rollback vs Keep

Roll back or keep disabled:

- The `StreamingBubble` WebView branch should remain disabled until bundle resolution, sanitizer, and settled-message parity are fixed.
- Any manual app-bundle resource placement that is not owned by `scripts/build-and-install.sh`.
- Any crash-on-missing-resource behavior (`assertionFailure`/`fatalError`) in renderer startup.

Keep, behind the flag or as scaffold:

- `FeatureFlags.htmlRenderingEnabled`, default OFF.
- `MessageTemplate.html`, after packaging is corrected.
- `MessageWebView` structure, weak script handler, height bridge, scroll forwarding, and process-termination reset, subject to non-crashing resource load.
- `ThemeManager.cssTokens` and color helpers.
- `HTMLMessageConverter` and classifier as scaffolding, but they need tests and real `MessageContent` integration before being described as shipped.
- `SwiftSoup` dependency if the next fix actually wires the converter into completed messages.

Rework before use:

- `HTMLSanitizer` should become parser-backed allowlist sanitization, preferably using SwiftSoup since it is already in the package.
- Link/file URL handling must share a single policy between native and WebView paths.

## Risk Assessment

Can the flag be flipped ON after only fixing the bundle? **No.**

Remaining blockers:

- Completed messages still fall back to plain text, causing visible format regression at stream completion.
- Sanitization does not implement its advertised allowlist and feeds `innerHTML`.
- The WebView path opens allowed links directly through `NSWorkspace`, with a different effective policy from existing message links.
- No tests cover the new sanitizer, converter, bundle resolution, WebView first paint, or settled-message parity.
- Resource fallback behavior is currently silent/inert in Release rather than native-renderer fallback.

Minimum safe ON criteria:

1. `MessageWebView` uses a non-crashing resource resolver, and installed-app smoke test proves `MessageTemplate.html` is reachable.
2. `scripts/build-and-install.sh` copies the SwiftPM resource bundle consistently and validates it.
3. `MessageContent` routes completed messages through the same HTML rendering decision as streaming, or the streaming path is constrained to exactly the same plain-text behavior until completion rendering exists.
4. Sanitizer tests demonstrate parser-backed allowlist behavior for scripts, handlers, unknown tags, dangerous URLs, malformed HTML, images, and tables.
5. Bundle-missing and WebView-process-terminated cases fall back to native text, not crash or blank content.
6. A Debug app run with the flag ON verifies a streaming response, completion transition, theme switch, link click policy, and relaunch.

Until those are true, the feature flag is serving its purpose: it is a kill switch for incomplete integration, not evidence that the feature is safe.
