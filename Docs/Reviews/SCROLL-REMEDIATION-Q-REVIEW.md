# Scroll & Whitespace Remediation — Q Build Review

**Reviewer:** Q  
**Date:** 2026-05-19  
**Spec:** `Docs/Specs/SCROLL-AND-WHITESPACE-REMEDIATION.md`  
**Verdict:** ✅ Implementable with caveats — see per-fix ratings below

---

## Summary

The spec accurately identifies the root causes and proposes sensible fixes. The BEFORE code snippets match the actual source. The overall strategy (remove forced scroll, let `defaultScrollAnchor(.bottom)` do its job) is correct and aligns with how Telegram/macOS works. I have a few concerns documented per-fix.

---

## Fix-by-Fix Review

### Fix 1: Remove forced `scrollToBottom` from `onChange(of: messages.count)`

**Rating: 🟢 GREEN**

**BEFORE match:** ✅ Exact match. The spec quotes:
```swift
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        ...
    } else if pendingTopicScroll {
        ...
    } else if isAtBottom {
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```
This is verbatim what's in `MessageCanvas.swift` lines 115–127.

**Side-effect analysis:**
- **Topic switching:** Not affected. Topic switches are handled by `onChange(of: topicId)` which calls `scrollToBottom(proxy:, animated: true)` independently. The removed `isAtBottom` branch is NOT the topic-switch path.
- **Load earlier messages:** Not affected. Uses `anchorMessageId` + `scrollTo(anchorId, anchor: .top)`, which is the first branch and runs before the removed `else if isAtBottom`.
- **Initial load / onAppear:** Not affected. `onAppear` calls `scrollToBottom` directly.
- **New messages during streaming:** This is the exact problematic path. Removing this is the right call — `defaultScrollAnchor(.bottom)` keeps the view pinned.

**One caveat:** When a user sends a message and is already at the bottom, the new user-message bubble will appear via `defaultScrollAnchor(.bottom)` keeping the scroll pinned. This works. But if `isAtBottom` were to briefly flicker `false` during the layout transition (which `onScrollGeometryChangeCompat` could cause), the old code would have force-scrolled back. Without it, the user could end up slightly scrolled up after sending. The hysteresis in the `onScrollGeometryChangeCompat` handler (enter threshold 50pt, leave threshold 120pt) makes this unlikely, but it's worth testing the "send message while at bottom" case carefully.

**Recommendation:** Ship it. Test the send-while-at-bottom edge case.

---

### Fix 2: Remove `scrollToBottom` from `onChange(of: thinkingState)`

**Rating: 🟢 GREEN**

**BEFORE match:** ✅ Exact match. Lines 135–140 in `MessageCanvas.swift`:
```swift
.onChange(of: thinkingState) { oldState, newState in
    BeeChatLogger.log("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
    if newState == .thinking && isAtBottom {
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```

**Side-effect analysis:**
- The spec's rationale is correct: `.thinking` fires right after the user sends a message, when Composer height may still be transitioning. The forced scroll at that moment creates the whitespace overshoot.
- `defaultScrollAnchor(.bottom)` will handle the transition from user-message to thinking-bee indicator without programmatic intervention.
- The log line is preserved, which is good for debugging.

**Caveat:** With Fix 5 (per-topic thinkingState), this `onChange` will only fire for the active topic's state changes, reducing spurious invocations. Even without Fix 5, removing the scroll call is safe.

**Recommendation:** Ship it.

---

### Fix 3: Move WidthReader outside ScrollView

**Rating: 🟡 AMBER**

**BEFORE match:** ✅ The `WidthReader` as a `.background` on the `ScrollView` matches exactly (lines 100–106):
```swift
.background(
    WidthReader { width in
        Color.clear
            .preference(key: WidthPreferenceKey.self, value: width)
    }
)
```

**Concerns:**
1. The proposed AFTER wraps everything in a `GeometryReader`. This changes the view hierarchy from `ZStack > ScrollViewReader > ScrollView > ...` to `GeometryReader > ScrollViewReader > ScrollView > ...`. GeometryReader is greedy in both dimensions — it will propose maximum size to the `ScrollViewReader`, which means the scroll view's parent gets an ideal size of infinity. In a `VStack(spacing: 0)` alongside `GatewayStatusBar` and `Composer`, this needs careful testing. The `GeometryReader` will take all offered space, but since `MessageCanvas` already has `.frame(maxHeight: .infinity)`, this should work — but verify in practice.

2. The `measuredWidth` is currently set via `.onPreferenceChange(WidthPreferenceKey.self)` and propagated via `.environment(\.canvasWidth, measuredWidth)`. The new approach uses `let measuredWidth = geometry.size.width` inside the GeometryReader body. This should work identically, but the preference key path is removed entirely. Verify that no other view reads `WidthPreferenceKey` directly.

3. The spec's AFTER snippet removes the `.onPreferenceChange` and `.background(WidthReader...)` but doesn't show what the full ZStack looks like after. Make sure the `measuredWidth` binding to `@State` still updates reactively. Currently it uses `onPreferenceChange` which is a SwiftUI reaction cycle. With `let measuredWidth = geometry.size.width` inside a GeometryReader body, it updates on every layout pass automatically — actually better, no preference key delay.

**Recommendation:** Implement, but test that the GeometryReader doesn't cause the `MessageCanvas` to collapse or expand unexpectedly in the `VStack` layout with the `Composer`. May need explicit `.frame(maxHeight: .infinity)` on the GeometryReader child.

---

### Fix 4: Replace cursor animation with TimelineView

**Rating: 🟡 AMBER**

**BEFORE match:** ✅ Exact match. Lines in `StreamingBubble.swift`:
```swift
Text("▌")
    .font(themeManager.font(.body))
    .foregroundColor(themeManager.color(.accentPrimary))
    .opacity(cursorVisible ? 1 : 0)
    .animation(themeManager.animation(.slow).repeatForever(autoreverses: true), value: cursorVisible)
```

**Concerns:**
1. **macOS version:** The project targets macOS 14+ (confirmed in Package.swift: `.macOS(.v14)`). `TimelineView` with `.periodic(from:by:)` schedule was introduced in **iOS 15 / macOS 12**, so availability is fine. ✅

2. **Animation smoothness:** The current `.repeatForever(autoreverses: true)` creates a smooth fade in/out. The `TimelineView` replacement uses `Int(timeline.date.timeIntervalSince1970) % 2 == 0` which creates a hard on/off blink every 1 second. This is visually different — it's a blink, not a fade. This is arguably better for accessibility (clearer state) but worse for aesthetics. The spec says "doesn't trigger SwiftUI layout invalidation" which is true — `TimelineView` only invalidates the `body` at scheduled intervals, not every animation frame.

3. **The `@State private var cursorVisible = false` and `.onAppear { cursorVisible = true }` should be removed** since they're no longer needed. The spec doesn't mention this cleanup.

4. **Alternative approach:** If we want to preserve the fade effect without layout invalidation, we could use `TimelineView(.periodic(from: .now, by: 0.5))` and compute opacity as a sin wave based on the date. But this adds complexity for minimal benefit. The hard blink is standard for terminal cursors.

**Recommendation:** Implement with the hard blink. Remove the now-unused `@State cursorVisible` and `.onAppear`. Test that streaming scroll is smoother.

---

### Fix 5: Per-topic thinkingState

**Rating: 🟢 GREEN (with note)**

**BEFORE match:** ✅ The spec correctly identifies that `MainWindow.swift` passes `syncBridgeObserver.thinkingState` directly to `MessageCanvas` (line 166):
```swift
thinkingState: syncBridgeObserver.thinkingState,
```

**Analysis:**
- The sidebar already computes per-topic `topicThinkingState` (line 447):
  ```swift
  let topicThinkingState: ThinkingState = syncBridgeObserver.isStreamingSession(topic.sessionKey) ? syncBridgeObserver.thinkingState : .idle
  ```
  This confirms the pattern works — the sidebar was already fixed for this.

- The proposed fix adds a similar `let topicThinkingState` computed in the detail area and passes it to `MessageCanvas` instead of the global `thinkingState`. This is straightforward.

- **One subtlety:** The `onChange(of: thinkingState)` in `MessageCanvas` will now only fire when the *active topic's* state changes. This is exactly what we want. When background Topic B goes idle→streaming, the active Topic A's canvas won't re-render.

- **Edge case to verify:** When the user switches TO a topic that's already streaming. The `catchUpStreaming` method in `SyncBridgeObserver` sets `thinkingState = .streaming` and `isStreaming = true`. At that point, `isActiveTopicStreaming` becomes true, and `topicThinkingState` becomes `.streaming`. The `onChange(of: thinkingState)` in MessageCanvas will see `.idle` → `.streaming`. But we've removed the `scrollToBottom` in Fix 2, so this is fine — it just logs the transition. ✅

**Naming concern:** The spec uses `topicThinkingState` as the local variable name. This same name is already used in the sidebar list (line 447). Since they're in different `@ViewBuilder` scopes, there's no collision, but it might be confusing during maintenance. Consider `activeTopicThinkingState` in the detail area for clarity. Minor point.

**Recommendation:** Ship it. Consider naming it `activeTopicThinkingState` for clarity.

---

### Fix 6: Reduce streaming poll frequency from 50ms to 150ms

**Rating: 🟢 GREEN**

**BEFORE match:** ✅ Exact match. Line in `SyncBridgeObserver.swift`:
```swift
try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
```

**Analysis:**
- 150ms (≈7fps) is visually adequate for streaming text. Humans read at roughly 10-15 words per second for chat content. At 7fps, each frame can show ~2 words of new content, which feels responsive.
- This directly reduces SwiftUI invalidations from ~20/sec to ~7/sec during streaming, which compounds with Fix 4 (no cursor animation invalidation) and Fix 5 (no cross-topic invalidation).
- The spec's note about event-driven updates replacing polling is a good future improvement but not blocking.

**Recommendation:** Ship it. Can always tune later.

---

### Fix 7: Use `safeAreaInset(edge: .bottom)` for Composer

**Rating: 🟡 AMBER**

**BEFORE match:** ✅ The current detail layout is confirmed (MainWindow.swift lines 152–177):
```swift
VStack(spacing: 0) {
    GatewayStatusBar(...)
    Divider()
    // MessageCanvas in ZStack with resetIndicator
    Divider()
    Composer(viewModel: composerViewModel, onSend: composerSend)
}
```

**Concerns:**

1. **`NavigationSplitView` compatibility:** The spec asks whether `safeAreaInset` works with `NavigationSplitView`. **It does.** `safeAreaInset(edge:)` is a modifier on the scroll view itself, not on the navigation container. Since it's applied to `MessageCanvas` (which contains the `ScrollView`), and `MessageCanvas` sits inside the detail column of the `NavigationSplitView`, this works fine. Apple's own Messages app uses this exact pattern in a `NavigationSplitView` on macOS.

2. **Layout structure change:** The proposed change removes the `Composer` from the `VStack` and instead attaches it as a `safeAreaInset`. This means:
   - The `VStack(spacing: 0)` loses the `Composer` and the `Divider` above it.
   - `MessageCanvas` gets `.safeAreaInset(edge: .bottom) { VStack { Divider; Composer } }`.
   - The `Divider` between the canvas and composer must move inside the `safeAreaInset`.

3. **`GatewayStatusBar` and `Divider` before the canvas:** These stay in the `VStack` above `MessageCanvas`. That's fine — they're above the scroll view, not inset.

4. **The `ZStack(alignment: .top)` wrapping MessageCanvas + resetIndicator:** This needs careful handling. The `safeAreaInset` should be on the `ZStack`, not on the `ScrollView` inside `MessageCanvas`. If applied inside `MessageCanvas`, it won't include the `GatewayStatusBar`. If applied at the `MainWindow` level on the whole content area, it works. The spec proposes applying it to `MessageCanvas(...)` which is correct — it's the scroll-containing view.

   Wait — actually, `MessageCanvas` is a `ZStack` containing the scroll view and the jump-to-latest button. The `safeAreaInset` modifier on `MessageCanvas` will apply to its content scroll area. But `MessageCanvas` isn't itself a `ScrollView` — it's a `ZStack` containing a `ScrollViewReader > ScrollView`. Per Apple docs, `safeAreaInset` modifies the safe area of the modified view. When applied to a view containing a `ScrollView`, the scroll view's content inset adjusts. This should work correctly since the `ScrollView` is the primary layout child.

5. **Keyboard avoidance:** `safeAreaInset` interacts with the keyboard on macOS. When the Composer's `ChatField` gets focus, macOS may show a keyboard (for external keyboards, this is a no-op, but for on-screen scenarios, this matters). The `safeAreaInset` approach actually handles this better than the VStack approach, because the scroll content area shrinks to accommodate both the keyboard AND the composer.

6. **`resetIndicator` placement:** The `ZStack(alignment: .top)` wrapping `MessageCanvas + resetIndicator` is at the `MainWindow` level. The `safeAreaInset` needs to be on the view that contains the `ScrollView`. Since `resetIndicator` overlays on top, it should be inside the `safeAreaInset`'s target view, or more likely, it stays where it is (it's a top overlay, not affected by bottom inset).

   Actually, looking more carefully: `resetIndicator` is inside a `ZStack(alignment: .top)` with `MessageCanvas`. If we put `safeAreaInset` on `MessageCanvas`, the `ZStack` still works — the `resetIndicator` just overlays the top. The bottom inset is for the Composer. This is fine.

**Recommendation:** Implement, but test thoroughly:
- Composer expands from 1 to multiple lines
- Keyboard show/hide (if applicable)
- Message canvas scroll position when Composer height changes
- Topic switching with Composer expanded

---

## Cross-Fix Interaction Analysis

| Interaction | Concern | Verdict |
|---|---|---|
| Fix 1 + Fix 2 together | Both remove `scrollToBottom` calls. Only remaining programmatic scrolls are: `onAppear`, topic switch, and "Jump to Latest" button. This is exactly the Telegram pattern. | ✅ Safe |
| Fix 1 + Fix 5 | Per-topic thinking state means `onChange(of: messages.count)` won't fire spuriously from background topics anyway (different `messages` array). | ✅ Reinforces |
| Fix 3 + Fix 7 | Both change the layout hierarchy around `MessageCanvas`. Fix 3 adds a `GeometryReader` wrapper. Fix 7 adds `safeAreaInset`. These compose — the GeometryReader measures the available width, and `safeAreaInset` adjusts the safe area. No conflict. | ✅ Safe |
| Fix 4 + Fix 6 | Both reduce SwiftUI recomputation during streaming. TimelineView removes per-frame invalidation. 150ms poll reduces update frequency. Compound benefit. | ✅ Synergistic |
| Fix 2 + Fix 5 | With per-topic `thinkingState`, the `.thinking` transition only fires for the active topic. Removing the scroll call from that handler is even safer since it won't fire for background topics at all. | ✅ Reinforces |

---

## Overall Recommendation

**Implement in the spec's suggested order: Fix 1 + Fix 2 first, then Fix 7, then Fix 3–5, then Fix 6.**

All seven fixes are implementable. The two AMBER ratings (Fix 3 and Fix 4) are about visual/cosmetic differences (GeometryReader layout, cursor blink vs fade) that need verification but aren't blockers. Fix 7 needs the most careful testing due to the layout restructure.

**Priority for testing:**
1. Send message while at bottom → no whitespace, no bounce
2. Send message, type multi-line in Composer → no whitespace jump
3. Watch Topic A while Topic B streams → no bounce on A
4. Switch to streaming Topic B → correct scroll position
5. "Jump to Latest" button still works
6. Load earlier messages → scroll position preserved
7. Thinking indicator appears without scroll jump

**One thing the spec doesn't address:** The `resetIndicator` overlay sits inside a `ZStack(alignment: .top)` with `MessageCanvas`. When `safeAreaInset` is applied, verify that this overlay isn't clipped or displaced. It should be fine since it's positioned at `.top`, but worth checking.

**Minor cleanup the spec missed:**
- In `StreamingBubble.swift`, the `@State private var cursorVisible = false` and `.onAppear { cursorVisible = true }` should be removed when Fix 4 is implemented (they become dead code).
- In `MessageCanvas.swift`, after Fix 3, the `WidthPreferenceKey` struct can be removed if no other view reads it.

---

*Q — ready to implement.*