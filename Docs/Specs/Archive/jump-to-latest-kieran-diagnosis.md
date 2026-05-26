# Kieran's Independent Diagnosis: Jump-to-Latest Scroll Detection

**Date:** 2026-05-08  
**Reviewer:** Kieran (independent safety review)  
**Commits reviewed:** `4e29e8a` (Q's original) → `7647a23` (Bee's attempted fix)

---

## 1. Was Bee's Fix Safe? — New Bugs & Regressions

### WidthReader removal: ✅ Safe

`WidthReader` was a private struct, used only once in `MessageCanvas.swift` to measure the scroll view's width and emit a `WidthPreferenceKey`. Bee replaced it with an inline `GeometryReader { geo in ... }` that emits both `WidthPreferenceKey` and `VisibleHeightPreferenceKey`. I confirmed:

- `WidthReader` is **not referenced anywhere else** in the codebase (grep returned zero hits).
- The replacement GeometryReader reads `geo.size.width` — identical semantics to what `WidthReader` provided.
- `canvasWidth` is still set via `.environment(\.canvasWidth, measuredWidth)` and consumed by `MessageBubble`. No regression here.

**Verdict:** No regression from WidthReader removal.

### VisibleHeightPreferenceKey implementation: ⚠️ Probably correct, but may not fire as expected

The implementation is standard `PreferenceKey` boilerplate. The key reads `geo.size.height` from a `GeometryReader` placed in the `.background()` of the `ScrollView`. In principle, this should give the visible viewport height.

**Concern:** On macOS (AppKit-backed), `GeometryReader` in a `ScrollView.background()` may not reliably report the *visible* height — it may report the *content* height or zero, depending on when layout resolves. SwiftUI's coordinate space behavior in scroll views is notoriously unreliable, especially with `LazyVStack`. The `visibleHeight` value may be stale or zero when `BottomAnchorPreferenceKey` fires, since preference changes are batched and may not arrive in a deterministic order.

If `visibleHeight` is 0 (its `defaultValue`) when the first `BottomAnchorPreferenceKey` update fires, then `distanceBelowVisible = bottomY - 0 = bottomY` — which collapses back to Q's original broken logic. This would explain why "Adam reports no change in behaviour."

**Verdict:** Implementation is syntactically correct but likely fails at runtime due to initialization timing or GeometryReader-in-ScrollView measurement issues on macOS.

### Coordinate space math: ❌ Conceptually wrong

The comment in Bee's fix says:

```
// When at bottom: bottomY ≈ visibleHeight (anchor visible near bottom edge)
// When scrolled up: bottomY > visibleHeight (anchor is below visible area)
```

This is **incorrect** for SwiftUI's coordinate system.

In a `ScrollView` with `.coordinateSpace(name: "messageScrollView")`, the coordinate space origin is at the **top-left of the scroll view's content area**, and Y increases downward. The `bottom-anchor`'s `minY` in this coordinate space represents its **absolute position from the top of the total content**, NOT its position relative to the visible viewport.

- When the user is at the bottom of a long conversation, `bottomY` could be 15,000 (the anchor is 15,000 points from the top of the content).
- The visible height might be 800.
- `distanceBelowVisible = 15000 - 800 = 14,200` → `isAtBottom = false` → button shows. **Wrong.**

The fundamental error: **`bottomY` is an absolute content-space coordinate, not a viewport-relative distance.** Subtracting `visibleHeight` doesn't convert it to a distance-from-visible-bottom.

**What actually works:** You need the anchor's position **relative to the visible viewport**. The correct computation is:

```
distanceFromVisibleBottom = bottomY - currentScrollOffset
```

But SwiftUI doesn't expose `currentScrollOffset` directly. That's the core problem Q's original implementation also faced — it compared `bottomY` against fixed pixel thresholds, which only works when content is short enough that `bottomY < 120`.

**Verdict:** The math is wrong. `bottomY - visibleHeight` does not compute what the comment claims it computes.

---

## 2. Should We Revert to Q's Original Implementation?

**Yes — revert to `4e29e8a` before any further debugging.**

Rationale:
- Q's implementation has the **confirmed working** topic-switch fix.
- Bee's fix introduced no regressions *to other features* (WidthReader removal is safe, no other code changed), but it **also didn't fix the bug**.
- Bee's code adds complexity (`VisibleHeightPreferenceKey`, `visibleHeight` state, altered math) that is incorrect and makes debugging harder.
- Reverting gives Q a clean base to work from. The topic-switch fix is in `4e29e8a`, so reverting preserves it.

**Action:** `git revert 7647a23` on `develop`, or hard-reset `MessageCanvas.swift` to the state at `4e29e8a`.

---

## 3. Correct Approach for Scroll Position Detection on macOS 14

### Why this is hard

SwiftUI's `ScrollView` deliberately hides scroll offset. There is no `scrollOffset` binding. The `PreferenceKey` + `GeometryReader` approach can measure where specific views are in a named coordinate space, but converting that to "is the user at the bottom?" requires knowing the scroll offset, which SwiftUI won't give you.

### Option A: `scrollPosition(id:)` binding (macOS 14+) — ⭐ Recommended

macOS 14 / iOS 17 introduced `scrollPosition(id:)` which binds the ID of the view at the top (or bottom) of the visible area. Combined with an `onChange(of:)` on the bound ID, you can determine whether the last message is visible.

```swift
@State private var scrollPosition = ScrollPosition(edge: .bottom)

ScrollView(.vertical) {
    LazyVStack { ... }
}
.scrollPosition($scrollPosition)
.onChange(of: scrollPosition) { ... }
```

This is the **simplest, most SwiftUI-native** approach. It avoids all coordinate-space math.

**Caveat:** `ScrollPosition` API is still evolving; verify it works correctly with `LazyVStack` and `ScrollViewReader` together on macOS 14. There were early bugs where `scrollPosition` and `ScrollViewReader` conflicted.

### Option B: Bottom-anchor `onAppear`/`onDisappear` — Simple but coarse

Place an `onAppear`/`onDisappear` on the bottom-anchor view:

```swift
Color.clear.frame(height: 1).id("bottom-anchor")
    .onAppear { isAtBottom = true }
    .onDisappear { isAtBottom = false }
```

**Pros:** No coordinate math, no PreferenceKeys, works reliably.
**Cons:** `LazyVStack` may recycle the bottom anchor aggressively — `onDisappear` may fire even when the anchor is only just outside the viewport (1px away). This causes button flicker. The hysteresis approach can't be applied here.

**Verdict:** Good as a fallback if Option A doesn't work, but needs debouncing/minimum-visible-time logic to avoid flicker.

### Option C: AppKit bridge via `NSScrollView` — Powerful but complex

Wrap an `NSScrollView` via `NSViewRepresentable` to get direct `contentOffset` access. This gives precise, reliable scroll position data.

**Pros:** Complete control, battle-tested, no SwiftUI quirks.
**Cons:** Significant implementation effort, breaks SwiftUI idioms, harder to maintain, may conflict with `ScrollViewReader`.

**Verdict:** Overkill. Only consider if Options A and B both fail.

### Option D: Fixed-threshold on `bottomY` with content-height tracking — What Q tried

This is what Q implemented and what Bee tried to fix. The approach requires knowing both the content height and the visible height to compute a meaningful threshold. It's fundamentally fragile because:

1. Content height changes as `LazyVStack` loads/unloads views.
2. The `bottomY` value jumps around as content is recycled.
3. The threshold values (50, 120) are magic numbers that depend on viewport size.

**Verdict:** This approach is a dead end for long conversations. Don't invest more time in it.

---

## 4. Process Concerns

### 🔴 Bee committed and shipped a fix without team review

The issue report itself acknowledges this. Per AGENTS.md:
- **Standard tier** changes (multi-file, new component) require: success criteria → spec → build → tech validation → commit.
- **Bee is coordinator** — the default operating loop says "route, not execute" for anything beyond simple/local/reversible changes.

Bee's fix was:
- Not simple (touched coordinate math, added new state/preference key, removed a struct)
- Not reviewed by Q (the specialist)
- Not validated at runtime (Adam reported no change)
- Committed directly to `develop` without a PR or review

This is a **process violation** that could have introduced regressions (it didn't, but only by luck — the WidthReader removal was safe, and the new code is functionally a no-op since `visibleHeight` likely stays at 0).

### 🟡 The issue was already documented before the fix

Bee wrote a thorough issue report *and then immediately tried to fix it anyway*. The issue report specifically asks for Q's runtime debugging help — that help was never obtained before the fix was attempted.

### 🟡 Self-imposed "no further changes" constraint came after the damage

The "No further code changes by Bee" constraint in the issue report was written *after* Bee already committed the broken fix. The constraint is correct, but it's closing the barn door after the horse has bolted.

### ✅ Bee was transparent about the failure

The issue report honestly documents what Bee did, why it didn't work, and what needs to happen next. This is good process — the transparency just came too late.

---

## Summary & Recommendation

| Question | Answer |
|---|---|
| Was Bee's fix safe? | No regressions to other features (WidthReader removal safe), but the fix itself is **wrong** — coordinate math is incorrect, `visibleHeight` may be stale/zero, and the logic collapses to the same broken behavior. |
| New bugs introduced? | No functional regressions, but dead/incorrect code added (`visibleHeight`, `VisibleHeightPreferenceKey`, wrong math). |
| Revert to Q's original? | **Yes.** Revert `7647a23`. Q's code has the working topic-switch fix and no more broken than Bee's version. |
| Correct approach? | **`scrollPosition(id:)` binding (macOS 14+)**, with `onAppear`/`onDisappear` as fallback. Abandon the `bottomY`-threshold approach entirely. |
| Process concerns? | **Critical:** Bee shipped a fix without review, violating coordinator-first routing and Standard-tier validation. The fix was a no-op that could have been a regression. |

### Recommended next steps

1. **Revert** `7647a23` on `develop`. This restores Q's `4e29e8a` state (topic-switch fix intact, scroll detection still broken).
2. **Q implements** scroll detection using `scrollPosition(id:)` binding. Test on macOS 14 with both short and long conversations.
3. **If `scrollPosition` has issues** with `LazyVStack` + `ScrollViewReader` interaction, fall back to the `onAppear`/`onDisappear` approach with debouncing.
4. **Process:** All future scroll detection changes go through Q. Bee routes, doesn't implement.
5. **Runtime validation:** Q must test with the actual app, not just compile. Adam should see a working build before we call it done.