# WP-1 — Transcript Boundary Refactor

**Author:** Bee
**Date:** 2026-08-05
**Version:** 2.0 (folded Kieran + Q spec validation)
**Status:** SPEC v2 — pending Kieran + Q re-validation of changes
**Workflow:** Bee spec → Kieran+Q validate → dispatch Q to build → Kieran check → Bee validate → Adam sign-off. External super-checker (Fable/Claude) at milestone only.
**Source:** `Docs/Specs/Active/single-webview-transcript-plan.md` §2 (Phase B-1) + Desktop tracker `BEECHAT-BUILD-PROGRESS.html`
**Builder:** Q · **Spec validation:** Kieran + Q · **Check:** Kieran + Bee · **Branch:** `feat/transcript-boundary`
**Estimate:** ~half a day (policy-move step may add up to a half day) · **Exit gate:** B1

---

## 1. Goal

Make the message window a **swappable component** behind a single typed boundary, with a `FeatureFlags.transcriptEngine` toggle (default `.native`). Pure refactor of the *structure*, not the *behaviour*: the app must behave identically on `.native`. Ships standalone value even if the rest of Option B stalls, and is the modularity seam for WP-2/WP-3.

## 2. Scope (in)

1. New file `Sources/App/UI/Transcript/TranscriptBoundary.swift`:
   - `struct TranscriptState: Equatable`
   - `struct TranscriptCallbacks` (NOT `Equatable` — see §4.2)
   - `enum TranscriptEngine: String, CaseIterable { case native, web }`
   - `@ViewBuilder func transcriptView(engine:state:callbacks:) -> some View` — a **free `@ViewBuilder` function** in the `TranscriptBoundary` file (not a `View` extension, not a computed property). Concrete types: `state.messages: [Message]` where `Message` is the existing model type, `state.thinkingState: ThinkingState` (existing type). Both imported from their existing modules; document exact import paths in the code.
2. `FeatureFlags.transcriptEngine: TranscriptEngine` — string-backed, `UserDefaults`-persisted, defaults `.native` (same pattern as `htmlRenderingEnabled`).
3. Wrap the existing stack (`canvasWithMacOS15Chrome` + `MessageCanvas` + chrome) as `NativeTranscriptView` — rename-and-wrap, **zero logic changes** in this step.
4. `MainWindow.swift` (~line 234) calls `transcriptView(...)` instead of `canvasWithMacOS15Chrome(...)`.
5. **The policy move (deliberate, test-backed step — see §4.5):** move `showStreamingBubble` / `showCompletedBridge` policy computations (`MessageCanvas.swift:37–60`) into `TranscriptState` extension methods so both engines consume the same derived `streamingHTML: String?` / `settledBridgeHTML: String?`. This is a *logic move*, not just a rename — its equivalence must be proven by tests (truth table), not assumed.
6. `WebTranscriptView` stubbed to `EmptyView` (web case renders nothing for now).

## 3. Scope (out — explicitly NOT this WP)

- No web transcript implementation (WP-2, WP-3).
- No behaviour changes to the native transcript.
- No FR-MULTICOPY implementation (gated requirement; enforced at G3 + P6, built in WP-2 doc).
- No scroll/whitespace fixes — the v0.9.5g clamp stays as-is (D1 decision: leave current version alone).

## 4. Acceptance criteria (exit gate B1) — observable, not "byte-for-byte"

### 4.1 Behavioural equivalence (replaces "byte-for-byte identical")
On `.native` (default), after the refactor, the app must show:
- **Same rendered topics/messages** in the same order (no change to what's displayed or when).
- **Same streaming → settled transition** (streaming bubble appears, updates, settles — identical timing/visibility to before).
- **Same callbacks fire** (link taps, image taps, load-earlier) with identical results.
- **Same focus behaviour** — composer retains first responder per the same rules as before; no new focus loss or theft.
- **Same test results**: `swift test` whole suite green, run concurrently (E7), no test that passed before now failing, no cherry-picking.

Verification: `swift build && swift test` (use `swift test`, not `xcodebuild test`) + 3-topic manual walk as a smoke test on top (not the sole evidence).

### 4.2 Flag plumbing
- Flag flips **`.native` ↔ `.web`** without crash. `.web` renders `EmptyView` stub — **expected: transcript area goes blank** (this is correct behaviour for the stub; the acceptance is "no crash + clean blank state", NOT "no visual change").
- Verify persistence: set flag to `.web`, relaunch, confirm it persists and still renders the stub without crash. Set back to `.native`, relaunch, transcript returns.
- Default on first launch = `.native`.

### 4.3 Feature-flag test isolation
`FeatureFlags` reads/writes `UserDefaults`. Tests must not be order-dependent on persisted values:
- Inject a scoped `UserDefaults` (suite) in tests, or reset the key in `setUp`/`tearDown`.
- Add a test asserting default value is `.native` on a fresh store, and that round-tripping `.native`/`.web` works.

### 4.4 `TranscriptCallbacks` and equality
- `TranscriptCallbacks` holds closures (`onLoadEarlier`, `onOpenLink`, `onTapImage`) — **not `Equatable`**.
- `TranscriptState` IS `Equatable` (messages, booleans, strings — all value types).
- Document how state/view updates flow: SwiftUI re-evaluates `transcriptView` when `TranscriptState` (Equatable) changes; callbacks are transient view inputs captured at build time and do not drive equality. State this in code comments so future engines don't accidentally try to make callbacks Equatable.

### 4.5 Policy move — proven equivalence (Kieran flag)
- Before the move, **enumerate the exact inputs** of `showStreamingBubble` / `showCompletedBridge` (message count, topic/session state, completion status, bridge eligibility) and write them into the code as a documented contract.
- After the move, add **truth-table unit tests** for the derived `streamingHTML` / `settledBridgeHTML`: for each input combination, assert the derived value matches what the old inline computation produced. Capture the old behaviour first (test against current output), then move, then verify the tests still pass unchanged. This proves algorithmic equivalence.
- If the truth-table grows too large to be a "pure refactor," split this policy move into a **separate micro-WP** after the boundary lands (decision logged, not silently folded).

### 4.6 Rollback
- Revert one commit. If the policy move is included, it must be its own commit so it can be reverted independently of the rename-and-wrap.

## 5. Evidence requirements (E1–E7 binding)

- Exit gate evidence file at `Docs/Reviews/optionb/B1-evidence.md`.
- Operator + verifier differ (E5): Q builds + produces evidence; Q cannot sign B1 alone — Kieran checks, Bee validates, Adam confirms.
- Green suite = `swift test` whole suite concurrently (E7), no cherry-picking.
- E2/E3 less relevant to a pure refactor but: any log line used as evidence must be `.info`+ (E2); any threshold pre-registered before the run (E3).

## 6. Risks

| Risk | Mitigation |
|---|---|
| Rename-and-wrap accidentally changes behaviour | Observable acceptance (§4.1), not "byte-for-byte"; 3-topic walk + full suite |
| Policy move introduces subtle equivalence break | §4.5 truth-table: capture old output first, move, verify unchanged |
| `FeatureFlags` persistence pattern drift / test order-dependence | §4.3 scoped UserDefaults + reset |
| Scope creep into unrelated "improvements" | Surgical-change rule: every line traces to the boundary. Spot dead code → note, don't delete |

## 7. Open items to confirm before dispatch

- Confirm the exact `Message` and `ThinkingState` type locations/imports (Q to verify during spike).
- Confirm `swift test` is the project's canonical test runner (not `xcodebuild test`) — if `xcodebuild` is used anywhere in CI, note the concurrency flag needed for E7.
