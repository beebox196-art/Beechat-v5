# Fable / Claude — External Super-Checker Review: WP-2 Transcript Document (Option B Milestone 2)

**Prepared by:** Bee (2026-08-06)
**Purpose:** Independent external review of the WP-2 Transcript Document — the shippable, single-WebView transcript that becomes the **load-bearing base WP-3 ports into**. This is the last big build before the native rendering code is retired. WP-0's scroll engine is ported verbatim here; if the port is not faithful, every WP-3 feature inherits the defect. You are the external super-checker — the last independent set of eyes before B2 sign-off and the WP-3 hand-off.
**How to use this prompt:** Adam copies this file into Claude (Fable) and shares the referenced evidence. Fable reviews and either SIGNS OFF or provides improvements/corrections. This is a manual process — no automation.

---

## Context for the reviewer

BeeChat-v5 (macOS) is a Swift/SwiftUI chat app with a chronic, multi-round bug class: **bottom whitespace / scroll bounce / scroll stranding** in the message transcript. After six review cycles the diagnosis is architectural: message heights are measured in one process (WKWebView) and scroll offsets applied in another (SwiftUI native ScrollView), so the two can disagree → whitespace and jumps.

**Option B** replaces the whole transcript with **ONE WKWebView** that owns both layout and scrolling — height and scroll offset live in the same layout engine, making the bug class *unrepresentable* rather than fixed. This retires ~1,900 lines of native rendering code if it succeeds.

**WP-0** (the KILL GATE feasibility spike) PASSED: the proven scroll engine passed G2 with 100/100 assertions including 50/120 hysteresis and the bounce probe. Adam signed G1, G2, G3, G6; Mel signed G4 with caveat (visual parity deferred to WP-2); G5 (Kieran) is the only WP-0 gate still pending.

**WP-2** is the production transcript document: `Sources/App/Resources/TranscriptTemplate.html` (920 lines / 30.7 KB) + the generated `Sources/App/Rendering/TranscriptTemplate.swift` constant, the `embed-template.swift` generator with `--check` drift detection, the 8-theme fixture corpus, and the CSP/sanitizer hand-off to WP-3. **This is the base WP-3 ports into** — a defect here is inherited by everything downstream.

**Your job:** independently verify the WP-2 evidence, adjudicate the port fidelity and the bridge-contract honesty, and give a verdict. Be adversarial. You are the external super-checker.

---

## Evidence to review

All in the BeeChat-v5 repo (branch `feat/transcript-document`):

- **Exit-gate bundle:** `Docs/Reviews/optionb/B2-evidence.md` (299 lines — the primary review target; covers T1–T4, the 8-theme fixture corpus, `embed-template.swift --check`, CSP, FR-MULTICOPY, and the bridge contract)
- **Build report (WP-0 provenance):** `Docs/Reviews/optionb/BUILD-REPORT.md`
- **Sign-off status:** `Docs/Reviews/optionb/E5-SIGNOFF-STATUS.md`
- **Prior review prompts (continuity):** `Docs/Reviews/optionb/FABLE-REVIEW-PROMPT-WP0.md`, `FABLE-RECHECK-PROMPT-WP0.md`, `FABLE-SUPERCHECK-WP0.md`, `FABLE-SUPERCHECK-WP0-RECHECK.md`
- **Source under review:** `Sources/App/Resources/TranscriptTemplate.html` (DOM/CSS/JS + `window.bc` bridge) and the generated `Sources/App/Rendering/TranscriptTemplate.swift`
- **Generator:** `scripts/embed-template.swift` (supports `--check` for MessageTemplate + TranscriptTemplate)
- **Tests:** `Tests/BeeChatAppTests/TranscriptTemplateTests.swift`, `TranscriptFixtureTests.swift`, `Fixtures/TranscriptFixtures.swift`
- **Spec:** `Docs/Specs/Active/single-webview-transcript-plan.md` §4 (B-2) + B2 exit gate; `Docs/Specs/Active/WP-2-csp-handoff.md`
- **Tracker (programme source of truth):** `~/Desktop/BEECHAT-BUILD-PROGRESS.html`

---

## What to scrutinise

### 1. Scroll-engine port fidelity (the highest-stakes item)

The proven WP-0 engine from `Experiments/TranscriptSpike/Sources/TranscriptSpike/Resources/transcript.html` is ported verbatim into `TranscriptTemplate.html`, with **two field-tested fixes preserved unchanged**:

- **Fix 1** — `engineScrollTop` is clamped to `scrollHeight − clientHeight` (not raw `scrollHeight`). Without this, the user-scroll detector misclassifies every engine repin as a user scroll-up (the 680px scrollHeight-vs-clientHeight mismatch leaks through the detector).
- **Fix 2** — `userScrolledUp` persists until an explicit re-pin (jump-to-latest click, pinToBottom, swapTopic, user returning to bottom band). It is NOT cleared as a side-effect of an engine repin.

Verify: are Fix 1 and Fix 2 preserved **verbatim** in the port, or subtly altered? Is the 50/120 hysteresis intact? Is the `ResizeObserver` + two-rAF deferred repin present? Does T2 (`testT2_pinHysteresisAndUserScrollPersistence`) genuinely exercise Fix 2 (scroll up → userScrolledUp=true → upsertMessages does NOT re-pin → scrollToBottom clears it)?

### 2. Bridge-contract honesty (the bcPinned question)

The template's bridge surface is **exactly 5 real events**: `bcReady` (initial signal), `bcLink` (anchor click), `bcImage` (image hydration), `bcLoadEarlier` (load-earlier button), `bcCopyMessage` (per-message copy). `grep -n "bridge("` shows exactly these 5 call sites.

**Known historical issue (now resolved):** the in-source header doc-comment previously listed `bcPinned` and `bcSelectionCopied` alongside the five real events, but `bridge()` was never called with those names — the pinned state is exposed to Swift only via `window.bc.state().pinned`, never as a bridge event. Kieran flagged this as an "optional follow-up" (B2-evidence line 297). **This has now been cleaned** (commit in `feat/transcript-document`, 2026-08-06): the header comment in both `TranscriptTemplate.html` and the regenerated `TranscriptTemplate.swift` now lists only the 5 real events, and `swift scripts/embed-template.swift --check TranscriptTemplate` exits 0 (in sync).

Verify: (a) the comment is now contract-truthful in BOTH the .html and the generated .swift; (b) `--check` passes; (c) WP-3 must NOT register a `bcPinned` message handler — `state().pinned` is the source of truth.

### 3. CSP (Mel signed, but verify the substance)

The CSP meta in `TranscriptTemplate.html` includes `form-action 'none'` (added per Mel's REQUEST CHANGES) and **intentionally omits `frame-ancestors`** — documented as not enforceable from a meta CSP in this WKWebView template; the local `loadHTMLString(..., baseURL: nil)` + navigation policy is the relevant control. `testEmbeddedTemplateHasCSPMeta` asserts each directive is present and will FAIL if any future edit drops one.

Verify: is `form-action 'none'` present and asserted? Is `frame-ancestors` correctly documented as absent (not implied as protected)? Is the WP-3 sanitizer contract binding — sanitizer must run before EVERY `window.bc.setTopic` / `upsertMessages` / `prependEarlier` / `setStreaming` payload path?

### 4. FR-MULTICOPY (A2/A3/A5 without breaking A4)

Copy affordances: per-code-block copy + per-message `bcCopyMessage`, selection-friendly (A4). Verify the affordances don't break text selection, and that `bcCopyMessage` is a real emitted event (not comment-only).

### 5. T1–T4 genuineness against real WKWebView

All four headless tests drive the real `TranscriptTemplate.html` in a real `WKWebView` via `evaluateJavaScript`, with pre-registered observable criteria and threshold constants. Documented harness limitations (E6): `evaluateJavaScript` can't return Promises (Swift-side 50ms sleep ≈ 3 frames instead of awaiting rAF); can't bridge MutationObserver (wrapped to return a boolean); `window.scrollTo` doesn't fire a scroll event in WebKit (T2/T3 dispatch it on `document.scrollingElement` explicitly).

Verify: are the T1–T4 criteria genuinely met, or is a harness workaround masking a real failure? Is the `document.scrollingElement` dispatch a legitimate correction or a test-only cheat?

### 6. `embed-template.swift` §3.1 `--check` mode + drift detection

`--check` exits 0 when the embedded Swift constant is in sync with the .html source, 1 on drift (→ regenerate → exit 0). Verify the drift-detection is real (not a no-op) and that the generated constant matches the source.

---

## Deliverable

Return a verdict: **APPROVE** / **APPROVE-WITH-CONDITIONS** / **REQUEST CHANGES**, with evidence-referenced findings ranked **blocker** vs **carry-forward**. For each finding, cite the specific file/line/commit. Be adversarial — the internal chain (Mel + Kieran + Bee) has cleared this; you are the independent check that it deserves.

---

## Known state (so you don't re-derive it)

- **B2 engineering gate:** Kieran CONDITIONS CLEARED (commit 56a1c97) — bcPinned contract + `--bc-bubble-max` removal both verified; `swift test` 396/0/0.
- **CSP:** Mel SIGNED (re-verify) after `form-action 'none'` + `frame-ancestors` documentation + WP-3 sanitizer contract (commit 23854a3).
- **Bridge doc-comment cleanup:** DONE 2026-08-06 (this review's trigger) — header now lists only the 5 real events in both .html and .swift; `--check` exits 0.
- **Pending:** Bee validation + Adam sign-off on B2; G5 (Kieran) still open for full WP-0 closure.
