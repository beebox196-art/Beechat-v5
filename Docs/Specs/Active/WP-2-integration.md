# WP-2I — Transcript Integration (wire the WP-2 document into the app for live testing)

**Status:** DRAFT — awaiting Kieran + Q validation
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

**WP-2I must start from a clean merge of both.** Recommended: create `feat/transcript-integration` off `main`, merge `feat/transcript-boundary` then `feat/transcript-document` (or rebase both onto main). Resolve conflicts at the boundary seam (`TranscriptBoundary.swift`, `FeatureFlags.swift`, `MainWindow.swift`).

**Gate:** the merge must compile and pass the full suite (baseline 380/0/0 + WP-1 27 + WP-2 397) before any host work begins. Record the merge in the B1/B2 evidence trail.

> **Note for Adam:** WP-1's B1 gate is "awaiting Adam smoke walk" — the boundary refactor is behaviourally identical (flag flips `.native`↔`.native`). WP-2I's merge brings WP-1 in as a dependency. If Adam has not yet done the WP-1 3-topic smoke walk, it can be folded into the WP-2I smoke test (the boundary is engine-agnostic; a single walk covers both).

---

## 3. Scope — what Q builds

### 3.1 The Swift host (bring-forward of §5, minimal slice)

New file `Sources/App/UI/Transcript/WebTranscriptView.swift` — one `NSViewRepresentable` + controller, replacing the WP-1 `.web` stub (`EmptyView`):

- **One `WKWebView`, app-lifetime.** Created in `makeNSView`, never torn down on topic switch. Reuse from `MessageWebView`: `WeakScriptMessageHandler`, `drawsBackground=false` + `underPageBackgroundColor`, transparent config, `dismantleNSView` handler cleanup.
- **Load `TranscriptTemplate.html`** (the generated constant) via `loadHTMLString(_, baseURL: nil)`.
- **State diffing in `updateNSView`:** controller keeps `appliedState: TranscriptState?` and emits the minimal JS call per the §4.3 contract:
  - topicId changed → `setTopic({topicId, messages, canLoadEarlier})`
  - messages array changed → diff by id/content → `upsertMessages` (or `prependEarlier` when the head extends)
  - streaming/thinking fields changed → `setStreaming` / `setThinking`
  - tokens/fontScale → `setTheme` / `setFontScale`
  - All writes via one `evaluateJavaScript` per update cycle.
- **Bridge handlers** (§4.5): `bcReady` → replay full state; `bcLink` → `LinkPolicy` → `callbacks.onOpenLink`; `bcImage` → `callbacks.onTapImage`; `bcLoadEarlier` → `callbacks.onLoadEarlier`. **No `bcHeight`** — there is no height protocol.
- **Wire into `transcriptView(...)`** in `TranscriptBoundary.swift`: `.web` case renders `WebTranscriptView` instead of the stub.

### 3.2 The `data:` image fix (confirmed defect — security-sensitive)

**Confirmed by live probe (2026-08-06):** `HTMLSanitizer.sanitize("<img src=\"data:image/png;base64,...\">")` → `<img alt="generated">` — the `src` is stripped. Root cause: the sanitizer uses a **single `allowedSchemes` set** (`["http", "https", "mailto"]`) for **both** `href` and `src` (line 229-231). `data:` is not in it, so `data:` images are dropped.

**The WP-2 CSP handoff doc (`WP-2-csp-handoff.md`, signed by Mel) explicitly requires** `data:` for `img src` (line 125: "URL scheme allow-list: `https:`, `data:` for `img src`"). The code does not match the signed contract.

**Fix (per-attribute scheme allow-lists — do NOT add `data:` to the shared set):**
- `img src`: allow `http:`, `https:`, `data:` (matches CSP `img-src https: data:`)
- `a href`: allow `http:`, `https:`, `mailto:` (NOT `data:` — prevents `data:text/html,<script>` XSS)
- Refactor `isURLAllowed` to take the attribute/tag context, or split `allowedSchemes` into `hrefSchemes` + `srcSchemes`.

**Security note:** this is the one security-sensitive change in the task. `data:` must be allowed for `img src` ONLY, never for `href`. The existing XSS test (`data:text/html,<script>alert('xss')</script>` blocked) must still pass. Add a positive test: `data:image/png;base64,...` survives on `img src`; `data:text/html,...` still blocked on `a href`.

### 3.3 Flag gating

- `FeatureFlags.transcriptEngine` (WP-1) defaults `.native`. Flipping to `.web` renders the new host.
- **Default stays `.native`** for this task. Adam flips to `.web` to smoke-test, flips back to `.native` to return to the known-good baseline. One UserDefault, no reinstall (the escape hatch).
- `htmlRenderingEnabled` must be `true` for the web path to engage (existing gate).

---

## 4. Out of scope (deferred to WP-3, do not build here)

- **Process-death replay polish** (`webViewWebContentProcessDidTerminate` → reload + `bcReady` replay). WP-2I may include the basic `bcReady` replay (it's the same code path as initial load) but the full kill-9 self-heal verification is WP-3.
- **Context-menu filtering** (keep Copy/Copy Link/Look Up/Share; strip Reload/Go Back/Inspect Element) — WP-3.
- **Bundle-identifier fix** (for `log show` subsystem filtering) — WP-3.
- **Content-prep memoization** (`NSCache` keyed by content hash) — WP-3 if profiling shows need.
- **Full parity matrix P1–P16** — WP-4.
- **Deletion ledger** (retire legacy `MessageWebView`/`MessageCanvas`/etc.) — WP-6.

---

## 5. Acceptance criteria (exit gate B2I)

Observable, not "byte-for-byte". **E1: no gate passes on code inspection alone** — every criterion needs a running artifact.

| # | Criterion | Evidence |
|---|---|---|
| B2I-1 | Flag `.web` renders a real topic end-to-end with live streaming against the gateway | Adam live smoke test (screenshot + notes) |
| B2I-2 | `data:` image fix: `data:image/png;base64,...` renders; `data:text/html` still blocked on `href` | Sanitizer unit tests (positive + negative) + live image test |
| B2I-3 | Bridge contract honest: exactly the 5 real events (`bcReady, bcLink, bcImage, bcLoadEarlier, bcCopyMessage`); no `bcHeight` | Bridge-surface test + code inspection |
| B2I-4 | Scroll engine live: pinned-at-bottom under streaming; scroll-up + jump-to-latest works; no whitespace/bounce | Adam smoke test (the P1/P2/P5 class) |
| B2I-5 | FR-MULTICOPY live: per-code-block copy button (A2), per-message copy (A3), cross-message selection + Cmd+C (A1) | Adam smoke test (P6 class) |
| B2I-6 | Full suite green, run concurrently (E7) | `swift test` whole-suite output |
| B2I-7 | `embed-template.swift --check` exit 0 (template in sync) | `--check` output |
| B2I-8 | Rollback: flag back to `.native` restores known-good baseline, no reinstall | Adam flip-back test |

**Signs:** Q (build) → Kieran (check) → Bee (validate) → **Adam (smoke test + B2I sign-off)**. Fable super-check at milestone (Adam copies the prompt manually).

---

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Merge conflict at boundary seam (WP-1 + WP-2 diverged) | Merge gate: must compile + full suite green before host work; resolve at `TranscriptBoundary.swift`/`FeatureFlags.swift`/`MainWindow.swift` |
| `data:` fix introduces XSS if `data:` leaks to `href` | Per-attribute scheme lists; `data:` for `img src` only; existing XSS test must pass; new negative test |
| Whitespace/bounce recurs in `.web` engine | **Standing rule: any recurrence is automatically P0** (recorded in progress HTML). The WP-2 scroll engine is Fable-verified; the host must not reintroduce the bug |
| Host state-diffing bugs (wrong JS call per state change) | Truth-table tests on the diff logic (mirror WP-1 §4.5 policy-test pattern); bridge-surface test |
| Scope creep into WP-3 | §4 out-of-scope list is explicit; anything not needed to render a real topic with streaming is deferred |

---

## 7. Effort

**Estimate: 1–2 days** (host slice + `data:` fix + merge + tests). WP-3 (full host hardening) remains ~2 days later.

---

## 8. Definition of done

- `feat/transcript-integration` branch: WP-1 + WP-2 merged clean, host built, `data:` fix in, tests green.
- Kieran checked, Bee validated.
- Adam smoke-tests `.web` live; B2I signed.
- Progress HTML updated (WP-2I status → built/awaiting smoke test).
- Fable super-check prompt drafted at milestone (Adam copies manually).
