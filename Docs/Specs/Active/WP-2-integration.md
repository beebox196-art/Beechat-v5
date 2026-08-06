# WP-2I — Transcript Integration (wire the WP-2 document into the app for live testing)

**Status:** DRAFT — Q validation SOUND WITH FIXES (2026-08-06); fixes applied §2/§3.1/§3.2/§5. Awaiting Kieran sign-off then dispatch to Q.
**Author:** Bee (spec) · **Builder:** Q · **Checker:** Kieran · **Validator:** Bee · **Smoke test:** Adam
**Branch:** `feat/transcript-integration` (new, off the merge of WP-1 + WP-2)
**Spec source:** `Docs/Specs/Active/single-webview-transcript-plan.md` §5 (Swift host) + §4.3/§4.5 (bridge contract)
**Date:** 2026-08-06

---

## 0. Why this exists

The WP-2 transcript document (`TranscriptTemplate.html` + generated `TranscriptTemplate.swift`) is **built and Fable-approved** (APPROVE WITH CONDITIONS, 2026-08-06 — "B2 is signable, WP-3 can start"). But **no Swift code drives it** — `window.bc.setTopic` has no caller. The running app (0.9.5f) uses the legacy per-message WebView path, so the WP-2 feature **cannot be smoke-tested live**.

This task wires the WP-2 document into the topic view behind the existing `htmlRenderingEnabled` / `transcriptEngine` flag so Adam can test WP-2 in a live environment. It is the **bring-forward of the WP-3 Swift host** (§5 of the route plan) to a minimal-but-correct degree: enough to render a real topic end-to-end with streaming, so the Fable-approved document is actually exercised.

**This is NOT the full WP-3.** WP-3 (parity, hardening, process-death replay polish, context-menu filtering, bundle-id fix) remains a separate later gate. WP-2I is the *integration slice* that unblocks live testing. Anything not needed to render a real topic with streaming is deferred to WP-3 and noted as such.

---

## 1. Process (Adam-mandated, binding)

Per the standing workflow (recorded in `BEECHAT-BUILD-PROGRESS.html` Evidence tab and `Docs/Specs/Active/` process doc):

1. **Bee** writes this spec.
2. **Kieran + Q** validate the spec is sound.
3. Once agreed → dispatch to **Q** to build.
4. **Kieran** checks the work is done and correct.
5. **Bee** validates before returning to Adam.
6. At **milestone only**: Bee writes a review prompt `.md` → Adam copies to **Fable** (external super-checker, manual).

**Q builds everything.** E5 applies: implementer cannot sign their own gate.

---

## 2. Branch sequencing (critical dependency)

The two prerequisite branches have **diverged** (neither is an ancestor of the other; common base `a008278`):

- `feat/transcript-boundary` (WP-1) — 4 commits: `5ae493d` (boundary rename-and-wrap), `d7ebbe2` (§4.5 policy move), `403fa87` (feature-flags didSet), `83dc233` (B1 evidence). **Not merged to main.**
- `feat/transcript-document` (WP-2) — ~10 commits incl. `5d814fa`/`c0df445`/`726a514` (Fable fixes). **Not merged to main.**

**WP-2I must start from a clean merge of both.** Recommended: create `feat/transcript-integration` off `main`, merge `feat/transcript-boundary` (WP-1, smaller + mechanical) **first**, rebase `feat/transcript-document` (WP-2) onto the result, then build the WP-2I host on top.

**Merge seam (Kieran validation, 2026-08-06 — corrected):** WP-1 and WP-2 modify **disjoint file sets vs `main`**; the intersection is **empty**. WP-1 touches `MessageCanvas.swift` / `MainWindow.swift` / `FeatureFlags.swift` (and adds `TranscriptBoundary.swift`); WP-2 touches `MessageTemplate.swift` / `Package.swift` / `ThemeManager.swift` / `ShadowToken.swift` (and adds the `TranscriptTemplate.{swift,html}` constants + `embed-template.swift`). **No file is in both diffs vs `main`** — the merge should be **conflict-free**; the merge gate is `swift build` + `swift test` green, not source-tree surgery. (The earlier `git diff feat/transcript-boundary feat/transcript-document --stat` quote was misleading — that command shows files *different between the two branches*, not files *both modify vs main*; it has been removed.) Record the merge commit in the B1/B2 evidence trail.

**Gate:** the merge must compile and pass the full suite before any host work begins. **Baseline numbers to be verified at merge time (Q validation, 2026-08-06):** the WP-2I spec §2 originally cited "baseline 380/0/0 + WP-1 27 + WP-2 397", but `Tests/BeeChatAppTests/TranscriptTemplateTests.swift:25` says "baseline 407/0/0 from WP-1 must still hold". **Run the WP-1 and WP-2 test suites independently at merge and record the ACTUAL pass/fail numbers**, then update this section + B2I-6 evidence with what is really seen — do not commit a guessed baseline. Record the merge commit in the B1/B2 evidence trail.

> **Note for Adam:** WP-1's B1 gate is "awaiting Adam smoke walk" — the boundary refactor is behaviourally identical (flag flips `.native`↔`.native`). WP-2I's merge brings WP-1 in as a dependency. If Adam has not yet done the WP-1 3-topic smoke walk, it can be folded into the WP-2I smoke test (the boundary is engine-agnostic; a single walk covers both).

---

## 3. Scope — what Q builds

### 3.1 The Swift host (bring-forward of §5, minimal slice)

New file `Sources/App/UI/Transcript/WebTranscriptView.swift` — one `NSViewRepresentable` + controller, replacing the WP-1 `.web` stub (`EmptyView`).

> **⚠ Naming-collision resolution (Q validation, 2026-08-06):** WP-1's `TranscriptBoundary.swift` **already declares `struct WebTranscriptView: View` as `EmptyView()`** (lines 196-208). Adding `Sources/App/UI/Transcript/WebTranscriptView.swift` without deleting that stub → **two types with the same name → compile error**. **Resolution: Option α (clean, adopted).** Delete the `WebTranscriptView` stub from `TranscriptBoundary.swift`, add the real `WebTranscriptView.swift` (NSViewRepresentable), and replace `case .web` in `transcriptView(...)` to instantiate the new host. Single source of truth for the type. (Option β — keep both with a `WebTranscriptViewStub` rename — rejected as extra diff noise; the stub is dead weight the moment the real host lands.)

- **One `WKWebView`, app-lifetime.** Created in `makeNSView`, never torn down on topic switch. Reuse from `MessageWebView`: `WeakScriptMessageHandler`, `drawsBackground=false` + `underPageBackgroundColor`, transparent config, `dismantleNSView` handler cleanup.
- **Load `TranscriptTemplate.html`** (the generated constant) via `loadHTMLString(_, baseURL: nil)`.
- **State diffing in `updateNSView`:** controller keeps `appliedState: TranscriptState?` and emits the minimal JS call per the §4.3 contract:
  - topicId changed → `setTopic({topicId, messages, canLoadEarlier})`
  - messages array changed → diff by id/content → `upsertMessages` (or `prependEarlier` when the head extends)
  - streaming/thinking fields changed → `setStreaming` / `setThinking`
  - tokens/fontScale → `setTheme` / `setFontScale`
  - All writes via one `evaluateJavaScript` per update cycle.
- **Bridge handlers** (§4.5): `bcReady` → replay full state; `bcLink` → `LinkPolicy` → `callbacks.onOpenLink`; `bcImage` → `callbacks.onTapImage`; `bcLoadEarlier` → `callbacks.onLoadEarlier`; `bcCopyMessage` → route to the multi-copy path. **No `bcHeight`** — there is no height protocol.
- **`bcCopyMessage` pasteboard path (Kieran nit N3, 2026-08-06 — Q MUST verify before implementing):** the template's bridge helper (`TranscriptTemplate.html:575-580`) reads `bubble.textContent` in-DOM, calls `copyToClipboard(text)`, and only sends `{id, ok}` over the bridge. So the Swift `bcCopyMessage` handler is **mostly a no-op or a state-update** — the actual pasteboard write happens in the document, NOT in Swift. **Do NOT wire a Swift-side pasteboard write** (redundant; the template already wrote). **Risk:** the DOM-side `navigator.clipboard.writeText` inside a synthesized event handler from a non-user-gesture context may be **blocked by macOS WebKit's security model** under `loadHTMLString(_, baseURL: nil)`. **Q must verify the in-DOM pasteboard write actually works on a real user-click gesture.** If it fails silently, escalate: either (a) update `TranscriptTemplate.html` to send `{id, text}` in the bridge payload so Swift writes to pasteboard, or (b) accept A3 depends on the DOM-side write. Do not hand-wave A3 (per-message copy) until this is confirmed.
- **Initial-state-push contract (Q validation, 2026-08-06 — pinned):** the host **registers bridge handlers in `makeNSView`**, holds incoming state in `pendingState`, and fires the **first `evaluateJavaScript` chain ONLY after `bcReady` arrives** (mirroring `MessageWebView.swift` lines 152-157). Pushing before the template is loaded returns null/throws and silently loses the first update. `bcReady` → replay full state from `pendingState`.
- **`bcReady` inverse invariant (Kieran must-fix #1, 2026-08-06):** the `bcReady` handler **MUST always call `applyState(pendingState)` regardless of the `appliedState` value** — including the very first fire where `appliedState == nil`. First-load and recovery use the **same code path**. **Do NOT add a `.fault` tripwire for "`bcReady` with content already applied"** — that pattern (present at `MessageWebView.swift:157`) catches recovery but masks first-load; replicating it in the new host would turn the legitimate first load into a fault. Treat "no state applied yet" as normal initial-load, not an anomaly.
- **Wire into `transcriptView(...)`** in `TranscriptBoundary.swift`: `.web` case renders `WebTranscriptView` instead of the stub.

### 3.2 The `data:` image fix (confirmed defect — security-sensitive)

**Confirmed by live probe (2026-08-06):** `HTMLSanitizer.sanitize("<img src=\"data:image/png;base64,...\">")` → `<img alt="generated">` — the `src` is stripped. Root cause: the sanitizer uses a **single `allowedSchemes` set** (`["http", "https", "mailto"]`, at `HTMLSanitizer.swift:97`) for **both** `href` and `src` — the shared `urlAttributes` set (line 100) feeds `isURLAllowed()` (line 263) from both the `href` and `src` paths in `emitAllowedElement` (line ~229: `if urlAttributes.contains(key) { … if !isURLAllowed(value) { continue } }`). `data:` is not in the set, so `data:` images are dropped.

> **Q validation (2026-08-06):** the spec clarified the precise line locations to aid Q's refactor — `allowedSchemes` at **line 97**, `urlAttributes` at **line 100**, `isURLAllowed` at **line 263**. (The earlier "line 229-231" reference pointed at the `urlAttributes.contains(key)` + `isURLAllowed(value)` call sites in `emitAllowedElement`, which remain the right references for the structural claim.) Structural claim stands — the shared set feeds both attribute paths.

**The WP-2 CSP handoff doc (`WP-2-csp-handoff.md`, signed by Mel) explicitly requires** `data:` for `img src` — line 125 verbatim: "URL scheme allow-list: `https:`, `http:`, `mailto:` for `href`; `https:`, `data:` for `img src`". The code does not match the signed contract. (Note: the CSP contract allows `http:` for `href` — match Mel's signed contract, not a paraphrase.)

**Fix (per-attribute scheme allow-lists — do NOT add `data:` to the shared set). Q's preferred refactor (adopted):** split into `hrefSchemes: ["http", "https", "mailto"]` + `srcSchemes: ["http", "https", "data"]`, and make `isURLAllowed` take `(value: String, attribute: String)`. Less invasive than threading tag+attribute context through; the attribute name is already known at the call site (line ~229). This keeps the function shape simple.
- `img src`: allow `http:`, `https:`, `data:` (matches CSP `img-src https: data:`)
- `a href`: allow `http:`, `https:`, `mailto:` (NOT `data:` — prevents `data:text/html,<script>` XSS)

**Security note:** this is the one security-sensitive change in the task. `data:` must be allowed for `img src` ONLY, never for `href`. The existing XSS test (`data:text/html,<script>alert('xss')</script>` blocked on `<a href>`, at `HTMLSanitizerTests.swift:249`; `javascript:` on `<img src>` at line 278) must still pass. **Test gap (Q validation + Kieran nit N1, 2026-08-06):** there is **no positive test for `<img src="data:image/png;base64,...">`** — add **at least three** positive tests confirming the data URI survives on `img src` (`data:image/png`, `data:image/jpeg`, `data:image/gif` — model providers emit all three), plus the negative `data:text/html` still blocked on `a href`.

### 3.3 Flag gating

- `FeatureFlags.transcriptEngine` (WP-1) defaults `.native`. Flipping to `.web` renders the new host.
- **Default stays `.native`** for this task. Adam flips to `.web` to smoke-test, flips back to `.native` to return to the known-good baseline. One UserDefault, no reinstall (the escape hatch).
- `htmlRenderingEnabled` must be `true` for the web path to engage (existing gate).

---

## 4. Out of scope (deferred to WP-3, do not build here)

- **Process-death replay VERIFICATION/polish** (kill-9 self-test, logging, telemetry of `webViewWebContentProcessDidTerminate`). **IN SCOPE for WP-2I (Q validation, 2026-08-06):** the `webViewWebContentProcessDidTerminate` handler itself — `func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.loadHTMLString(...); /* bcReady fires → replays */ }` (~3 lines) — because killing WebContent (normal under macOS memory pressure, not just kill-9) → blank transcript with no recourse except app restart, and the route plan lists it as a P9 hard requirement. The kill-9 self-test, logging, and telemetry polish remain WP-3.
- **Context-menu filtering** (keep Copy/Copy Link/Look Up/Share; strip Reload/Go Back/Inspect Element) — WP-3.
- **Bundle-identifier fix** (for `log show` subsystem filtering) — WP-3.
- **Content-prep memoization** (`NSCache` keyed by content hash) — WP-3 if profiling shows need.
- **Full parity matrix P1–P16** — WP-4.
- **Deletion ledger** (retire legacy `MessageWebView`/`MessageCanvas`/etc.) — WP-6.

> **Composer note (Q validation, 2026-08-06):** the composer lives **outside** `transcriptView(...)` in `MainWindow.swift` (above the boundary), so it is **unaffected by the engine flag flip** — Adam can compose/send in either engine, and the transcript area reflects whichever engine is active. No composer work is needed in WP-2I.

---

## 5. Acceptance criteria (exit gate B2I)

Observable, not "byte-for-byte". **E1: no gate passes on code inspection alone** — every criterion needs a running artifact.

| # | Criterion | Evidence |
|---|---|---|
| B2I-1 | Flag `.web` renders a real topic end-to-end with live streaming against the gateway | Adam live smoke test (screenshot + notes). **Evidence must include Adam composing 2+ messages in a row in `.web` mode** to exercise the streaming → settle → upsert diff path (`upsertMessages`), not just a single message that only triggers `setTopic` (Q validation, 2026-08-06) |
| B2I-2 | `data:` image fix: `data:image/png;base64,...` renders; `data:text/html` still blocked on `href` | Sanitizer unit tests (positive + negative) + live image test |
| B2I-3 | Bridge contract honest: exactly the 5 real events (`bcReady, bcLink, bcImage, bcLoadEarlier, bcCopyMessage`); no `bcHeight` | Bridge-surface test + code inspection. **Evidence (Kieran must-fix #3, 2026-08-06):** route plan `single-webview-transcript-plan.md` §4.5 was **already corrected in commit `bf3a5ef`** — `bcPinned` dropped, `bcCopyMessage` added (WP-2's shipped contract: 5 events, no `bcPinned`, `bcCopyMessage` at `TranscriptTemplate.html:579`). B2I-3 evidence must **reference that this correction is already complete in the merged tree** — it is NOT an action for Q to redo. |
| B2I-4 | Scroll engine live: pinned-at-bottom under streaming; scroll-up + jump-to-latest works; no whitespace/bounce | Adam smoke test (the P1/P2/P5 class) |
| B2I-5 | FR-MULTICOPY live: per-code-block copy button (A2), per-message copy (A3), cross-message selection + Cmd+C (A1) | Adam smoke test (P6 class) |
| B2I-6 | Full suite green, run concurrently (E7) | `swift test` whole-suite output — **with the ACTUAL pass/fail numbers captured at merge per §2** (baseline cited as 380/0/0 but `TranscriptTemplateTests.swift:25` says 407/0/0 — verify which is real before commit) |
| B2I-7 | `embed-template.swift --check` exit 0 (template in sync) | `--check` output |
| B2I-8 | Rollback: flag back to `.native` restores known-good baseline, no reinstall | Adam flip-back test |

**Signs:** Q (build) → Kieran (check) → Bee (validate) → **Adam (smoke test + B2I sign-off)**. Fable super-check at milestone (Adam copies the prompt manually).

---

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Merge conflict (WP-1 + WP-2 diverged) | Merge gate: must compile + full suite green before host work. **Per §2, the merge is conflict-free** (disjoint file sets vs `main`); gate is `swift build` + `swift test` green, not source-tree surgery. |
| `data:` fix introduces XSS if `data:` leaks to `href` | Per-attribute scheme lists; `data:` for `img src` only; existing XSS test must pass; new negative test |
| Whitespace/bounce recurs in `.web` engine | **Standing rule: any recurrence is automatically P0** (recorded in progress HTML). The WP-2 scroll engine is Fable-verified; the host must not reintroduce the bug |
| Host state-diffing bugs (wrong JS call per state change) | Truth-table tests on the diff logic (mirror WP-1 §4.5 policy-test pattern); bridge-surface test |
| Scope creep into WP-3 | §4 out-of-scope list is explicit; anything not needed to render a real topic with streaming is deferred |

---

## 7. Effort

**Estimate: 2 days.** Per §2 the merge is conflict-free (no source-tree surgery), so the buffer is for cross-engine smoke-test cycles + the bcCopyMessage pasteboard-write verification per §3.1. Host slice + `data:` fix + tests ≈ 310 LOC (WebTranscriptView bridge + diffing ≈ 250; sanitizer refactor + tests ≈ 60). WP-3 (full host hardening) remains ~2 days later.

---

## 8. Definition of done

- `feat/transcript-integration` branch: WP-1 + WP-2 merged clean, host built, `data:` fix in, tests green.
- Kieran checked, Bee validated.
- Adam smoke-tests `.web` live; B2I signed.
- Progress HTML updated (WP-2I status → built/awaiting smoke test).
- Fable super-check prompt drafted at milestone (Adam copies manually).
