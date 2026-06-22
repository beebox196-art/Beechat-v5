# BC5-KR-001 Kieran Review: Blank White Space on Topic Switch

**Date:** 2026-05-08  
**Reviewer:** Kieran (Independent Safety Review)  
**Spec:** BC5-SPEC-005  
**Status:** REVIEW COMPLETE — Root cause identified, fix recommended

---

## Summary

The blank space issue is **not** caused by a single factor. It's a compound effect of three interacting problems:

1. **The 120pt bottom anchor is necessary but not the main culprit** — it adds scroll space, but 120pt alone can't produce "two screens" of blank space.
2. **The animated `scrollToBottom` on topic switch is the primary driver** — `scrollToBottom(animated: true)` fires immediately on `onChange(of: topicId)`, but the new topic's messages haven't arrived yet. The scroll targets the `bottom-anchor` which is sitting at the bottom of an *empty* `LazyVStack`. Then the 200ms fallback fires again, also targeting the same empty anchor. By the time messages actually arrive, the scroll position is already locked at the bottom of the empty content area, and the messages load *above* the visible viewport.
3. **`MessageListObserver` clears messages before new ones arrive** — `startObserving()` sets `self.messages = []` immediately, so there's a window where the canvas is rendering an empty `LazyVStack` with only the 120pt anchor visible.

The combination means: user switches topic → messages clear → scroll fires to bottom-anchor (which is alone in an empty stack) → messages arrive later but are above the viewport → user sees blank white space below where messages should be.

---

## Detailed Analysis

### 1. The 120pt Bottom Anchor

**File:** `MessageCanvas.swift`, lines ~77-92

```swift
Color.clear
    .frame(height: 120)
    .id("bottom-anchor")
    .onAppear { ... }
    .onDisappear { ... }
```

**Assessment:** The 120pt height is contributing but not the primary cause. Here's why:

- 120pt is ~1/3 of a typical screen height on macOS. The spec says "two screen heights" of blank space — that's ~1800pt. 120pt alone cannot account for this.
- The anchor serves a legitimate purpose: it provides a stable scroll target and drives the `isAtBottom` detection via `onAppear`/`onDisappear`.
- **However**, the height is excessive. A 1pt anchor would work just as well for scroll targeting. The `onAppear`/`onDisappear` hysteresis is already handled by the 100ms/50ms debounce timers — the physical height of the anchor doesn't need to be 120pt for that to work.

**Recommendation:** Reduce to 1pt. The debounce timers handle the hysteresis; the anchor doesn't need to be tall. This eliminates a small but unnecessary scroll-space contribution.

**Confidence:** High

---

### 2. StreamingBubble / ThinkingBee Collapse

**File:** `MessageCanvas.swift`, lines ~55-68

```swift
if thinkingState == .thinking {
    ThinkingBeeIndicator(mode: .thinking)
        .id("thinking-bee")
} else if isStreaming && streamingContent.isEmpty {
    if thinkingState != .streaming {
        TypingIndicator()
            .id("typing-indicator")
    }
} else if showStreamingBubble {
    StreamingBubble(content: streamingContent)
        .id("streaming-bubble")
}
```

**Assessment:** These views are conditionally rendered — when their conditions become false, they are removed from the view tree entirely. In SwiftUI, a removed view from a `LazyVStack` should release its layout space immediately.

**Potential issue:** If `StreamingBubble` has internal animations (opacity fades, slide transitions) that persist after the view is removed from the tree, those could theoretically leave residual space. But without seeing the `StreamingBubble` implementation, I can only flag this as a *low-probability* secondary factor.

**More importantly:** When a topic switch happens, `MessageListObserver.startObserving()` sets `self.messages = []` and `self.allMessages = []`. The `MessageCanvas` receives an empty `messages` array. At this point:
- `thinkingState` may still be `.thinking` from the *previous* topic (the `SyncBridgeObserver` hasn't updated yet for the new topic).
- `isStreaming` may still be `true` from the previous topic.
- `showStreamingBubble` may still be `true`.

This means the canvas could briefly render a `StreamingBubble` or `ThinkingBeeIndicator` *on top of an empty message list* for the new topic, before the sync bridge observer updates. This would add height to the empty stack.

**Recommendation:** When `topicId` changes, the streaming/thinking state should be reset to `.idle`/`false` immediately, before the new topic's data arrives. This prevents ghost streaming indicators from the previous topic.

**Confidence:** Moderate — depends on `StreamingBubble` internals and the timing of `SyncBridgeObserver` updates relative to `MessageListObserver` clearing.

---

### 3. Topic Switch Flow — Message List Replacement

**Files:** `MessageListObserver.swift` + `MessageViewModel.swift` + `MessageCanvas.swift`

**The flow:**

1. User selects a new topic in the sidebar
2. `MainWindow` calls `messageViewModel.selectTopic(id: id)`
3. `selectTopic()` calls `startObservationForSelectedTopic()`
4. `startObservationForSelectedTopic()` sees the session key changed, calls `messageListObserver.startObserving(syncBridge: sessionKey: newKey)`
5. `startObserving()` **immediately** sets `self.messages = []`, `self.allMessages = []`, `self.messageLimit = 25`
6. The `MessageCanvas` receives `messages = []` — the `LazyVStack` now has zero message bubbles
7. `MessageCanvas.onChange(of: topicId)` fires — sets `isAtBottom = true`, calls `scrollToBottom(animated: true)`
8. `scrollToBottom` scrolls to `"bottom-anchor"` — but the only thing in the stack is the 120pt anchor
9. Meanwhile, the gateway stream starts delivering messages for the new topic
10. Messages arrive and are set via `setAllMessages()` → `applyWindow()` → `messages = windowed`
11. `onChange(of: messages.count)` fires — but `isAtBottom` is `true` (set in step 7), so it calls `scrollToBottom(animated: false)`

**The problem:** Step 7-8 happen *before* step 9-10. The scroll targets an empty stack. When messages arrive in step 9-10, they appear *above* the current scroll position (because the scroll position is already at the bottom of the empty content). The `onChange(of: messages.count)` handler in step 11 does call `scrollToBottom(animated: false)`, which should fix it — but there's a race condition:

- The `scrollToBottom(animated: true)` from step 7 has a 200ms fallback (line ~126)
- The `onChange(of: messages.count)` fires when messages arrive
- If the 200ms fallback fires *after* the messages have arrived, it will scroll to the bottom-anchor again — which is now at the bottom of the *new* messages. This should be correct.
- **But** the animated scroll from step 7 uses `DispatchQueue.main.async` + `withAnimation(.easeInOut(duration: 0.2))`. The animation takes 200ms. During that animation, the scroll position is transitioning. If messages arrive mid-animation, the final scroll position may not be where we expect.

**Worse:** The `scrollToBottom(animated: true)` in the `onChange(of: topicId)` handler uses `scrollProxy` which is captured in `onAppear`. But `scrollProxy` is set once and never re-validated. If the `ScrollViewReader` has been recreated (which it shouldn't be on topic switch, but SwiftUI can be unpredictable), the proxy could be stale.

**Recommendation:** The `onChange(of: topicId)` handler should use `scrollToBottom(animated: false)` instead of `true`. The animated scroll on topic switch is unnecessary (the user just clicked a new topic — they expect an instant reset, not a smooth scroll). More importantly, `false` avoids the 200ms animation + 200ms fallback race entirely.

**Confidence:** High — this is the primary root cause.

---

### 4. scrollToBottom on Topic Switch — Overshoot Analysis

**File:** `MessageCanvas.swift`, lines ~115-132

```swift
.onChange(of: topicId) { _, newId in
    if newId != nil {
        isAtBottom = true
        lastScrollTime = .distantPast
        scrollToBottom(animated: true)
    }
}
```

And `scrollToBottom`:

```swift
private func scrollToBottom(animated: Bool = false) {
    guard let proxy = scrollProxy else { return }
    // ... dedup logic for streaming ...
    
    if animated {
        DispatchQueue.main.async { [proxy] in
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
        // Fallback for LazyVStack layout timing on topic switch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [proxy] in
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    } else {
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    }
}
```

**The overshoot mechanism:**

When `animated: true`:
1. `DispatchQueue.main.async` queues the animated scroll for the next runloop
2. `withAnimation(.easeInOut(duration: 0.2))` starts a 200ms animation
3. `proxy.scrollTo("bottom-anchor", anchor: .bottom)` animates to the anchor
4. 200ms later, the fallback fires: `proxy.scrollTo("bottom-anchor", anchor: .bottom)` — this time **non-animated**

**The problem:** At step 1-3, the `LazyVStack` is empty (messages cleared in step 5 of the flow above). The `bottom-anchor` is the only content. The scroll position goes to the bottom of the empty stack. At step 4 (200ms later), the fallback fires — but messages may or may not have arrived yet. If they have, the fallback correctly scrolls to the new bottom. If they haven't, the fallback re-confirms the scroll to the empty bottom.

**Then messages arrive**, and `onChange(of: messages.count)` fires:
```swift
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        // ... (not applicable here)
    } else if isAtBottom || isUserMessage || isStreaming {
        scrollToBottom(animated: false)
    }
}
```

`isAtBottom` is `true` (set in the `onChange(of: topicId)` handler), so `scrollToBottom(animated: false)` fires. This should scroll to the bottom of the *new* content. **This should work.**

So why is there still blank space?

**My diagnosis:** The issue is that `scrollToBottom(animated: false)` in the `onChange(of: messages.count)` handler fires *during* the message array update. SwiftUI may not have yet laid out the new message views in the `LazyVStack` at the moment `proxy.scrollTo()` is called. The proxy scrolls to the `bottom-anchor`, but the message views above it haven't been measured yet. So the scroll position is correct (at the anchor), but the content above hasn't been laid out, and the visible viewport shows the anchor area (blank) rather than the messages.

The 200ms fallback in the animated path was intended to handle exactly this — "LazyVStack layout timing on topic switch." But it only fires in the `animated: true` path, and it fires 200ms after the *initial* animated scroll, not after the messages arrive.

**Recommendation:** 
- Change `onChange(of: topicId)` to use `scrollToBottom(animated: false)` — removes the animation + fallback race.
- Add a small delayed re-scroll in the `onChange(of: messages.count)` handler when the count changes from 0 to >0 (i.e., on topic switch):

```swift
.onChange(of: messages.count) { _, newCount in
    if let anchorId = anchorMessageId {
        // ... existing ...
    } else if isAtBottom || isUserMessage || isStreaming {
        scrollToBottom(animated: false)
        // If this is a fresh load (topic switch), re-scroll after layout settles
        if newCount > 0 && wasEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                scrollToBottom(animated: false)
            }
        }
    }
}
```

**Confidence:** High — this addresses the LazyVStack layout timing issue directly.

---

## Root Cause Summary

| Factor | Contribution | Severity |
|--------|-------------|----------|
| `scrollToBottom(animated: true)` on topic switch | Primary — fires before messages arrive, animation + fallback race | High |
| `MessageListObserver` clears messages before new ones load | Enables the empty-stack condition | Medium |
| 120pt bottom anchor | Minor — adds scroll space but not enough to explain "two screens" | Low |
| StreamingBubble/ThinkingBee ghost state | Possible — if previous topic's streaming state persists | Low-Medium |
| LazyVStack layout timing | Secondary — `scrollTo` may fire before new views are measured | Medium |

---

## Recommended Fix (Priority Order)

1. **Change `onChange(of: topicId)` to `scrollToBottom(animated: false)`** — eliminates the animation race. This is the single highest-impact change.

2. **Add a 150ms delayed re-scroll on message count change from 0→N** — handles LazyVStack layout timing.

3. **Reset streaming/thinking state on topic switch** — prevent ghost indicators. This can be done by having `MessageListObserver.startObserving()` also signal the UI to reset streaming state, or by having `MessageCanvas` watch `topicId` and reset local streaming-related state.

4. **Reduce bottom anchor from 120pt to 1pt** — eliminates unnecessary scroll space. The debounce timers handle the hysteresis.

---

## Risk Assessment

All four recommended changes are **low-risk, reversible, and isolated**:

- Change 1 is a single parameter change (`true` → `false`)
- Change 2 adds a small delay only on the 0→N transition (topic switch)
- Change 3 is a state reset that should happen anyway
- Change 4 is a frame height change (120 → 1)

None require architectural changes. All can be tested independently.

---

## Conclusion

The blank space is a **timing issue**, not a layout bug. The animated scroll fires into an empty stack, and the layout timing of LazyVStack means the scroll position lands before the new content is measured. The fix is to use non-animated scrolls on topic switch and add a small layout-settle delay after messages arrive.

**Confidence in diagnosis:** High  
**Estimated fix effort:** 15-30 minutes  
**Regression risk:** Low
