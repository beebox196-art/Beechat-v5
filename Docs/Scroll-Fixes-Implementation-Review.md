# Scroll Fixes — Implementation Review

**Author:** Fable review · **Date:** 2026-07-11 · **Scope:** verification of the five prescribed fixes (`afbf0bf` vs `develop-v0.9.5d-whitespace`) against `Docs/Scroll-Baseline-RCA-and-Prescription.md` and `Docs/Scroll-Fixes-Implementation-Brief.md`. Review only — no code changed.

**Verdict up front:** Four of the five fixes are implemented correctly and faithfully — Fix 1, Fix 2's hysteresis, Fix 3a, and Fix 3b need no changes. Two findings need action before this ships: **F1 (functional)** — Fix 3c's monotonic guard has no settle window, so any legitimate height decrease (window widen, font-scale decrease) is rejected forever, turning Bug 3's transient whitespace into *permanent* whitespace inside settled WebView bubbles; the defect originates in the brief's own code snippet, which Bee transcribed faithfully. **F2 (architectural)** — the chrome injects a fresh non-Equatable closure into the environment on every render, which invalidates the entire `MessageCanvas` body on every chrome re-render; one-line fix. One more concern (**F3**) needs a 30-second manual test on macOS 15 before Fix 1 can be called verified there. Everything else is confirmed sound, including the macOS 14 fallback — which actually *gains* the topic-switch fix.

---

## Findings (severity-ordered)

### F1 — Fix 3c's monotonic guard is forever, not "during settle" — **functional, must fix**

**Where:** `Sources/App/Rendering/MessageWebView.swift:162`

```swift
if rounded < current, current > 40 { return } // monotonic during settle
```

The comment says "during settle" but there is no settle window: once a bubble's height exceeds 40pt, **every smaller report is rejected for the lifetime of the binding**. Heights legitimately decrease in two systematic, user-triggered cases:

1. **Window widen.** Text rewraps at greater width → content gets *shorter* → ResizeObserver reports a smaller height → rejected. The bubble keeps its tall frame; the content inside is shorter. Result: permanent whitespace inside the bubble — exactly the Bug-3 symptom this fix exists to remove, made *persistent* instead of transient.
2. **Font-scale decrease.** Same cascade via `setFontScale`.

**Blast radius:** the guard was implemented in the shared `Coordinator` (good centralization — see F6), so it covers all three consumers: settled messages (`MessageContent.swift:51`, `$settledWebViewHeight` persists for the bubble's lifetime — the permanent case), the streaming bubble (transient — replaced when the message settles), and the bridge bubble (transient). It applies on macOS 14 and 15 alike.

**Concrete failure scenario:** open a topic containing a table-heavy `needsWebView` message in a narrow window (bubble settles at, say, 600pt); drag the window wider; content reflows to ~380pt; every subsequent report is rejected; the bubble shows ~220pt of dead whitespace until app restart or the LazyVStack recreates the view.

**Attribution:** Bee implemented the brief's snippet (`Scroll-Fixes-Implementation-Brief.md:247–258`) line-for-line — the guard condition is verbatim from the brief. The brief in turn compressed my RCA's "monotonic growth **during streaming**" (a StreamingBubble-only discipline from commit `16b0130`, where content only grows) into an unconditional guard, despite the RCA's own risk-table warning: *"Coalescing must never drop a final height (coalesce, don't debounce-forever)."* The prescription chain is at fault, not the implementation fidelity. I own the ambiguity: the RCA should have said explicitly that monotonicity is only valid while content monotonically grows.

**Suggested change (minimal, in place):** reject only jitter-band shrinks; accept real reflow:

```swift
// Reject only small shrinks (settle jitter). Large shrinks are real reflow
// (window widen, font-scale decrease) and must be accepted — a lock-forever
// guard turns transient whitespace into permanent whitespace.
if rounded < current, current > 40, current - rounded < 8 { return }
```

8pt ≈ half a line at default scale; ResizeObserver jitter is sub-point, so anything ≥ 2pt would work — 8 gives margin against multi-report settle oscillation. A more precise alternative — have the coordinator compare `webView.frame.width` against the width at last accepted report and skip the monotonic check when width changed — is available if the band ever proves too coarse, but start with the band: it's one condition and covers font-scale too.

### F2 — Environment action is a fresh non-Equatable value per render → whole-canvas invalidation — **architectural/performance, one-line fix**

**Where:** `Sources/App/UI/Components/MessageCanvas.swift:297–307` (injection), `:312–314` (type), `:73` (reader)

`MacOS15ScrollPositionChrome.body` constructs a **new** `MacOS15JumpAction` (a struct wrapping a fresh closure) on every evaluation and writes it into the environment. `MacOS15JumpAction` is not `Equatable`, so SwiftUI cannot prove the value unchanged and must treat every write as a change — invalidating every view that reads `\.macOS15JumpAction`. That reader is `MessageCanvas` itself (line 73), so **every chrome re-render forces a full `MessageCanvas` body evaluation**, including the `ForEach` over all messages.

When does the chrome re-render? (a) Whenever `MainWindow`'s body runs (streaming ticks at ~5fps — mostly masked, because the canvas re-renders then anyway with new content), and (b) whenever the scroll view writes back into the `scrollPosition` binding — `ScrollPosition` bindings are updated by the scroll view as the user scrolls, which on macOS 15 means potentially **per scroll event** during a drag of a long transcript. Case (b) adds canvas body evaluations that would not otherwise happen at all. Magnitude needs an Instruments pass to confirm (see verification matrix), but the fix costs nothing:

**Suggested change:**

```swift
/// Environment key carrying the macOS 15+ Jump-to-Latest action closure.
/// Equatable-as-always-equal: the closure captures a Binding to the chrome's
/// @State storage, which is stable across renders — any instance is
/// interchangeable, so re-injection must not invalidate readers.
struct MacOS15JumpAction: Equatable {
    let perform: () -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}
```

This is safe precisely because of how the chrome is built: the closure captures `$scrollPosition`, and `Binding` is a stable handle to `@State` storage — a "stale" closure from an earlier render still mutates the live storage. (This also answers the lifetime question in the review prompt: no lifetime pitfall, for the same reason.)

### F3 — Stale `ScrollPosition` may defeat Fix 1 on macOS 15 — **functional concern, needs one manual test**

**Where:** `MessageCanvas.swift:284` (chrome `@State`), `:137` (`.id(topicId)`)

On topic switch, `.id(topicId)` tears down and rebuilds the ScrollView — but the chrome and its `@State scrollPosition` sit *outside* the identity boundary and survive. If the user had scrolled up in topic A, the binding holds a user-determined position. Whether a **freshly created** scroll view applies a pre-populated `ScrollPosition` binding at initial layout (overriding `defaultScrollAnchor(.bottom)`'s `initialOffset`) is not documented, and I can't resolve it from the SDK — if it does, Bug 1 is quietly resurrected on macOS 15 only, while testing on macOS 14 (no chrome) would show the fix working.

**Manual test (do this first):** on macOS 15+, scroll well up in a long topic, switch topics → must land at bottom. If it doesn't, that's this.

**Hardening (recommended regardless, makes intent explicit):** pass `topicId` into the chrome and reset the position in the same transaction as the identity swap:

```swift
@available(macOS 15.0, *)
struct MacOS15ScrollPositionChrome<Content: View>: View {
    @State private var scrollPosition = ScrollPosition()
    let topicId: String?
    let content: Content
    // ...
    var body: some View {
        content
            .scrollPosition($scrollPosition)
            // ...
            .onChange(of: topicId) { _, _ in
                scrollPosition = ScrollPosition(edge: .bottom)
            }
    }
}
```

### F4 — Fix 3a's role anchors are shadowed by the inner single-arg anchor — **cosmetic/no-op, document or drop**

**Where:** chrome `MessageCanvas.swift:295–296` (outer) vs `:136` (inner)

`defaultScrollAnchor` configures descendant scroll views; when applied at multiple levels, the modifier **closest to the scroll view wins**. The single-arg `.defaultScrollAnchor(.bottom)` at line 136 sits inside the chrome's wrapping, and on macOS 15 the single-arg form sets the anchor for *all* roles (`initialOffset`, `sizeChanges`, `alignment`). So the chrome's two role-specific modifiers are redundant — shadowed by line 136, which already delivers bottom-anchoring for both roles on macOS 15.

**Net behavior is exactly what Fix 3a intended** — it's just delivered by line 136, not by the chrome. No functional issue (both specify `.bottom`, so any precedence reading converges). My prescription said "**replace** the single-arg anchor (under `#available`)" — the implementation *added* instead of replacing; since the single-arg form must stay for macOS 14 anyway, the honest resolutions are: (a) leave as-is and fix the comment to say the chrome anchors are declarative documentation, or (b) drop the two chrome lines. Either is fine. One thing to still verify at runtime (carried over from my RCA risk table): that `.sizeChanges` bottom-anchoring only pins while *at* the anchor — i.e., a user scrolled up reading history is not yanked down when streaming grows the content.

### F5 — Hysteresis comment is backwards — **cosmetic**

**Where:** `MessageCanvas.swift:67`

> "Leaving is tight (120pt) so a small upward drag keeps the button **visible**"

A 120pt leave threshold means a small upward drag (< 120pt) keeps `isAtBottom == true` and the button **hidden**. The code is right; the comment inverts it. Should read: *"Leaving requires a deliberate scroll (>120pt) so layout settle and small drags don't flash the button."* Same inversion appears in the header doc at line 17. Also `MessageWebView.swift:155` — "Monotonic during settle" — describes the intended behavior, not the implemented one (see F1); fix the comment when fixing F1.

### F6 — Fix 3c placement moved from the brief's target, and it's an improvement — **note, no action**

The brief targeted `MessageContent.swift`'s binding consumer; Bee put the coalescing in the shared `MessageWebView.Coordinator` bcHeight handler (`MessageWebView.swift:151–168`). This is the better location: one implementation covers `MessageContent`, `StreamingBubble`, and `CompletedBridgeBubble` instead of three copies. It also widens F1's blast radius — but F1 exists in the brief's version too. Keep the placement; fix F1 in place.

---

## Answers to the review questions

### Q1 — `.id(topicId)` placement and state reset: **Confirmed**

`MessageCanvas.swift:137`, `:190–196`. Modifier chains wrap bottom-up: written *after* `.defaultScrollAnchor(.bottom)`, the `.id(topicId)` assigns identity to the subtree `ScrollView + .scrollContentBackground + .defaultScrollAnchor` — i.e., the anchor **is** part of the fresh identity as written. That is the correct and tightest arrangement; do not move it. (Placed the other way, the anchor would sit outside the identity boundary but would still govern the new instance — these modifiers configure descendant scroll views and re-apply at the new instance's first layout — so the ordering question is a distinction without a behavioral difference. The current form is the more direct guarantee.)

Placement *inside* `ScrollViewReader` (the prescription said "ScrollViewReader subtree"; Bee put it one level in, on the ScrollView) is fine and arguably better: the proxy, jump-button overlay, geometry observer, and width reader all survive the switch, and the proxy re-resolves IDs against the new subtree. `measuredWidth` survives (the prescription's critical constraint) — confirmed, it's `@State` on `MessageCanvas` (line 63), untouched by the identity swap. The state reset (`isAtBottom = true`, `anchorMessageId = nil`, lines 190–196) matches the prescription exactly and fires in the same update transaction as the rebuild. `topicId` being `String?` is harmless (`Optional` is `Hashable`; nil→non-nil transitions also rebuild, correctly).

One flag carried from F3: the reset is complete for *MessageCanvas's* state, but on macOS 15 there is now a third piece of transient state living in the chrome (`scrollPosition`) that is **not** reset — see F3.

Bonus not in the brief's framing: `.id` + single-arg anchor are macOS 14 APIs, so macOS 14 users get the Bug-1 fix too — as prescribed ("macOS 14-safe. No gates").

### Q2 — Chrome view architecture: **Concern** (F2 + F3; pattern itself is right)

The chrome-view pattern is idiomatic and is exactly what the prescription asked for ("a small `@available(macOS 15)`-gated wrapper subview owning the `ScrollPosition` state"). `@State` can't be `@available`-gated, so a gated wrapper view is the standard resolution; the `#available` branch in `canvasWithMacOS15Chrome` (`MainWindow.swift:976–980`) is stable-identity (`_ConditionalContent` with a runtime-constant condition), so no identity churn there. Applying `.scrollPosition`/anchors on the wrapper (outside `MessageCanvas`'s ZStack) works because these modifiers configure *scroll views within* the modified view, and the canvas contains exactly one ScrollView.

- **Mutation pattern (`MessageCanvas.swift:302–306`): Confirmed.** Copy-mutate-write-back through the binding is correct; there is no more direct way from an escaping closure (calling `scrollPosition.scrollTo` directly would need to mutate captured `self`, which doesn't compile on a struct). It can be one line — `binding.wrappedValue.scrollTo(edge: .bottom)` desugars to the same get/mutate/set — but that's taste, not correctness. Wrapping in `withAnimation` is right and matches the prescription. `isAtBottom` deliberately *not* set in the macOS 15 branch (`MessageCanvas.swift:217–224`) — correct, exactly as prescribed ("the manual write can only race it").
- **Env-key pitfalls: yes, two.** F2 (fresh non-Equatable value per render → canvas-wide invalidation; fix with always-equal `Equatable`) and F3 (surviving `scrollPosition` state vs Fix 1's identity swap; test + reset on topic change). No closure-lifetime pitfall: the captured `Binding` targets stable `@State` storage, so even a stale closure instance acts on live state.

### Q3 — Hysteresis: **Confirmed**

`MessageCanvas.swift:68–69`, `:139–160`.

- **Thresholds:** keep 50/120. These are the exact values the pre-`2c507d5` build shipped and field-tested (RCA §0.1); the prescription restored them deliberately. Against 30/150: a 30pt enter threshold is under two text lines — during streaming, content growth between geometry updates regularly exceeds it, so a user sitting at the bottom can fail to re-latch and be shown a jump button while effectively pinned. That's the flicker class this fix removes. Tune only if manual testing shows flicker at 50/120, and tune the *leave* side first.
- **Cold-start guard returning 0: correct, not a footgun.** During cold start the anchor is about to place the view at the bottom — "at bottom" is the *true* imminent state, and the alternative (returning a large distance) would flash the button during every topic load. The feared scenario ("user believes they're at bottom while content is still arriving") cannot persist: the moment geometry is non-degenerate, the transform emits real distances and hysteresis takes over; and while content is arriving with the user at bottom, the anchor keeps them there — at-bottom is accurate. Note the whole mechanism is macOS 15-only anyway (compat no-ops on 14).
- **Redundant firing: the guards are sufficient, and necessary.** The framework only invokes `action` when the *transformed* value changes (Equatable dedup on `T`), but the value is now a continuous `CGFloat`, so the action runs on essentially every scroll frame. Its body is two comparisons; the inner `if !isAtBottom` / `if isAtBottom` guards ensure `@State` is written only on genuine threshold crossings, so view invalidation happens only when the button actually needs to change. This is the right structure — hysteresis needs the live distance plus current state, which is exactly why the transform was changed from `Bool` to distance (and the generic `<T: Equatable>` widening of the compat shim is clean and source-compatible). Negative distances during overscroll bounce correctly read as "at bottom".

### Q4 — Anchor roles + width churn: **Confirmed**, with F4 noted

- **Role syntax:** separate `.defaultScrollAnchor(_:for:)` calls per role is the correct API — there is no collection/array form. But see F4: both chrome calls are shadowed by the inner single-arg anchor at line 136, which already sets all roles to `.bottom` on macOS 15. Intended behavior is delivered either way; the chrome lines are documentation, not mechanism.
- **1pt width threshold: right.** Sub-point deltas are invisible at any bubble width and are pure FP jitter from live-resize ticks — exactly the churn the RCA identified. Real resize deltas (≥1pt/tick) pass through and *should*: the fix targets jitter, not resizes. The initial `measuredWidth = 1200` default interacts fine (first real preference differs by ≫1pt, or is already equal after rounding).
- **`disablesAnimations` scope:** it disables implicit animation for everything that re-lays *synchronously from that state write* — `measuredWidth` → `canvasWidth` environment → `BubbleWidthModifier` → bubble frames — which is precisely the intent (reflow snaps; tweened intermediate widths are the traveling-gap artifact). It does not touch animations driven by other state (cursor blink `.animation(value: cursorVisible)` etc.). The only way tweening could re-enter is an explicit `.animation(_:value:)` keyed on a width-derived value — grep confirms none exists (`BubbleWidthModifier` and `MessageBubble` have none). **No additional guards needed.**

### Q5 — WebView height coalescing: **Wrong** (one clause — F1); rounding/coalescing/no-animate confirmed

- **0.5pt rounding + 0.5pt delta threshold: right balance.** ResizeObserver jitter is sub-point; real content changes are at minimum a line fragment (≫0.5pt). Nothing meaningful can be dropped by this clause alone, and it kills the highest-frequency write class. Confirmed.
- **40pt floor: right constant, quirky semantics, harmless.** It matches the `@State` initial 40 in all three consumers (`StreamingBubble.swift:18`, `MessageContent.swift:17`, `MessageCanvas.swift:390`). Quirk worth knowing: once a *short* bubble settles below 40 (e.g., 25pt), `current > 40` is false forever, so short bubbles are never monotonic-guarded at all. That's fine — the guard is effectively "only heights that grew past the placeholder" — but it underlines that the guard's semantics are accidental rather than designed.
- **Transient-shrink lock-in: yes, and worse than the question implies.** The question asks about transient style-change shrinks during streaming; those recover as content grows past the locked height, and the streaming bubble is short-lived anyway. The severe case is the *settled* path (`MessageContent`), where the binding lives as long as the bubble and shrinks are systematic, not transient: window widen and font-scale decrease. See F1 for scenario and the suggested band fix (`current - rounded < 8`).

### Q6 — macOS 14 fallback: **Confirmed invisible — actually a net gain — with one shared caveat**

Path-by-path on macOS 14:

- `onScrollGeometryChangeCompat` → `self` (unchanged no-op) → `isAtBottom` stays `true` → button hidden (`opacity 0`, hit-testing off, a11y hidden — `MessageCanvas.swift:244–246`). The `else` proxy branch is unreachable in practice; if ever reached it reproduces the previous behavior exactly. Sound.
- Chrome absent (`MainWindow.swift:976–980` availability branch) → env key nil → no macOS 15 code paths reachable. No 15-only API leaks (build proves the gating compiles; all new 15-only symbols are inside `@available` contexts).
- `.id(topicId)` + single-arg `defaultScrollAnchor(.bottom)`: both macOS 14 APIs. The anchor re-applies at the fresh identity by the same mechanism as on 15 — **macOS 14 users gain the Bug-1 fix**; nothing about the surrounding modifiers changes the anchor's behavior there. This is not a regression; it's the prescription working as designed ("macOS 14-safe. No gates").
- Fix 3b (width rounding) is platform-neutral and strictly reduces layout churn on 14.
- **Caveat:** Fix 3c is also platform-neutral, so **F1 applies to macOS 14 equally**. That is the only 14-visible regression risk in the diff, and it's shared, not fallback-specific.

### Q7 — Pre-`2c507d5` recovery: **Confirmed complete (one omission is deliberate and correct)**

`2c507d5` stripped three things (RCA §0.1): the `onChange(of: topicId)` scroll — recovered structurally and *better* via `.id` (a load, not a scroll; no timing lottery); the 50/120 `isAtBottom` hysteresis — restored verbatim; and the `onChange(of: messages.count)` / streaming manual scrolls — **intentionally not restored**. Those are superseded by `defaultScrollAnchor(.bottom)`'s at-bottom pinning, and re-adding manual scrolls on top of the anchor would reintroduce the fighting/bounce that motivated `2c507d5` in the first place. Likewise `b40e9db`'s deferred-scroll topic treatment stays dead — it was the async lottery the RCA rejected. Nothing else from the pre-rollback state needs re-earning.

### Q8 — Anything missed

1. **F1** is the one genuine defect (brief-originated, faithfully transcribed).
2. **F2/F3** are the two chrome hardenings; both are cheap and should land before manual testing so the tests exercise the final shape.
3. **Fix 3d (VStack experiment)** remains open by design — the brief's decision procedure stands: land 1–3c, then judge Bug 3 visually on a worst-case topic before spending memory on it. F1's fix should land *first*, since locked-tall bubbles would contaminate the visual judgment.
4. **Edge cases checked, all safe:** *Empty topic* — degenerate-geometry guard returns 0, button hidden; single-arg anchor's alignment role bottom-aligns short content, unchanged from before. *Rapid topic switching* — each change is a transactional identity swap; `anchorMessageId` is nilled in the same `onChange`; no async work in flight to race (that's the point of the identity fix). F3 is the one rapid-switch-adjacent risk (stale chrome position). *Streaming + topic switch* — the streaming bubble sits inside the `.id` boundary, so its `webViewHeight` `@State` is rebuilt fresh (back to 40) with the new topic; props flow from the new topic's view model. Clean.
5. **Nothing has been observed at runtime.** Build-clean is the only verification so far (test runner hang is pre-existing). Priority manual matrix for when Adam is back:
   1. **macOS 15: scroll up in topic A, switch to topic B** → must land at bottom (F3 — decides whether the chrome needs the topic reset urgently or just as hygiene).
   2. **Table-heavy WebView message; widen window** → whitespace inside bubble must clear (F1 — will fail as written; re-run after fix).
   3. **Jump button during active streaming with a settling table** → one click, lands at true bottom, button hides itself via geometry (not via manual write).
   4. **Streaming at bottom** → no button flicker (hysteresis), no scroll creep.
   5. **Live resize, drag continuously** → gaps transient at reading edge, reflow snaps (no tweening).
   6. **Instruments (SwiftUI View Body counter): drag-scroll a 200+ message topic on macOS 15** → `MessageCanvas.body` should not fire per scroll event (F2 — re-check after the `Equatable` fix).
6. Housekeeping: the RCA, the brief, and now this review are untracked (`git status`); commit decision remains Adam's, but the review cycle's provenance is currently one `rm -rf` away.

---

## Fidelity summary

| Fix | Prescribed | Implemented | Verdict |
|---|---|---|---|
| 1 — `.id(topicId)` + reset | `.id` on reader subtree, reset `isAtBottom`/`anchorMessageId` | `MessageCanvas.swift:137`, `:190–196` — on the ScrollView, inside the reader | ✅ Confirmed (F3 to verify on 15) |
| 2 — edge jump | gated wrapper owning `ScrollPosition`; no manual `isAtBottom` write | chrome + env action, `MessageCanvas.swift:283–309`, `:217–224` | ✅ pattern; ⚠️ F2 (Equatable), F3 (topic reset) |
| 2 — hysteresis | enter <50 / leave >120 | `:68–69`, `:151–159` | ✅ Confirmed (comment F5) |
| 3a — anchor roles | replace single-arg under `#available` | added in chrome, single-arg retained inside | ✅ behavior delivered; F4 redundancy |
| 3b — width rounding | round, ≥1pt, no-animate | `:167–179` | ✅ Confirmed |
| 3c — height coalescing | coalesce ≥0.5pt, no-animate, monotonic-while-growing; *never drop a final height* | `MessageWebView.swift:151–168`, shared coordinator | ❌ F1 — monotonic-forever drops final heights; band fix suggested |
