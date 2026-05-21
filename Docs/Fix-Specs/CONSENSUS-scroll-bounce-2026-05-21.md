# Consensus: Scroll Bounce & White Space Fix (2026-05-21)

**Reconciling:** Kieran review, Q review, Bee coordination  
**Previous consensus:** 2026-05-10 (flawed — fixes made it worse)  
**Previous diagnosis:** DIAGNOSIS-scroll-bounce-2026-05-10.md (correct direction, not fully implemented)

---

## Why the May 10 Consensus Failed

The May 10 consensus added conditional scroll targets, bounce behaviour switching, and removed `onChange(of: showStreamingBubble)`. The DIAGNOSIS showed these made things worse by:
1. Scrolling to a growing element (`"streaming-bubble"`) instead of a stable anchor
2. Switching `.scrollBounceBehavior` to `.automatic` (more bounce, not less)
3. Removing a necessary scroll trigger

After that diagnosis, the code was patched again (scroll-fix4) which added MORE complexity: `scheduleScrollCorrection`, `contentFillsContainer`, hysteresis geometry tracking, and a 200ms debounce. These patches are the source of the CURRENT bounce.

---

## Team Agreement (Both Reviewers Concur)

### Root Cause

The current code has **6 competing scroll-triggering mechanisms** during streaming. They fight `defaultScrollAnchor(.bottom)` and each other:

1. `onChange(of: messages.count)` — multiple sub-actions including forced short-content scroll
2. `onChange(of: containerHeight)` — schedules scroll correction
3. `scheduleScrollCorrection` — async Task fires explicit scroll 100ms after layout changes
4. `onChange(of: topicId)` — triggers scroll
5. `onAppear` — triggers scroll
6. `contentFillsContainer` guard — forces scroll when content is short

The 200ms debounce was added to suppress the resulting chaos, but it masks necessary scrolls too.

### Principle

**The fix is removal, not addition.** Every previous round added mechanisms. This round removes them.

Let `defaultScrollAnchor(.bottom)` do its job. Only call `scrollToBottom` explicitly for user-initiated actions and initial scroll triggers. Never call it during active streaming.

---

## Fix Set (5 Changes, All in `MessageCanvas.swift`)

### Change 1: Simplify `scrollToBottom` — remove debounce, add streaming guard

**Before:**
```swift
private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
    let now = Date()
    if now.timeIntervalSince(lastScrollTime) < 0.2 {
        return
    }
    lastScrollTime = now
    if animated {
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    } else {
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
}
```

**After:**
```swift
private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
    if isStreaming {
        // No animation during streaming — animation fights with SwiftUI's
        // layout engine as content grows, causing visible bounce.
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    } else if animated {
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    } else {
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
}
```

**Kieran confidence:** 90% | **Q confidence:** High

### Change 2: Reduce bottom anchor from 8px to 4px

**Before:**
```swift
Color.clear
    .frame(height: 8)
    .id("bottom-anchor")
```

**After:**
```swift
Color.clear
    .frame(height: 4)
    .id("bottom-anchor")
```

**Kieran confidence:** 85% | **Q confidence:** High  
**Rationale:** 8px is visibly too tall and creates the white space Adam reports. 4px is enough for LazyVStack to render reliably but invisible to the user.

### Change 3: Remove `scheduleScrollCorrection` entirely

Delete:
- `@State private var scrollCorrectionTask: Task<Void, Never>?`
- `private func scheduleScrollCorrection(proxy: ScrollViewProxy)` method
- All calls to `scheduleScrollCorrection` in `.onChange(of: messages.count)` and `.onChange(of: containerHeight)`
- `@State private var lastScrollTime: Date = .distantPast` (only used by debounce)

**Kieran confidence:** 90% | **Q confidence:** High  
**Rationale:** Creates an async feedback loop. 100ms delay + 200ms debounce = mostly dead code that occasionally misfires. `defaultScrollAnchor(.bottom)` handles the cases it was meant to cover.

### Change 4: Remove `contentFillsContainer` + simplify geometry tracking

Delete:
- `@State private var contentHeight: CGFloat = 0`
- `@State private var containerHeight: CGFloat = 0`
- `private var contentFillsContainer: Bool { ... }`
- The `if !contentFillsContainer { scrollToBottom(...) }` block in `.onChange(of: messages.count)`
- The entire `.onChange(of: containerHeight)` handler
- `ScrollGeometryResult` struct (replace with `Bool`)

Simplify `onScrollGeometryChangeCompat` to track only `isAtBottom`:
```swift
.onScrollGeometryChangeCompat(
    transform: { geo in
        guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
            return true
        }
        let enterThreshold: CGFloat = 50
        let leaveThreshold: CGFloat = 120
        let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
        if isAtBottom {
            return distanceFromBottom < leaveThreshold
        } else {
            return distanceFromBottom < enterThreshold
        }
    },
    action: { _, newValue in
        isAtBottom = newValue
    }
)
```

**Kieran confidence:** 70-90% (mixed across sub-items) | **Q confidence:** High  
**Rationale:** `contentHeight`/`containerHeight` only used for `contentFillsContainer`, which we're removing. `defaultScrollAnchor(.bottom)` handles short content.

### Change 5: Restore `.onChange(of: showStreamingBubble)` scroll trigger

**Add:**
```swift
.onChange(of: showStreamingBubble) { _, isShowing in
    if isShowing {
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```

**Kieran confidence:** 60% (depends on macOS version) | **Q confidence:** High  
**Rationale:** When the streaming bubble first appears (empty → has content), something needs to scroll to it. Without this, the first chunk may not scroll into view. Use `animated: false` because this is part of streaming.

---

## What's Preserved

| Feature | Status |
|---|---|
| Jump-to-Latest button | ✅ Preserved (unchanged) |
| isAtBottom detection + hysteresis | ✅ Preserved (simplified) |
| Load Earlier messages | ✅ Preserved (unchanged) |
| ThinkingBeeIndicator | ✅ Preserved (unchanged) |
| Topic switch scroll | ✅ Preserved (unchanged) |
| macOS 14 fallback | ✅ Preserved (simplified) |

## What's Removed

| Mechanism | Reason |
|---|---|
| `scheduleScrollCorrection` | Feedback loop source |
| `contentFillsContainer` | Unnecessary — anchor handles it |
| `onChange(of: containerHeight)` | Only used for scroll correction |
| 200ms debounce | Wrong direction — problem is animation, not call frequency |
| `ScrollGeometryResult` struct | Over-engineered — `Bool` suffices |
| `contentHeight`/`containerHeight` state | Only used for `contentFillsContainer` |
| `lastScrollTime` state | Only used for debounce |
| `scrollCorrectionTask` state | Only used for scroll correction |

---

## Implementation Order

1. Change 2 (anchor 8→4px) — trivial, zero risk
2. Change 3 (remove scheduleScrollCorrection + debounce + lastScrollTime)
3. Change 4 (remove contentFillsContainer + simplify geometry)
4. Change 1 (simplify scrollToBottom with isStreaming guard)
5. Change 5 (restore showStreamingBubble onChange)

---

## Nuclear Option Fallback

If these 5 changes don't resolve the bounce, the fallback is:
1. Remove `onScrollGeometryChangeCompat` entirely
2. Remove `isAtBottom` state
3. Remove Jump-to-Latest button
4. Go back to simple `autoScroll: Bool` from the original `696b33a`
5. Only scroll triggers: `messages.count`, `isStreaming`, `showStreamingBubble`, `onAppear`

This loses the Jump button but eliminates all geometry-related feedback loops. The original code worked with this approach.