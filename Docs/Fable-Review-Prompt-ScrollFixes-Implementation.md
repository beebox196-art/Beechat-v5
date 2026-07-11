# Fable Review Prompt: BeeChat Message Window Scroll — Implementation Review

**Date:** 2026-07-11
**Author:** Bee
**Branch:** `feature/scroll-fixes-v0.9.5e` (from `develop-v0.9.5d-whitespace`)
**Purpose:** Have an expert SwiftUI reviewer verify that the implementation of the scroll fixes matches the prescription from `Docs/Scroll-Baseline-RCA-and-Prescription.md` and `Docs/Scroll-Fixes-Implementation-Brief.md`, and confirm that nothing has been missed or done wrong.

---

## Context

We previously commissioned you (Fable) to diagnose three scroll/anchor bugs in BeeChat's message canvas and prescribe fixes (`Docs/Scroll-Baseline-RCA-and-Prescription.md`). Your prescription included five fixes to be applied in landing order:

1. **Fix 1** — Topic switch: add `.id(topicId)` to the inner ScrollView so `defaultScrollAnchor(.bottom)` fires as a genuine initial layout per topic, and reset transient state in `onChange(of: topicId)`.
2. **Fix 2** — Jump to Latest: use `ScrollPosition.scrollTo(edge: .bottom)` (macOS 15+) instead of `ScrollViewProxy.scrollTo(view:anchor:)`. Add 50pt/120pt hysteresis around `isAtBottom`.
3. **Fix 3a** — Anchor roles (macOS 15+): `defaultScrollAnchor(.bottom, for: .initialOffset)` and `defaultScrollAnchor(.bottom, for: .sizeChanges)`.
4. **Fix 3b** — Width churn: round `measuredWidth` to whole points, ignore sub-point deltas, snap with `disablesAnimations` instead of tweening.
5. **Fix 3c** — WebView height coalescing: round bcHeight reports to nearest 0.5pt, ignore sub-point deltas, enforce monotonic during settle, snap with `disablesAnimations`.

Bee has implemented all five fixes. **No Fable review yet.** We need you to:
- **Verify each fix is implemented correctly** and faithfully matches your prescription.
- **Check for unintended side effects** that the brief did not anticipate.
- **Identify gaps** — anything in your RCA that has not been addressed.
- **Confirm the macOS 14 fallback** is sound (no regressions, no missed gates).
- **Assess the platform-gating architecture** (new `MacOS15ScrollPositionChrome` wrapper view, `MacOS15JumpAction` environment key) for correctness and idiomaticity.

---

## Files to Review

| File | Purpose | Lines changed |
|---|---|---|
| `Sources/App/UI/Components/MessageCanvas.swift` | Main canvas + scroll geometry compat helpers | ~85 LOC added |
| `Sources/App/UI/MainWindow.swift` | Wires `MessageCanvas` through `canvasWithMacOS15Chrome` | ~30 LOC added |
| `Sources/App/Rendering/MessageWebView.swift` | bcHeight coalescing (Fix 3c) | ~15 LOC added |

A diff vs `develop-v0.9.5d-whitespace` is at the bottom of this document.

---

## Review Questions

### Q1: Fix 1 — `.id(topicId)` placement and state reset

The brief specified `.id(topicId)` on the ScrollView (not on `MessageCanvas`) so `@State` survives and only the scroll view rebuilds. Implementation:

```swift
ScrollView(.vertical, showsIndicators: true) { ... }
.scrollContentBackground(.hidden)
.defaultScrollAnchor(.bottom)
.id(topicId)                           // ← placed here
.scrollBounceBehaviorCompat(axes: .vertical)
.onScrollGeometryChangeCompat(...)
```

And:

```swift
.onChange(of: topicId) { _, _ in
    isAtBottom = true
    anchorMessageId = nil
}
```

**Question:** Is the placement of `.id(topicId)` correct? Does putting it AFTER `.defaultScrollAnchor(.bottom)` matter for the timing of when the anchor re-applies? Should it be BEFORE the anchor instead, so the anchor is part of the fresh identity?

### Q2: Fix 2 — `ScrollPosition` chrome view architecture

Because `ScrollPosition` is a macOS 15+ type and `@State` properties cannot be marked `@available`, the implementation introduces a separate chrome view:

```swift
@available(macOS 15.0, *)
struct MacOS15ScrollPositionChrome<Content: View>: View {
    @State private var scrollPosition = ScrollPosition()
    // applies .scrollPosition($scrollPosition),
    //        .defaultScrollAnchor(.bottom, for: .initialOffset),
    //        .defaultScrollAnchor(.bottom, for: .sizeChanges),
    // and injects MacOS15JumpAction into the environment.
}
```

The Jump button inside `MessageCanvas` reads `\.macOS15JumpAction` from the environment. If the chrome is absent (macOS 14 build), the env value is nil and the button falls back to `ScrollViewProxy.scrollTo(...)`.

**Questions:**
- Is this chrome-view pattern idiomatic, or is there a simpler/cleaner SwiftUI pattern we should be using?
- Is the `ScrollPosition.scrollTo(edge:)` mutation pattern correct? (We mutate a local copy and write back through the binding — is there a more direct way?)
- Does the `MacOS15JumpAction` env key have any pitfalls (e.g., lifetime issues if the chrome re-renders)?

### Q3: Fix 2 — Hysteresis

The brief specified enter at < 50pt, leave at > 120pt. Implementation:

```swift
.onScrollGeometryChangeCompat(
    transform: { geo in
        guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
            return CGFloat(0)
        }
        return geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
    },
    action: { _, distanceFromBottom in
        if distanceFromBottom < enterBottomThreshold {
            if !isAtBottom { isAtBottom = true }
        } else if distanceFromBottom > leaveBottomThreshold {
            if isAtBottom { isAtBottom = false }
        }
    }
)
```

The guard returns `0` (i.e., "at bottom") when content/container is uninitialised, so the jump button stays hidden during cold start.

**Questions:**
- Are 50pt enter / 120pt leave the right hysteresis band for this UX? Should we adjust (e.g., 30/150 for more permissive behaviour)?
- The guard returns `0` to keep the button hidden during cold start — is this a footgun if the canvas renders before content loads, causing the user to think they've reached the bottom when in fact content is still arriving?
- Is there a risk that `onScrollGeometryChangeCompat` fires repeatedly with the same `distanceFromBottom` value, triggering redundant state writes? The inner `if !isAtBottom { isAtBottom = true }` guard prevents re-writing, but is that sufficient?

### Q4: Fix 3a + 3b — Anchor roles and width churn

Fix 3a applies both anchor roles inside the chrome view on macOS 15+:

```swift
.defaultScrollAnchor(.bottom, for: .initialOffset)
.defaultScrollAnchor(.bottom, for: .sizeChanges)
```

Fix 3b modifies `onPreferenceChange`:

```swift
.onPreferenceChange(WidthPreferenceKey.self) { newWidth in
    let rounded = round(newWidth)
    if abs(rounded - measuredWidth) >= 1 {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            measuredWidth = rounded
        }
    }
}
```

**Questions:**
- Are both anchor roles correctly specified? The brief showed them as separate `.defaultScrollAnchor(...)` calls — is that the right SwiftUI syntax (vs `.defaultScrollAnchor([.initialOffset, .sizeChanges], .bottom)` or similar)?
- The width threshold of 1pt for "real change" — is this too tight, too loose, or just right?
- `Transaction.disablesAnimations = true` — does this also disable the implicit animation that downstream `measuredWidth` consumers see (e.g., bubble width calculation)? If so, do we need any additional guards?

### Q5: Fix 3c — WebView height coalescing

In `MessageWebView.swift`, the bcHeight handler now coalesces:

```swift
let rounded = (h * 2).rounded() / 2  // round to nearest 0.5pt
Task { @MainActor [parent] in
    let current = parent.height
    if abs(rounded - current) < 0.5 { return }
    if rounded < current, current > 40 { return } // monotonic during settle
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
        parent.height = CGFloat(rounded)
    }
}
```

**Questions:**
- Is the 0.5pt rounding + 0.5pt delta threshold the right balance? Too tight means lots of writes; too loose means stale heights.
- The monotonic guard (`rounded < current && current > 40`) — is 40pt the right minimum settled height? The `@State` initialiser sets `40` as the minimum, so we want to allow the first ~40pt of growth freely and only enforce monotonic after that.
- Is there a risk that during streaming, the WebView reports a smaller height transiently (e.g., due to a style change that briefly reduces content), and the monotonic guard locks in the wrong height?

### Q6: macOS 14 fallback

On macOS 14:
- The chrome view is absent (no `.scrollPosition`, no anchor roles).
- The single-arg `.defaultScrollAnchor(.bottom)` already in place handles initial positioning.
- `onScrollGeometryChangeCompat` is a no-op, so `isAtBottom` stays true and the Jump button is hidden.
- The Jump button action's `else` branch (`proxy.scrollTo(...)`) is unreachable in practice because the button is hidden.

**Question:** Is the macOS 14 fallback truly invisible? Specifically:
- Could a macOS 14 user see ANY scroll regression vs. the previous behaviour?
- Are there any macOS 14 paths where `defaultScrollAnchor(.bottom)` would now behave differently because of the surrounding `.id(topicId)` modifier?

### Q7: Regression risk vs commit 2c507d5

Your RCA noted that commit `2c507d5` stripped working hysteresis and topic-scroll handling. We restored hysteresis (Fix 2) and added the `.id(topicId)` topic reset (Fix 1). Is there anything else from the pre-2c507d5 behaviour that we have not recovered?

### Q8: Anything we missed?

Looking at the original RCA + prescription, is there:
- A bug or fix that we overlooked?
- An edge case the brief did not anticipate (e.g., empty topics, race conditions during rapid topic switching, streaming + topic switch)?
- A better implementation pattern we should adopt?

---

## What We Want From You

For each numbered question above:
- **Verdict:** Confirmed / Concern / Wrong, with one-line rationale.
- **Evidence:** Cite the file and line. If you're flagging a concern, explain the failure mode concretely.
- **Suggested change (if any):** Specific code-level change, not vague guidance.

If you find nothing wrong, say so explicitly — we want confidence, not just absence of alarm.

---

## Diff Summary (vs `develop-v0.9.5d-whitespace`)

```
Sources/App/Rendering/MessageWebView.swift    |  20 +++-
Sources/App/UI/Components/MessageCanvas.swift | 159 ++++++++++++++++++++++----
Sources/App/UI/MainWindow.swift               |  36 +++++-
3 files changed, 190 insertions(+), 25 deletions(-)
```

The full diff is available via `git diff develop-v0.9.5d-whitespace` in `/Users/openclaw/Projects/BeeChat-v5`.

---

## Build Status

- `swift build` (debug): ✅ compiles clean
- `swift build --target BeeChatAppTests`: ✅ compiles clean
- `swift test`: test runner hangs in this environment (unrelated to these changes — pre-existing)
- Manual UI testing: pending (Adam returns from golf)

---

## Constraints

- **No code changes.** We want review only — same protocol as the original RCA prompt.
- **Be specific.** Cite line numbers, name APIs, quote code.
- **Be honest.** If the implementation is sound, say so. If something is wrong or fragile, flag it with severity (cosmetic / functional / architectural).
- **Stay within scope.** The five fixes in the brief are what we implemented. If you spot an unrelated improvement, mention it but don't make it the headline.
