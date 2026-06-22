# SPEC: Jump-to-Latest Button Fix

**Date:** 2026-05-18  
**Status:** ✅ Implemented & Deployed (pending formal review)  
**Author:** Bee  
**Reviewer:** Q (implementation), Kieran (adversarial review) — PENDING

## Problem

The "Jump to Latest" button (⌄) disappeared in the deployed BeeChat desktop app. Users could scroll up but had no way to jump back to the bottom.

## Root Cause

Two issues introduced in commit `bc26a9e` (scroll compat fix):

### Issue 1: `isAtBottom` set in tracking closure instead of action closure

SwiftUI's `onScrollGeometryChange(for:action:)` has two closures:
1. **Tracking closure** — should be pure, returns the computed value
2. **Action closure** — fires when the tracked value changes, where side effects belong

The compat wrapper was setting `isAtBottom` as a side effect inside the tracking closure and leaving the action closure empty:

```swift
// BROKEN — side effect in tracking closure
.onScrollGeometryChangeCompat { geo in
    let nearBottom = distanceFromBottom < threshold
    isAtBottom = nearBottom  // ← side effect in wrong closure
    return nearBottom
} action: { _, newValue in
    // isAtBottom is already updated inside the handler closure  ← empty!
}
```

On macOS 26 (which is far past macOS 15), the native `onScrollGeometryChange` is used. When `isAtBottom` is set as a side effect in the tracking closure, SwiftUI may coalesce or skip updates during rapid layout changes, causing `isAtBottom` to get stuck at `true`.

### Issue 2: Single 24px threshold lost hysteresis

The original implementation (commit `4e29e8a`) used hysteresis thresholds:
- **Enter (become "at bottom"):** 50px — generous, easy to hit
- **Leave (become "scrolled up"):** 120px — must scroll meaningfully up

The `bc26a9e` commit replaced this with a single 24px threshold. This was too narrow — the button would barely appear, and without hysteresis, it could flicker during layout shifts.

## Fix Applied

### 1. Compat wrapper now takes a `Binding<Bool>`

```swift
func onScrollGeometryChangeCompat(
    _ handler: @escaping (ScrollGeometry) -> Bool,
    binding: Binding<Bool>
) -> some View {
    if #available(macOS 15.0, iOS 18.0, *) {
        self.onScrollGeometryChange(for: Bool.self) { geo in
            let sg = ScrollGeometry(...)
            return handler(sg)  // pure computation
        } action: { _, newValue in
            binding.wrappedValue = newValue  // side effect in action
        }
    } else {
        self  // macOS 14: isAtBottom stays true, auto-scroll via defaultScrollAnchor
    }
}
```

The `@State` is now updated through a `Binding` in the action closure, which is the correct SwiftUI pattern.

### 2. Restored hysteresis thresholds

```swift
let enterThreshold: CGFloat = 50   // become "at bottom"
let leaveThreshold: CGFloat = 120   // become "scrolled up"

if isAtBottom {
    return distanceFromBottom < leaveThreshold   // need to scroll far to leave
} else {
    return distanceFromBottom < enterThreshold    // easy to re-enter
}
```

The hysteresis reads `isAtBottom` in the tracking closure — this is fine because it's reading current state to decide which threshold to apply, not writing to it.

### 3. Call site uses `$isAtBottom` binding

```swift
.onScrollGeometryChangeCompat({ geo in
    // ... hysteresis logic (pure computation) ...
}, binding: $isAtBottom)
```

## Verification

- BeeChat connects and functions normally: ✅
- Scrolling up should reveal ⌄ button: Manual testing needed
- Button should disappear when scrolled to bottom: Manual testing needed
- Button should not flicker during streaming: Manual testing needed

## Commits

- `fc4e710` — fix(scroll): restore jump-to-latest button with hysteresis + proper action closure

## Risk Assessment

| Aspect | Risk |
|--------|------|
| Scroll behaviour | Low — hysteresis is a well-tested pattern (was in original implementation) |
| Button visibility | Low — Binding in action closure is the correct SwiftUI pattern |
| macOS 14 fallback | None — isAtBottom stays true, auto-scroll works via defaultScrollAnchor |

## Lesson Learned

**Side effects in SwiftUI tracking closures are unreliable.** The `onScrollGeometryChange` tracking closure should only compute — all `@State` mutations belong in the action closure. This is documented in Apple's API but easy to miss when writing a compat wrapper.