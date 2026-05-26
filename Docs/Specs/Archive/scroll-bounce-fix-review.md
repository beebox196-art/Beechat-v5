# Scroll Bounce Fix — Independent Review

**Reviewer:** Kieran (independent reviewer)  
**Date:** 2026-05-09  
**Spec:** `SPECS/scroll-bounce-fix.md`  
**Source:** `Sources/App/UI/Components/MessageCanvas.swift`

---

## VERDICT: **Approve with changes**

The diagnosis is sound and the two-modifier fix is the right approach. Two issues need addressing before implementation.

---

## Issues Found

### 1. ⚠️ Removing the 500ms fallback may cause missed scroll targets on LazyVStack async layout (Medium)

**Problem:** The current code has a `DispatchQueue.main.asyncAfter(deadline: .now() + 0.5)` fallback specifically because LazyVStack renders its children asynchronously. When `messages.count` changes, the `onChange` fires immediately — but the new message view may not yet exist in the proxy's namespace. The old code handled this with a 500ms re-scroll.

The new code removes this fallback entirely. During streaming, the 0.3s dedup window means a second scroll attempt will fire ~300ms after the first. But if only one message arrives (e.g., a user sends a message and waits for the reply), there's no second scroll attempt at all — the first `proxy.scrollTo` may target a message ID that hasn't been laid out yet, and the view won't scroll to bottom.

**Evidence:** The spec itself acknowledges this: *"LazyVStack renders asynchronously"* — yet removes the mechanism that compensates for it.

**Recommended change:** Keep a single delayed fallback, but reduce it to 150ms (enough for LazyVStack layout, not 500ms of jitter):

```swift
if animated {
    withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo(targetId, anchor: .bottom)
    }
    // LazyVStack renders asynchronously — one-shot re-scroll after layout settles
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        proxy.scrollTo(targetId, anchor: .bottom)
    }
}
```

This is a single fire-and-forget call (no `[proxy]` capture needed since `proxy` is a `@State` value type). It doesn't create a bouncing window because `.scrollBounceBehavior(.basedOnSize)` will suppress any visual bounce from the second scroll.

### 2. ⚠️ Unused `debounceTask` property will cause a compiler warning (Low)

The diff removes all uses of `debounceTask` but the spec lists its removal only as a "Secondary Improvement" in §5 rather than including it in the main diff. If not included in the primary change, this will leave an unused `@State` property that produces a compiler warning.

**Recommended change:** Include the `debounceTask` removal in the primary diff, not as a secondary cleanup.

---

## What's Correct

### Two modifiers are the right fix

- `.scrollBounceBehavior(.basedOnSize, axes: .vertical)` — Canonical SwiftUI fix for this exact problem. Available since macOS 14, which matches the deployment target (confirmed in `Package.swift`: `.macOS(.v14)`). ✅
- `.defaultScrollAnchor(.bottom)` — Correctly pins scroll position to bottom during size changes. Also macOS 14+. ✅

### Removing `DispatchQueue.main.async` wrapper on animated scroll

The wrapper was unnecessary — all callers (`onChange`, `onAppear`) already run on the main thread. Removing it eliminates a source of race conditions. ✅

### Simplifying debounce on `onAppear`/`onDisappear`

Immediate state updates are more deterministic than 100ms/50ms delayed Tasks. The old debounce was defensive but created actual race conditions with `scrollTo` calls. ✅

### Diagnosis is thorough

The spec correctly identifies that multiple interacting triggers (missing modifiers + async scroll logic + small content) explain why previous single-point fixes kept failing. ✅

---

## Other ScrollViews in the App

Grep found 6 other files with `ScrollView`:

| File | Type | Bounce Risk |
|------|------|-------------|
| `ThemePicker.swift` | Picker panel | Low — small content list, bounce is acceptable |
| `AgentActivityPanel.swift` | Activity feed | Low — similar to message canvas but shorter-lived |
| `BeeBoardCanvasView.swift` | Horizontal+vertical board | Low — different use case, not chat |
| `BeeBoardPinDetailView.swift` | Pin detail (2 ScrollViews) | Low — not chat |
| `FolderPicker.swift` | Folder list | Low — standard picker |

None of these are chat message canvases. The bounce issue is specific to `MessageCanvas.swift` where content grows incrementally and users expect bottom anchoring. No other ScrollViews need the fix. ✅

### `.scrollBounceBehavior(.never)` vs `.basedOnSize`

`.never` would eliminate bounce entirely but would also remove natural bounce when content genuinely overflows (e.g., long conversations). `.basedOnSize` is the better choice — it gives natural bounce when needed and suppresses it when content fits. This is what iMessage does. ✅

---

## Testing — Validation Steps Assessment

Q's test matrix is solid. I'd add one edge case:

| Test | Expected Result |
|------|-----------------|
| **Send a message, then immediately switch topics** | New topic opens at bottom, no bounce during transition |
| **Window resize while streaming is active** | View stays anchored, no drift |

The existing tests cover the main scenarios well.

---

## Summary

The fix is fundamentally sound. The two-modifier approach is the canonical SwiftUI solution. The only real issue is removing the 500ms fallback without a replacement — even a 150ms one-shot handles the LazyVStack async layout gap without reintroducing bounce. Everything else checks out.

**Required before merge:**
1. Add a single 150ms delayed fallback to the animated scroll path
2. Include `debounceTask` removal in the primary diff
