# BeeChat Message Window Scroll — Implementation Brief

**Source:** Fable RCA & Prescription (`Docs/Scroll-Baseline-RCA-and-Prescription.md`)
**Target:** Q (implementation), Kieran (review)
**Branch:** Feature branch from `develop-v0.9.5d-whitespace`
**Constraint:** No diversion from Agent drop work. This brief is ready when Q is.

---

## Overview

Three scroll bugs, all solvable on ScrollView+LazyVStack. No List, no AppKit, no architecture change. Fixes land in order — each independently shippable and testable.

**Root cause summary:**
- Bug 1: `defaultScrollAnchor(.bottom)` fires per view identity, not per content swap. Topic switch reuses the same scroll view instance, so the old offset carries over.
- Bug 2: `scrollTo` computes a fixed offset from current (stale) layout — LazyVStack estimated heights plus async WebView height settlements mean the animation target is wrong by the time it finishes.
- Bug 3: Window resize triggers two-pass reflow per resize tick (including sub-pixel deltas), while off-screen lazy estimates and async WebView heights make content size thrash.

---

## Fix 1 — Topic switch: change identity, don't chase timing

**File:** `MessageCanvas.swift` only
**macOS:** 14+ (no gates needed)

### What to do

1. Add `.id(topicId)` to the `ScrollView` (inside `ScrollViewReader`, after the `ScrollView(` declaration):

```swift
ScrollView(.vertical, showsIndicators: true) {
    LazyVStack(spacing: 0) { ... }
}
.id(topicId)                           // ← add this
.scrollContentBackground(.hidden)
.defaultScrollAnchor(.bottom)
```

**Why inside, not at the call site:** Putting `.id()` on the whole `MessageCanvas` would destroy `@State` vars like `measuredWidth` (reset to 1200 → bubble width flash). On the `ScrollView` inside `ScrollViewReader`, the `@State` lives on `MessageCanvas` and survives the identity change. Only the scroll view rebuilds — which is exactly what we want.

2. In `onChange(of: topicId)`, reset state:

```swift
.onChange(of: topicId) { _, _ in
    isAtBottom = true
    anchorMessageId = nil
}
```

The `defaultScrollAnchor(.bottom)` will fire as a genuine initial layout on the fresh scroll view. No async dispatch, no timing races.

3. Remove the comment that says "defaultScrollAnchor handles it" — it was a false premise.

### What this fixes
- Topic switch now scrolls to bottom instantly, every time, zero races.
- Also reduces frequency of Bugs 2 and 3 (every switch starts from clean bottom).

### Risk
- Per-topic scroll memory is lost (desired — chat should start at bottom).
- Lazy caches discarded per switch: one extra materialization pass, imperceptible.

---

## Fix 2 — Jump to Latest: target the edge, not a view

**File:** `MessageCanvas.swift` only
**macOS:** 15+ gated (14 doesn't show the button anyway — `onScrollGeometryChangeCompat` no-ops there)

### What to do

1. Add a `@State` for the `ScrollPosition` struct (macOS 15+):

```swift
// Inside MessageCanvas, alongside existing @State vars:
@State private var scrollPosition = ScrollPosition()
```

2. Attach `.scrollPosition($scrollPosition)` to the `ScrollView`, inside the `#available` gate alongside the anchor roles (Fix 3a will use this same gate):

```swift
ScrollView(.vertical, showsIndicators: true) { ... }
.id(topicId)
.scrollContentBackground(.hidden)
.defaultScrollAnchor(.bottom)          // macOS 14 fallback
.scrollBounceBehaviorCompat(axes: .vertical)
.onScrollGeometryChangeCompat(...)
.background(WidthReader { ... })
.onPreferenceChange(WidthPreferenceKey.self) { newWidth in
    measuredWidth = newWidth
}
.onChange(of: anchorMessageId) { ... }
.onChange(of: topicId) { ... }
.overlay(alignment: .bottomTrailing) {
    jumpToLatestButton(proxy: proxy)
}
```

For macOS 15+, wrap the relevant modifiers in an `#available` block. The full gate structure will look like:

```swift
if #available(macOS 15.0, *) {
    scrollView
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)  // Fix 3a
        .defaultScrollAnchor(.bottom, for: .sizeChanges)      // Fix 3a
} else {
    scrollView
        .defaultScrollAnchor(.bottom)  // macOS 14: single-arg, already works for initial
}
```

3. Replace the jump button action. Currently:

```swift
Button(action: {
    withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
    isAtBottom = true  // ← remove this manual write
})
```

New action (macOS 15+ path):

```swift
Button(action: {
    withAnimation(.easeInOut(duration: 0.2)) {
        scrollPosition.scrollTo(edge: .bottom)
    }
    // Don't manually set isAtBottom — onScrollGeometryChange will set it truthfully
})
```

4. **Keep `ScrollViewReader` for load-earlier only.** Do NOT add `scrollPosition(id:)`. One programmatic controller per scroll view.

5. **Restore the hysteresis** lost in commit `2c507d5`. Replace the flat 80px threshold:

```swift
// Current (broken):
let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
return distanceFromBottom < 80

// Fixed — with hysteresis:
// (Use the onScrollGeometryChange transform to track enter/leave separately)
```

Since `onScrollGeometryChange` only gives us the computed value (not old vs new in a way that lets us gate on direction), implement hysteresis as:

```swift
@State private var isAtBottom: Bool = true

// In the action closure:
let newValue = /* computed from geometry */
if newValue && !isAtBottom {
    // Entering bottom zone — generous threshold
    isAtBottom = true
} else if !newValue && isAtBottom {
    // Leaving bottom zone — tight threshold
    isAtBottom = false
}
```

With two thresholds: enter at < 50px from bottom, leave at > 120px from bottom. This prevents flicker during streaming/layout settle.

### What this fixes
- One click lands at true bottom, even mid-WebView-settle.
- Button doesn't flicker during streaming.
- macOS 14 is unaffected (button already hidden there).

### Risk
- Coexistence: don't add `scrollPosition(id:)` alongside — one controller per scroll view.
- Verify animation style of `scrollPosition.scrollTo(edge:)` on macOS 26 Tahoe and 15.

---

## Fix 3a — Anchor roles (macOS 15+)

**File:** `MessageCanvas.swift` only
**macOS:** 15+ gated (14 uses single-arg anchor, which already approximates this when at-anchor)

### What to do

In the `#available(macOS 15.0, *)` block (shared with Fix 2), replace the single-arg `defaultScrollAnchor(.bottom)` with:

```swift
.defaultScrollAnchor(.bottom, for: .initialOffset)
.defaultScrollAnchor(.bottom, for: .sizeChanges)
```

This tells SwiftUI: when content size changes while the user is at the bottom, pin the reading edge so settling happens above the viewport (invisible) instead of pushing white space below.

### What this fixes
- Resize and font-scale changes no longer produce visible white-space gaps at the bottom.
- Streaming height increases settle above the viewport.

---

## Fix 3b — Kill width churn

**File:** `MessageCanvas.swift` only
**macOS:** All (no gates)

### What to do

In `onPreferenceChange(WidthPreferenceKey.self)`:

```swift
// Current:
.onPreferenceChange(WidthPreferenceKey.self) { newWidth in
    measuredWidth = newWidth
}

// Fixed:
.onPreferenceChange(WidthPreferenceKey.self) { newWidth in
    let rounded = round(newWidth)  // whole points only
    if abs(rounded - measuredWidth) >= 1 {  // real change only
        var transaction = Transaction()
        transaction.disablesAnimations = true  // reflow should snap, not tween
        withTransaction(transaction) {
            measuredWidth = rounded
        }
    }
}
```

### What this fixes
- Sub-pixel FP deltas no longer re-lay every bubble per resize tick.
- Reflow snaps instead of animating through intermediate heights (which are visible as traveling gaps).

---

## Fix 3c — Calm WebView height writes

**File:** `MessageContent.swift` (outside MessageCanvas — flagged, but it's height plumbing, not bubble-width logic)
**macOS:** All (no gates)

### What to do

The `$settledWebViewHeight` binding in `MessageContent` receives writes from `ResizeObserver` via the `bcHeight` message bridge. Currently every JS height report triggers a layout pass. Apply the same discipline commit `16b0130` gave `StreamingBubble`:

1. **Coalesce:** ignore sub-point deltas (height changes < 0.5pt).
2. **No animation:** height writes should snap, not animate.
3. **Monotonic during settle:** once a WebView has reported its final height, don't accept smaller values (prevent layout thrash from rounding jitter).

Implementation pattern:

```swift
// In the height callback (wherever bcHeight messages arrive):
let newHeight = round(reportedHeight * 2) / 2  // round to nearest 0.5pt
guard abs(newHeight - settledWebViewHeight) >= 0.5 else { return }
if newHeight < settledWebViewHeight && settledWebViewHeight > 40 { return }  // monotonic during settle

var transaction = Transaction()
transaction.disablesAnimations = true
withTransaction(transaction) {
    settledWebViewHeight = newHeight
}
```

### What this fixes
- Halves (roughly) the number of layout events under the anchored scroll view during resize and streaming.
- Each eliminated layout event is one fewer opportunity for visible white-space.

---

## Fix 3d — Optional VStack experiment

**File:** `MessageCanvas.swift` (one word change)
**macOS:** All

**Not prescribed — measure first.** Swap `LazyVStack(spacing: 0)` → `VStack(spacing: 0)`. With load-earlier pagination bounding the page, a non-lazy stack has zero estimated extents — eliminating Bugs 2's estimation term and Bug 3's stale-estimate gaps entirely. The cost is every `needsWebView` bubble holds a live WKWebView simultaneously.

**Decision procedure:** After landing Fixes 1–3c, measure a worst-case topic (50+ messages, several tables). If Bug 3 is still visually distracting, try 3d with Activity Monitor watching WKWebView process count and memory. Typical chat pages with 0–2 WebView bubbles should be fine. Heavy-table topics are the test case.

---

## Landing Order

1. **Fix 1** — `.id(topicId)` + state reset → test topic switching
2. **Fix 2** — `ScrollPosition` edge jump + hysteresis → test jump button
3. **Fix 3a** — anchor roles → test resize while at bottom
4. **Fix 3b** — width rounding → test resize/drag
5. **Fix 3c** — WebView height coalescing → test table-heavy messages during streaming
6. **Fix 3d** — measure, then decide

Each step is independently shippable. Fix 1 also reduces the frequency of 2 and 3.

---

## Files Touched

| Fix | File | Scope |
|---|---|---|
| 1 | `MessageCanvas.swift` | `.id(topicId)` placement + `onChange` state reset |
| 2 | `MessageCanvas.swift` | `@State scrollPosition`, `#available` gate, jump button rewrite, hysteresis |
| 3a | `MessageCanvas.swift` | `defaultScrollAnchor` role variants inside `#available` gate |
| 3b | `MessageCanvas.swift` | `onPreferenceChange` rounding + transaction |
| 3c | `MessageContent.swift` | `settledWebViewHeight` coalescing |
| 3d | `MessageCanvas.swift` | `LazyVStack` → `VStack` |

Nothing touches `MessageBubble.swift` or `BubbleWidthModifier`.

---

## Verification Checklist

After each fix:

- [ ] Topic switch scrolls to bottom (all topics, including empty, long, and table-heavy)
- [ ] Jump to Latest reaches true bottom in one click
- [ ] No button flicker during streaming
- [ ] Window resize: no white-space gaps at bottom
- [ ] Font scale change: no white-space gaps at bottom
- [ ] Load earlier messages: still scrolls to correct anchor position
- [ ] Streaming: bubble grows smoothly, no jumps
- [ ] macOS 14: no regressions (jump button already hidden, topic switch still works via `.id`)
- [ ] macOS 15+: all fixes active and correct
- [ ] macOS 26 Tahoe: all fixes active, no new regressions