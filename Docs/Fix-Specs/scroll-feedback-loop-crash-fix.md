# Fix Spec: MessageCanvas Scroll Feedback Loop & Crash

**Date:** 2026-05-20  
**Author:** Bee (coordinator)  
**Severity:** Critical — app killed by macOS, blocks release  
**Version:** v0.5.3-scroll-fix3  

---

## 1. Problem Statement

### 1.1 User-Visible Symptoms
1. **White space gap** appears in the chat view when typing a second line in the composer (Composer grows → scroll container shrinks → scroll position drifts)
2. **App crash** — macOS terminates BeeChat for exceeding 50% CPU over 180 seconds. Memory footprint spikes from 88 MB → 3.8 GB during the event.

### 1.2 Reproduction
1. Open a topic with existing messages
2. Type a message long enough to push the Composer to a second line
3. White space appears between messages and the bottom of the view
4. Continuing to type or sending the message can trigger the crash

### 1.3 Crash Signature
- **Report:** `BeeChatApp_2026-05-20-084956_Openclaws-Mac-mini.cpu_resource.diag`
- **Event:** CPU resource limit exceeded — 52% CPU average over 173s, footprint 88 MB → 3.8 GB
- **App version:** 0.5.3-scroll-fix3

**This is a recurring pattern.** Previous CPU resource kills on:
- 2026-05-13: 100% CPU for 90s (v0.5.2)
- 2026-05-14: 54% CPU for 167s (v0.5.2)
- 2026-05-20: 52% CPU for 173s (v0.5.3-scroll-fix3)

The v0.5.3-scroll-fix3 changes attempted to address this but did not fully resolve it.

---

## 2. Alignment with Standard SwiftUI Patterns

This fix spec follows **Apple's documented best practices** for `onScrollGeometryChange`:

- Apple's documentation states: "You should avoid updating large parts of your app whenever the scroll geometry changes."
- The `transform` closure should return an `Equatable` value that changes **as infrequently as possible**.
- The `action` closure should update **only the smallest possible piece of state**.
- Setting `@State` that affects the ScrollView's own size, position, or frame creates a layout cycle.
- Overlay-based buttons (`.overlay`) that don't affect scroll geometry are the standard pattern for scroll-to-bottom buttons.
- `defaultScrollAnchor(.bottom)` is the standard iOS 17+ approach for chat-style auto-scroll — we already use this correctly.

**What we're fixing is a deviation from these patterns**, not inventing new ones:
1. Our `action` closure mutates `@State var isAtBottom` which drives button visibility inside the ScrollView's ZStack — this violates "smallest possible state change" and "avoid updating large parts of your app."
2. Our button is a ZStack sibling that affects geometry when opacity changes — the standard pattern is `.overlay()` which sits outside the scroll geometry.
3. Our `needsScrollAfterLayout` state mutation inside the geometry handler creates a secondary cycle — the standard pattern is to never mutate state that triggers scroll actions from inside the handler.

References:
- [Apple: onScrollGeometryChange documentation](https://developer.apple.com/documentation/swiftui/view/onscrollgeometrychange(for:of:action:))
- [nilcoalescing.com: Modern SwiftUI APIs for Programmatic Scrolling](https://nilcoalescing.com/blog/ModernSwiftUIAPIsForProgrammaticScrolling)
- [fatbobman.com: Evolution of SwiftUI Scroll Control APIs](https://fatbobman.com/en/posts/the-evolution-of-swiftui-scroll-control-apis/)

---

## 3. Root Cause Analysis

### 2.1 Primary Cause: `onScrollGeometryChangeCompat` → `isAtBottom` State Feedback Loop

The crash stack traces directly into:

```
ScrollActionDispatcher.updateValue()
  → OnScrollGeometryChangeModifier.GeometryActionProvider.makeOutput(input:)
    → closure #1 in View.onScrollGeometryChangeCompat(_:binding:)  (MessageCanvas.swift:295)
      → closure #2 in closure #1 in closure #1 in MessageCanvas.body.getter  (MessageCanvas.swift:99)
        → State.wrappedValue.setter  (isAtBottom)
```

**The loop:**
1. User types second line → Composer grows (via `safeAreaInset`) → ScrollView container height shrinks
2. Container height change fires `onScrollGeometryChangeCompat`
3. Handler computes new `isAtBottom` value and sets `@State var isAtBottom`
4. `isAtBottom` state change triggers SwiftUI view graph update
5. The Jump-to-Latest button's opacity/animation depends on `isAtBottom`:
   ```swift
   .opacity(isAtBottom ? 0 : 1)
   .animation(.easeInOut(duration: 0.2), value: isAtBottom)
   ```
6. Button appearing/disappearing changes the ZStack layout → container geometry changes
7. Geometry change fires `onScrollGeometryChangeCompat` again → **loop**

### 2.2 Secondary Cause: `needsScrollAfterLayout` Self-Triggering

The `needsScrollAfterLayout` flag was added to correct scroll position after Composer height changes, but it can also create a cycle:

```swift
.onChange(of: needsScrollAfterLayout) { _, needs in
    if needs {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if isAtBottom {
                scrollToBottom(proxy: proxy, animated: false)
            }
            needsScrollAfterLayout = false
        }
    }
}
```

- `scrollToBottom` → scroll position changes → `onScrollGeometryChangeCompat` fires → may set `needsScrollAfterLayout = true` again (in the `onChange(of: messages.count)` or container height check)
- The 0.1s delay helps but doesn't break the logical cycle — it just slows it to ~10 iterations/second, which is still enough to spike CPU and grow memory

### 2.3 Memory Growth

The feedback loop causes SwiftUI's AttributeGraph to repeatedly recalculate the entire view hierarchy. Each cycle allocates new layout nodes. The AttributeGraph isn't given time to garbage-collect stale nodes because new transactions are queued faster than old ones can be cleaned up. Result: 3.8 GB footprint from a starting 88 MB.

### 2.4 Why the May 13/14 crashes were worse (v0.5.2)

In v0.5.2, there was no `onScrollGeometryChangeCompat` at all — the scroll position correction was even more aggressive, creating a tighter loop. The v0.5.3-scroll-fix3 changes (hysteresis thresholds, `needsScrollAfterLayout` debounce) slowed the loop but didn't break it.

---

## 4. Fix Specification

### 4.1 Guiding Principles

1. **No state mutations inside geometry handlers that cause layout changes.** This is the #1 Apple guideline violation.
2. **Break the feedback loop, don't just slow it.** Debouncing and hysteresis are harm reduction, not a fix.
3. **The Jump-to-Latest button must not affect scroll geometry.** Use `.overlay()` (standard pattern), not ZStack sibling.
4. **Follow Apple's two-closure design:** transform returns a minimal `Equatable` value, action updates minimal state.

1. **No state mutations inside geometry handlers that cause layout changes.** This is the #1 SwiftUI rule being violated.
2. **Break the feedback loop, don't just slow it.** Debouncing and hysteresis are harm reduction, not a fix.
3. **The Jump-to-Latest button must not affect scroll geometry.** Its visibility is currently layout-affecting.

### 4.2 Change 1: Remove `isAtBottom` state mutation from geometry handler

**File:** `MessageCanvas.swift`  
**Lines affected:** ~99 (body getter), ~295 (onScrollGeometryChangeCompat)

**Current (broken):**
```swift
@State private var isAtBottom: Bool = true

// In body:
.onScrollGeometryChangeCompat({ geo in
    // ... compute distanceFromBottom ...
    if isAtBottom {
        return distanceFromBottom < leaveThreshold
    } else {
        return distanceFromBottom < enterThreshold
    }
}, binding: $isAtBottom)
```

**Proposed:** Replace `@State var isAtBottom` with a `@State var scrollOffset: CGFloat` that stores the raw scroll position, and compute `isAtBottom` as a derived property that does NOT trigger view updates through layout-affecting dependencies.

```swift
@State private var scrollOffset: CGFloat = 0
@State private var contentHeight: CGFloat = 0
@State private var containerHeight: CGFloat = 0

private var isAtBottom: Bool {
    guard contentHeight > 0, containerHeight > 0 else { return true }
    let distanceFromBottom = contentHeight - scrollOffset - containerHeight
    return distanceFromBottom < 50
}
```

**Critical:** `isAtBottom` computed this way is NOT a `@State` — it's a pure computed property. Changes to `scrollOffset`/`contentHeight`/`containerHeight` will trigger view updates, but these are read-only geometry values, not layout-affecting booleans that change button visibility.

Wait — this still has the problem. If `scrollOffset` changes trigger a view update, and the view update changes the button visibility, which changes layout, which changes geometry...

**Better approach:** Use `onScrollGeometryChangeCompat` to update raw geometry values WITHOUT binding to `isAtBottom` at all. Separate the "should we show the jump button" logic into a **non-layout-affecting** overlay.

### 4.2 (Revised): Separate geometry tracking from button visibility

```swift
@State private var isAtBottom: Bool = true
@State private var lastContainerHeight: CGFloat = 0
@State private var needsScrollAfterLayout: Bool = false

// In onScrollGeometryChangeCompat handler:
// Track geometry for scroll correction, but DO NOT use hysteresis
// that reads isAtBottom (which creates circular dependency).
// Instead, just track raw distances.
.onScrollGeometryChangeCompat({ geo in
    guard geo.contentSize.height > 0, geo.containerSize.height > 0 else {
        return true
    }
    // Detect container height changes (Composer growing/shrinking)
    if lastContainerHeight > 0 && abs(geo.containerSize.height - lastContainerHeight) > 2 {
        needsScrollAfterLayout = true
    }
    lastContainerHeight = geo.containerSize.height
    
    // Pure function: compute at-bottom from geometry only
    let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
    return distanceFromBottom < 50
}, binding: $isAtBottom)
```

**But this still binds `isAtBottom`!** The core problem is that `isAtBottom` state changes → button opacity animation → layout change → geometry change → handler fires → `isAtBottom` changes again.

### 4.3 Change 2: Make Jump-to-Latest button non-layout-affecting

This is the critical fix. The button must NOT participate in the scroll view's geometry calculation.

**Current (broken):** The button is inside the ZStack alongside the ScrollView, using `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)`. When its opacity changes, it can affect layout.

**Proposed:** Use `.overlay()` instead of ZStack, or use `transaction { $0.animation = nil }` to prevent the button's visibility change from propagating layout changes.

```swift
// Option A: Use .overlay on the ScrollView (button doesn't affect scroll geometry)
ScrollViewReader { proxy in
    ScrollView(.vertical, showsIndicators: true) {
        // ... content ...
    }
    // ... scroll modifiers ...
    .overlay(alignment: .bottomTrailing) {
        Button(action: { ... }) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isAtBottom ? 0 : 1)
        .allowsHitTesting(!isAtBottom)
        .padding(.bottom, 12)
        .padding(.trailing, 12)
    }
}
```

**Option B (simpler, preferred):** Disable animation on `isAtBottom` changes entirely, and use `withTransaction` to suppress the layout-affecting animation:

```swift
// Replace the animation on isAtBottom with a non-layout animation
Button(action: { ... }) { ... }
    .opacity(isAtBottom ? 0 : 1)
    .allowsHitTesting(!isAtBottom)
    .padding(.bottom, 12)
    .padding(.trailing, 12)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
// REMOVE: .animation(.easeInOut(duration: 0.2), value: isAtBottom)
// The animation on isAtBottom causes the button to animate opacity,
// which SwiftUI treats as a layout-affecting change in a ZStack.
```

**This alone may not be sufficient** because even without `.animation()`, an opacity change from 0→1 or 1→0 can trigger a relayout in a ZStack.

**Option C (most robust, recommended):** Make the button always take up space (never conditionally affect layout) by using a fixed-size overlay that's always present:

```swift
.overlay(alignment: .bottomTrailing) {
    Color.clear
        .frame(width: 48, height: 48)
        .overlay {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if let proxy = scrollProxy {
                        proxy.scrollTo("bottom-anchor", anchor: .bottom)
                    }
                }
                isAtBottom = true
            }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(isAtBottom ? 0 : 1)
            .allowsHitTesting(!isAtBottom)
        }
        .padding(.bottom, 12)
        .padding(.trailing, 12)
}
```

This ensures the overlay always occupies the same space regardless of `isAtBottom` value.

### 4.4 Change 3: Move scroll correction out of geometry handler

**Current (broken):** Setting `needsScrollAfterLayout = true` inside `onScrollGeometryChangeCompat` and also in `onChange(of: messages.count)` creates a cycle where scroll corrections re-trigger geometry changes.

**Proposed:** Use a single `Task`-based approach that coalesces corrections:

```swift
@State private var scrollCorrectionTask: Task<Void, Never>?

private func scheduleScrollCorrection(proxy: ScrollViewProxy) {
    scrollCorrectionTask?.cancel()
    scrollCorrectionTask = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```

Call `scheduleScrollCorrection` only from:
1. `onChange(of: messages.count)` — new message appeared
2. `onChange(of: thinkingState)` — streaming started/stopped
3. `onAppear` — initial load

**Do NOT call it from `onScrollGeometryChangeCompat`.** The geometry handler should only track `isAtBottom` — it should never trigger a scroll action.

### 4.5 Change 4: Remove container height tracking from geometry handler

**Current:**
```swift
if lastContainerHeight > 0 && abs(geo.containerSize.height - lastContainerHeight) > 2 {
    needsScrollAfterLayout = true
}
lastContainerHeight = geo.containerSize.height
```

This mutates `@State` inside the geometry handler, which is called during a SwiftUI update pass. Even though `needsScrollAfterLayout` is later checked in `onChange`, the mutation itself can trigger re-evaluation.

**Proposed:** Remove this entirely. Container height changes (from Composer growing/shrinking) should be handled by the Composer itself posting a notification, or by the scroll correction task coalescing naturally.

Alternative: Use `onChange(of:)` on the Composer's text to schedule a scroll correction:

```swift
.onChange(of: composerText) { _, _ in
    scheduleScrollCorrection(proxy: proxy)
}
```

(Or whichever `@State` drives the Composer height.)

### 4.6 Change 5: Add crash guard — limit scroll correction frequency

Even with the loop broken, add a safety valve:

```swift
@State private var lastScrollTime: Date = .distantPast

private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
    let now = Date()
    if now.timeIntervalSince(lastScrollTime) < 0.15 {
        return  // Coalesce: skip if called within 150ms
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

This debounce already exists. Keep it, but increase the minimum interval to **200ms** for safety:

```swift
if now.timeIntervalSince(lastScrollTime) < 0.2 { return }
```

---

## 5. Summary of Changes

| # | Change | File | Risk | Rationale |
|---|--------|------|------|-----------|
| 1 | Move Jump button from ZStack sibling to `.overlay()` | MessageCanvas.swift | Low | Removes button from scroll geometry calculation |
| 2 | Remove `.animation(.easeInOut, value: isAtBottom)` from button | MessageCanvas.swift | Low | Prevents animated layout change triggering geometry recalc |
| 3 | Remove `needsScrollAfterLayout` state and `onChange` handler | MessageCanvas.swift | Medium | Eliminates secondary feedback path |
| 4 | Replace `needsScrollAfterLayout` with `Task`-based `scheduleScrollCorrection()` | MessageCanvas.swift | Medium | Properly coalesces corrections, no state mutation in geometry handler |
| 5 | Remove container height tracking from `onScrollGeometryChangeCompat` | MessageCanvas.swift | Low | State mutations during SwiftUI update pass cause loops |
| 6 | Add Composer text `onChange` to schedule scroll correction | MessageCanvas.swift | Low | Handles Composer height changes without geometry handler |
| 7 | Increase scroll debounce to 200ms | MessageCanvas.swift | Low | Extra safety margin against rapid re-triggering |
| 8 | Make overlay fixed-size so opacity changes don't affect layout | MessageCanvas.swift | Low | Belt-and-suspenders: even opacity 0→1 won't change geometry |

---

## 6. What This Does NOT Change

- `defaultScrollAnchor(.bottom)` — kept as-is, this is correct for auto-scroll
- `LazyVStack` content — no changes to message rendering
- Composer layout — no changes to Composer itself
- Hysteresis thresholds (50/120px) — KEPT ➕ (post-review: retained for UX quality, safe once feedback loop is broken)
- `scrollToBottom` animated vs non-animated logic — kept as-is

---

## 7. Verification Plan

### 6.1 Functional Tests
1. Type a message → first line only → verify no white space
2. Type a message → push to second line → verify no white space appears
3. Send a message → verify scroll stays at bottom
4. Scroll up → verify Jump-to-Latest button appears
5. Tap Jump-to-Latest → verify scrolls to bottom and button disappears
6. Receive streaming response → verify auto-scroll to bottom works
7. Switch topics → verify scroll to bottom works

### 6.2 Performance Tests
1. Open Activity Monitor → BeeChatApp CPU should stay under 5% during idle
2. Type rapidly (second line transitions) → CPU should not exceed 30% momentarily
3. Hold a 30-minute conversation → memory should stay under 200 MB
4. Leave app idle for 10 minutes → memory should not grow

### 6.3 Regression Tests
1. macOS 14 compatibility — verify `onScrollGeometryChangeCompat` fallback still works
2. Short content (< 1 viewport) — verify content stays at bottom
3. Long content (> 10 viewports) — verify scroll works normally
4. Topic switching — verify scroll resets correctly

---

## 8. Known Risks: `contentFillsContainer`

The current code uses `@State private var contentFillsContainer: Bool = false` set inside the geometry handler. This is used for the short-content fallback:

```swift
if !contentFillsContainer {
    scrollToBottom(proxy: proxy, animated: false)
}
```

This is another potential feedback loop source (geometry handler → state mutation → scroll action → geometry change). **In the fix, this should be replaced with the Task-based approach** — `contentFillsContainer` should be tracked but scroll corrections should go through `scheduleScrollCorrection`.

---

## 9. Review Results (2026-05-20)

Both Q (builder) and Kieran (adversarial reviewer) gave **APPROVED WITH CONCERNS**.

### Q's Key Concerns:
1. `.offset(y: isAtBottom ? 8 : 0)` on the button is layout-affecting in ZStack — spec didn't call this out explicitly (Medium)
2. Hysteresis should be kept for UX quality — removing it was overzealous (Medium)
3. `contentFillsContainer` is still set inside the geometry handler — not in the change table (High)
4. Compat wrapper mutates `@State` inside the transform closure, not the action closure — violates Apple's pattern (Medium)
5. Need to track raw geometry values separately from derived booleans (Medium)
6. macOS 14 fallback loses `needsScrollAfterLayout` with no replacement (Low)
7. `Task`-based `scheduleScrollCorrection` could re-trigger geometry handler — need to ensure scroll corrections don't cause `isAtBottom` flips that re-enter the handler (Low)

### Kieran's Key Concerns:
1. `contentFillsContainer` needs explicit change row — spec §8 says "should be replaced" but change table doesn't include it (Medium)
2. `.overlay()` approach confirmed — opacity changes on overlay don't affect ScrollView geometry (Validated ✅)
3. `.offset(y:)` must also be removed — same as Q's concern 1 (Medium)
4. Hysteresis should be kept — same as Q's concern 2 (Medium)
5. Composer text `onChange` for scroll correction needs access to `@State` that drives Composer height — need to verify this is accessible from MessageCanvas (Low)
6. macOS 14 fallback: removing `needsScrollAfterLayout` with no replacement means macOS 14 users lose scroll-to-bottom when Composer grows (Medium)
7. `scheduleScrollCorrection` must guard against re-triggering — scroll action can change geometry, which fires handler, which must not schedule another correction (Low)

### Agreed Resolution:
All concerns addressed in the revised change table below (§10).

---

## 10. Revised Change Table (Post-Review)

Incorporates Q and Kieran's review concerns. Changes from original spec marked with ➕.

| # | Change | File | Risk | Rationale |
|---|--------|------|------|----------|
| 1 | Move Jump button from ZStack sibling to `.overlay(alignment: .bottomTrailing)` on the ScrollView | MessageCanvas.swift | Low | Removes button from scroll geometry calculation |
| 2 | Remove `.animation(.easeInOut, value: isAtBottom)` AND `.offset(y: isAtBottom ? 8 : 0)` from button ➕ | MessageCanvas.swift | Low | Both are layout-affecting in ZStack; neither needed in overlay |
| 3 | Make overlay container fixed-size (48×48) with button inside — opacity changes can't affect layout ➕ | MessageCanvas.swift | Low | Belt-and-suspenders: zero geometry impact from button visibility |
| 4 | Keep hysteresis thresholds (50/120px) in `onScrollGeometryChangeCompat` ➕ | MessageCanvas.swift | Low | Prevents button flickering near boundary; safe once feedback loop is broken |
| 5 | Remove `needsScrollAfterLayout` state and `onChange` handler | MessageCanvas.swift | Medium | Eliminates secondary feedback path |
| 6 | Replace `needsScrollAfterLayout` with `Task`-based `scheduleScrollCorrection()` | MessageCanvas.swift | Medium | Properly coalesces corrections, no state mutation in geometry handler |
| 7 | Remove container height tracking (`lastContainerHeight`) from geometry handler | MessageCanvas.swift | Low | State mutations during SwiftUI update pass cause loops |
| 8 | Remove `contentFillsContainer` `@State` mutation from geometry handler; replace with computed property from tracked geometry values ➕ | MessageCanvas.swift | Medium | Was a hidden feedback loop source; compute inline from tracked values |
| 9 | Move all `@State` mutations out of the transform closure into the action closure of `onScrollGeometryChangeCompat` ➕ | MessageCanvas.swift + Compat extension | Medium | Follows Apple's documented pattern; transform is pure, action mutates state |
| 10 | Add Composer height `onChange` to schedule scroll correction (access via `@Binding` or `@State` in parent) | MessageCanvas.swift | Low | Handles Composer height changes without geometry handler |
| 11 | Increase scroll debounce to 200ms | MessageCanvas.swift | Low | Extra safety margin against rapid re-triggering |
| 12 | Add macOS 14 fallback: `DispatchQueue.main.asyncAfter` for short-content scroll correction ➕ | MessageCanvas.swift | Low | macOS 14 users lose `onScrollGeometryChange` — need alternative for auto-scroll |
| 13 | Guard `scheduleScrollCorrection` against re-trigger: check `isAtBottom` before scrolling, don't schedule if already at bottom ➕ | MessageCanvas.swift | Low | Prevents scroll correction from re-entering geometry handler |

### Key Design Decisions (Post-Review):

1. **`.overlay()` over ZStack** — Both reviewers confirmed this breaks the primary feedback loop. An overlay's opacity/visibility changes don't feed back into `ScrollGeometry`.

2. **Keep hysteresis** — Both reviewers recommend keeping the 50/120px thresholds. They prevent button flickering near the boundary. Once the overlay removes the layout feedback, hysteresis is purely a UX improvement with no loop risk.

3. **Restructure `onScrollGeometryChangeCompat`** — Q identified that the current wrapper mutates `@State` inside the transform closure. Apple's pattern is: transform returns an `Equatable` value (pure), action mutates state. The revised compat wrapper should:
   ```swift
   .onScrollGeometryChangeCompat(
       transform: { geo in
           // Pure computation — no @State mutations
           guard geo.contentSize.height > 0, geo.containerSize.height > 0 else { return true }
           let fillsContainer = geo.contentSize.height >= geo.containerSize.height
           let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
           let enterThreshold: CGFloat = 50
           let leaveThreshold: CGFloat = 120
           return distanceFromBottom < (isAtBottom ? leaveThreshold : enterThreshold)
       }, action: { oldValue, newValue in
           // All state mutations here
           isAtBottom = newValue
       }
   )
   ```
   Note: The hysteresis reads `isAtBottom` in the transform, but this is safe because it's a read (not a write) and the value is stale-by-one-frame at most.

4. **`contentFillsContainer` becomes computed** — Instead of `@State`, track `@State private var contentHeight: CGFloat` and `@State private var containerHeight: CGFloat` (set in the action closure), then compute:
   ```swift
   private var contentFillsContainer: Bool {
       guard contentHeight > 0, containerHeight > 0 else { return false }
       return contentHeight >= containerHeight
   }
   ```
   This avoids a separate `@State` mutation in the geometry handler.

5. **macOS 14 fallback** — On macOS 14, `onScrollGeometryChangeCompat` is a no-op. The current fallback just returns `self`. We need to add a `DispatchQueue.main.asyncAfter` based approach for short-content auto-scroll on macOS 14, similar to the `Task`-based `scheduleScrollCorrection` but using GCD.

---

## 11. Review Checklist (Final)

- [ ] **Q (builder):** Verify the fix compiles and all functional tests pass
- [ ] **Q (builder):** Verify CPU stays under 5% idle, memory stays under 200 MB after 30 min
- [ ] **Q (builder):** Verify no white space on second-line Composer transitions
- [ ] **Q (builder):** Verify `.overlay()` button has zero impact on scroll geometry (confirm with debug logging)
- [ ] **Kieran (reviewer):** Verify no new feedback loops introduced
- [ ] **Kieran (reviewer):** Verify all `@State` mutations are in the action closure, not the transform closure
- [ ] **Kieran (reviewer):** Verify `contentFillsContainer` is computed, not `@State`
- [ ] **Kieran (reviewer):** Verify macOS 14 fallback works for short-content auto-scroll
- [ ] **Bee (verifier):** Run the app for 30 minutes with active chat → verify no crash, no white space, no memory growth
- [ ] **Bee (verifier):** Verify no button flickering near scroll boundary (hysteresis test)