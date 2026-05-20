# Scroll Bounce & Whitespace Remediation Spec

**Date:** 2026-05-19  
**Status:** APPROVED — Team review complete (Q: GREEN/AMBER, Kieran: APPROVE WITH CONDITIONS). Conditions incorporated below.  
**Author:** Bee (coordinator)  
**Priority:** HIGH — Recurring UX regression affecting daily use

---

## Problem Statement

Two persistent UI bugs in BeeChat macOS that keep regressing:

1. **Whitespace intrusion:** Large blank space appears in the message canvas, pushing the view focus point several screens down. Adam has observed this correlates with text entry in the Composer — specifically when typing into a second line, the whitespace appears, then sometimes self-corrects.

2. **Scroll bounce:** While waiting for a message response, the message canvas bounces/jumps. This happens on each topic when a response is streaming on another topic.

Neither issue occurs in standard macOS chat apps (Telegram, Discord, Messages). Something in our implementation is fighting the natural scroll behaviour that SwiftUI provides out of the box.

---

## Root Cause Analysis

After reviewing the current codebase (`MessageCanvas.swift`, `Composer.swift`, `MainWindow.swift`, `StreamingBubble.swift`, `SyncBridgeObserver.swift`), here are the identified contributing factors:

### Issue 1: Whitespace / Focus Jumping

**Primary suspect: Composer height changes trigger ScrollView content size recalculation, which `defaultScrollAnchor(.bottom)` misinterprets.**

The flow:
1. User types in Composer, text wraps to second line
2. Composer expands (`.fixedSize(horizontal: false, vertical: true)` + `maxHeight: 160`)
3. The VStack containing MessageCanvas + Composer re-layouts
4. MessageCanvas's `ScrollView(.vertical)` content height shrinks (less vertical space for messages)
5. SwiftUI recalculates scroll position — `defaultScrollAnchor(.bottom)` tries to stay at bottom but the content offset shifts
6. A gap appears at the top of the scroll content, or the scroll target overshoots

**Contributing factors:**

- **`onChange(of: messages.count)` calls `scrollToBottom` on every new message**, including during streaming. The comment says "Do NOT force scroll on user message" but the code still calls `scrollToBottom(proxy: proxy, animated: false)` when `isAtBottom == true`. During streaming, this fires every time a message is persisted (streaming chunks can create intermediate message saves).

- **`onChange(of: thinkingState)` also calls `scrollToBottom`** — this fires when `.idle` → `.thinking`, which is the exact moment the user sends a message and the Composer is still expanded.

- **`WidthReader` / `GeometryReader` inside ScrollView** — The `WidthReader` with `GeometryReader` is a known SwiftUI layout trap. GeometryReader is greedy and can cause unexpected size proposals, particularly inside a `LazyVStack` within a `ScrollView`.

- **StreamingBubble with cursor animation** — The blinking cursor `Text("▌")` with `.repeatForever` animation causes continuous view invalidation. Each animation frame triggers SwiftUI to reconsider layout, which can cause the scroll position to jitter.

### Issue 2: Cross-Topic Scroll Bounce

**Primary suspect: Streaming state changes on background topics invalidate ALL observed `@Observable` properties, triggering SwiftUI re-renders across topics.**

The flow:
1. User is on Topic A, Topic B is streaming
2. `SyncBridgeObserver` is `@Observable` — every `streamingContent` update (every 50ms poll) mutates state
3. SwiftUI detects `SyncBridgeObserver` changed → re-renders the MainWindow detail area
4. MessageCanvas's `onChange(of: thinkingState)` fires even though the current topic isn't the one streaming
5. This triggers unnecessary `scrollToBottom` calls and layout recalculation

**Contributing factors:**

- **`SyncBridgeObserver` is a single monolithic `@Observable`** — any property change (streaming content, agent activity, etc.) causes SwiftUI to re-evaluate any view that reads ANY property from it. This is the "observation granularity" problem.

- **`onChange(of: thinkingState)`** fires on the active topic's canvas even when the thinking state change came from a background topic. The `thinkingState` is a single value, not per-topic.

- **`startStreamingPoll()` at 50ms intervals** creates extremely frequent state mutations. Even with the diff guard (`if self.streamingContent != content`), content changes on every poll during active streaming, causing 20 state mutations per second.

- **`scrollToBottom` debounce of 150ms** is insufficient during streaming — at 50ms poll intervals, every other update bypasses the debounce, creating an uneven scroll experience.

---

## Remediation Plan

### Fix 1: Eliminate Forced Scroll-To-Bottom During Streaming (HIGH PRIORITY)

**File:** `MessageCanvas.swift`

**Current behaviour:** `onChange(of: messages.count)` calls `scrollToBottom` when `isAtBottom == true`. During streaming, messages may be persisted multiple times, and intermediate states trigger scroll jumps.

**Fix:** Remove the `scrollToBottom` call from `onChange(of: messages.count)` when content fills the viewport. Rely on `defaultScrollAnchor(.bottom)` for maintaining scroll position during streaming. This is how Telegram and Discord work — they use `defaultScrollAnchor` and never programmatically scroll during content growth.

```swift
// BEFORE (MessageCanvas.swift, onChange(of: messages.count)):
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(anchorId, anchor: .top)
        }
        anchorMessageId = nil
    } else if pendingTopicScroll {
        pendingTopicScroll = false
        scrollToBottom(proxy: proxy, animated: true)
    } else if isAtBottom {
        scrollToBottom(proxy: proxy, animated: false)
    }
}

// AFTER:
.onChange(of: messages.count) { _, _ in
    if let anchorId = anchorMessageId {
        withAnimation(.easeInOut(duration: 0.15)) {
            proxy.scrollTo(anchorId, anchor: .top)
        }
        anchorMessageId = nil
    } else if pendingTopicScroll {
        pendingTopicScroll = false
        scrollToBottom(proxy: proxy, animated: true)
    }
    // REMOVED: else if isAtBottom { scrollToBottom }
    // defaultScrollAnchor(.bottom) handles this automatically when content fills the viewport.
    // Forced scrollTo during streaming causes bounce/whitespace.
    // See Fix 1A for the short-content fallback.
}
```

**Rationale:** `defaultScrollAnchor(.bottom)` already keeps the scroll pinned to the bottom when new content is added. Explicit `scrollTo` during streaming creates a race condition between SwiftUI's layout engine and the scroll proxy, causing bounce. The only times we need explicit scroll are: (1) topic change, (2) load earlier messages, (3) user taps "Jump to latest", (4) short-content fallback (Fix 1A).

### Fix 1A: Short-Content Fallback Scroll (HIGH PRIORITY — Kieran Finding 1)

**File:** `MessageCanvas.swift`

**Problem:** `defaultScrollAnchor(.bottom)` is ignored by macOS when scroll content is shorter than the viewport. Content aligns to the top with blank space below — visually identical to the whitespace bug.

**Fix:** Track whether content fills the container in `onScrollGeometryChangeCompat`, and force-scroll to bottom when it doesn't.

```swift
// Add new @State:
@State private var contentFillsContainer: Bool = false

// In onScrollGeometryChangeCompat, after computing isAtBottom:
let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
contentFillsContainer = geo.contentSize.height >= geo.containerSize.height

// New onChange for short-content fallback:
.onChange(of: messages.count) { _, _ in
    // ... existing anchorMessageId / pendingTopicScroll logic ...

    // Short-content fallback: when messages don't fill the viewport,
    // defaultScrollAnchor(.bottom) is ignored by macOS.
    // Force-scroll to keep content at the bottom of the visible area.
    if !contentFillsContainer {
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```

**Important:** This scroll is safe because when content is short, there's no streaming race condition — the content size isn't rapidly changing. The force-scroll only fires in the short-content case, which is the one scenario where `defaultScrollAnchor` doesn't work.

### Fix 2: Remove ThinkingState onChange Scroll Side-Effect (HIGH PRIORITY)

**File:** `MessageCanvas.swift`

**Current behaviour:** `onChange(of: thinkingState)` calls `scrollToBottom` when transitioning to `.thinking`. This fires at the exact moment the user has just sent a message, when Composer height may be changing.

```swift
// BEFORE:
.onChange(of: thinkingState) { oldState, newState in
    BeeChatLogger.log("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
    if newState == .thinking && isAtBottom {
        scrollToBottom(proxy: proxy, animated: false)
    }
}

// AFTER:
.onChange(of: thinkingState) { oldState, newState in
    BeeChatLogger.log("[ThinkingBee] MessageCanvas: thinkingState changed \(oldState) → \(newState)")
    // REMOVED: scrollToBottom on .thinking
    // defaultScrollAnchor(.bottom) handles staying at bottom.
    // Explicit scroll here causes bounce when Composer height is changing.
}
```

### Fix 3: Move WidthReader Outside ScrollView (MEDIUM PRIORITY)

**File:** `MessageCanvas.swift`

**Current behaviour:** `WidthReader` (GeometryReader) is placed inside the ScrollView as a background, causing it to participate in the scroll content's layout. GeometryReader is greedy and proposes maximum size to its children, which can cause content size miscalculations.

**Fix:** Measure width at the `ZStack` level (outside the ScrollView), not inside it.

```swift
// BEFORE:
ScrollViewReader { proxy in
    ScrollView(.vertical, showsIndicators: true) {
        LazyVStack(spacing: 0) {
            // ... messages ...
        }
    }
    .background(
        WidthReader { width in
            Color.clear
                .preference(key: WidthPreferenceKey.self, value: width)
        }
    )
}

// AFTER:
GeometryReader { geometry in
    let measuredWidth = geometry.size.width
    
    ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                // ... messages ...
            }
        }
        // ... rest of scroll modifiers ...
    }
    .environment(\.canvasWidth, measuredWidth)
}
```

**Rationale:** GeometryReader inside ScrollView content is a well-known SwiftUI anti-pattern. Moving it outside eliminates greedy size proposals within the scroll content, and prevents the width measurement from interfering with content height calculations.

### Fix 4: Eliminate Streaming Cursor Animation (MEDIUM PRIORITY)

**File:** `StreamingBubble.swift`

**Current behaviour:** Blinking cursor `Text("▌")` with `.repeatForever` animation causes continuous layout invalidation during streaming, which cascades into scroll position recalculation.

```swift
// BEFORE:
Text("▌")
    .font(themeManager.font(.body))
    .foregroundColor(themeManager.color(.accentPrimary))
    .opacity(cursorVisible ? 1 : 0)
    .animation(themeManager.animation(.slow).repeatForever(autoreverses: true), value: cursorVisible)
```

**Fix:** Use `TimelineView` for the cursor blink, which doesn't trigger SwiftUI layout invalidation:

```swift
// AFTER:
TimelineView(.periodic(from: .now, by: 1.0)) { timeline in
    let blink = Int(timeline.date.timeIntervalSince1970) % 2 == 0
    Text("▌")
        .font(themeManager.font(.body))
        .foregroundColor(themeManager.color(.accentPrimary))
        .opacity(blink ? 1 : 0)
}
```

**Rationale:** `TimelineView` uses a coalesced display link that doesn't invalidate the view's layout. The `.animation(.repeatForever)` pattern creates an implicit animation transaction that re-evaluates on every frame, fighting the scroll layout engine.

### Fix 5: Per-Topic Streaming State (MEDIUM PRIORITY — addresses cross-topic bounce)

**File:** `SyncBridgeObserver.swift`, `MainWindow.swift`, `MessageCanvas.swift`

**Current behaviour:** `thinkingState` is a single value on `SyncBridgeObserver`. When Topic B is streaming and Topic A is displayed, the `.thinking` / `.streaming` state change triggers `MessageCanvas` re-render and potential scroll disruption on the wrong topic.

**Fix:** Make `MessageCanvas` only observe streaming state relevant to its own topic, not the global `thinkingState`.

In `MainWindow.swift`, we already compute `isActiveTopicStreaming` correctly:

```swift
let isActiveTopicStreaming = syncBridgeObserver.isStreaming
    && syncBridgeObserver.streamingSessionKey == messageViewModel.selectedTopic?.sessionKey
let activeTopicStreamingContent = isActiveTopicStreaming
        ? syncBridgeObserver.streamingContent : ""
```

But `MessageCanvas` also receives `thinkingState` from `SyncBridgeObserver.thinkingState`, which is global. Change to pass only the relevant state:

```swift
// MainWindow.swift — compute per-topic thinking state
let topicThinkingState: ThinkingState = isActiveTopicStreaming
    ? syncBridgeObserver.thinkingState
    : .idle

MessageCanvas(
    messages: messageViewModel.messages,
    isStreaming: isActiveTopicStreaming,
    streamingContent: activeTopicStreamingContent,
    thinkingState: topicThinkingState,  // per-topic, not global
    ...
)
```

**Rationale:** This is already partially done for `isStreaming` and `streamingContent`. Extending to `thinkingState` prevents cross-topic state changes from triggering `onChange` handlers on the wrong canvas.

### Fix 6: Reduce Streaming Poll Frequency (LOW PRIORITY)

**File:** `SyncBridgeObserver.swift`

**Current behaviour:** `startStreamingPoll()` polls every 50ms (20fps). Each content change triggers SwiftUI invalidation on the entire `SyncBridgeObserver` observable.

**Fix:** Increase to 150ms (≈7fps). Streaming text updates at 7fps are visually smooth for humans and reduce SwiftUI recomputation by 3×.

```swift
// BEFORE:
try await Task.sleep(nanoseconds: 50_000_000)  // 50ms

// AFTER:
try await Task.sleep(nanoseconds: 150_000_000)  // 150ms
```

**Note:** If the gateway already pushes content via WebSocket events (rather than requiring polling), this entire poll mechanism should be replaced with event-driven updates. Polling is a workaround for streaming content not being delivered via the observer pattern.

### Fix 7: Composer Height Isolation (LOW PRIORITY — addresses whitespace on multi-line entry)

**File:** `MainWindow.swift`, `Composer.swift`

**Current behaviour:** When the Composer expands from 1 line to 2+ lines, the VStack containing both MessageCanvas and Composer redistributes space. This causes MessageCanvas's content size to change, which can shift the scroll position.

**Fix:** Give the Composer a fixed bottom position and let it overlay the MessageCanvas. The canvas should always extend to the full height, with the Composer floating on top of the bottom edge.

```swift
// BEFORE (MainWindow.swift detail area):
VStack(spacing: 0) {
    GatewayStatusBar(...)
    Divider()
    MessageCanvas(...)
    Divider()
    Composer(...)
}

// AFTER:
ZStack(alignment: .bottom) {
    VStack(spacing: 0) {
        GatewayStatusBar(...)
        Divider()
        MessageCanvas(...)
            .safeAreaInsetEdge(.bottom)  // Reserve space for composer
    }
    Composer(...)
        .background(themeManager.color(.bgSurface))
}
```

**Wait — `safeAreaInsetEdge` is the better approach.** It's SwiftUI's built-in mechanism for this exact pattern (keyboard-like inset views). The scroll content insets automatically without layout fights.

```swift
// PREFERRED approach:
MessageCanvas(...)
    .safeAreaInset(edge: .bottom) {
        VStack(spacing: 0) {
            Divider()
            Composer(viewModel: composerViewModel, onSend: composerSend)
        }
        .background(themeManager.color(.bgSurface))
    }
```

**Rationale:** This is exactly how Apple recommends composing a scroll view with an input bar (see: Messages app, Telegram). The scroll content area is inset by the composer height, and SwiftUI manages the adjustment automatically without triggering content-size-change scroll jumps.

---

## Team Review Conditions (Incorporated)

Two conditions from Kieran's adversarial review have been incorporated:

1. **Short-content fallback (Kieran Finding 1):** `defaultScrollAnchor(.bottom)` does NOT work when scroll content is shorter than the viewport (0–2 short messages). Content aligns to the top with blank space below — looks like the whitespace bug. Fix 1 now includes a fallback: force-scroll only when content height < container height. See Fix 1A below.

2. **Fix 7 promoted to HIGH priority (Kieran Finding 7):** The whitespace during text entry is Adam's primary pain point, and it's ONLY fixed by `safeAreaInset`. Moved to first implementation batch.

## Implementation Order

| # | Fix | Priority | Risk | Files |
|---|-----|----------|------|-------|
| 1 | Remove forced scrollToBottom from `onChange(of: messages.count)` | HIGH | Low — removes code | `MessageCanvas.swift` |
| 1A | Short-content fallback scroll | HIGH | Low — conditional scroll | `MessageCanvas.swift` |
| 2 | Remove scrollToBottom from `onChange(of: thinkingState)` | HIGH | Low — removes code | `MessageCanvas.swift` |
| 7 | Use `safeAreaInset(edge: .bottom)` for Composer | HIGH | Medium — layout restructure | `MainWindow.swift` |
| 3 | Move WidthReader outside ScrollView | MEDIUM | Medium — layout change | `MessageCanvas.swift` |
| 4 | Replace cursor animation with TimelineView | MEDIUM | Low — isolated change | `StreamingBubble.swift` |
| 5 | Per-topic thinkingState | MEDIUM | Medium — data flow change | `MainWindow.swift`, `MessageCanvas.swift` |
| 6 | Increase streaming poll to 150ms | LOW | Minimal | `SyncBridgeObserver.swift` |

**Implementation batches:**
- **Batch 1 (HIGH):** Fix 1 + Fix 1A + Fix 2 + Fix 7. These address Adam's two pain points directly. Build, test, verify before proceeding.
- **Batch 2 (MEDIUM):** Fix 3 + Fix 4 + Fix 5. These reduce unnecessary recomputation and improve cross-topic isolation.
- **Batch 3 (LOW):** Fix 6. Simple tuning change.

**Critical principle:** Each batch must be tested before the next batch starts. We are NOT layering patches — we are removing interference with SwiftUI's natural scroll behaviour. Every chat app that works smoothly (Telegram, Discord, Messages) uses `defaultScrollAnchor(.bottom)` + minimal programmatic scroll. We should do the same.

**Rollback plan:** Before implementation, create a git branch `fix/scroll-remediation` from current HEAD. Tag the branch point as `PRE-SCROLL-REMEDIATION`. If any batch causes regression, revert to the tag.

---

## What NOT To Do

Based on the recurring pattern of fixes that keep regressing:

1. **Don't add more programmatic scroll calls.** Every `scrollToBottom` during streaming is a potential bounce trigger. The correct fix is to REMOVE them, not add more.

2. **Don't add animation to scroll during streaming.** `withAnimation` on `scrollTo` during active content growth creates visible bounce. The scroll position should be managed by `defaultScrollAnchor` only.

3. **Don't use `GeometryReader` inside scroll content.** It's greedy and causes content-size miscalculation. Measure outside, pass in via environment.

4. **Don't add more debouncing/throttling.** The 150ms debounce is a band-aid. The real fix is not calling scrollTo at all during streaming.

5. **Don't add `scrollPosition` binding (iOS 18+/macOS 15+) as a "fix".** It's useful for programmatic control, but the root cause here is too MUCH programmatic control, not too little.

---

## Verification Checklist

After implementing each fix, verify:

- [ ] Messages appear smoothly without bouncing during streaming
- [ ] Scrolling up during streaming keeps position (no forced scroll-to-bottom)
- [ ] "Jump to latest" button appears when scrolled up and scrolls to bottom correctly
- [ ] Typing multi-line messages in Composer does NOT cause whitespace or focus jumps
- [ ] Switching topics scrolls to bottom of new topic correctly
- [ ] Cross-topic streaming (watching Topic A while Topic B streams) does NOT cause bounce on Topic A
- [ ] Thinking indicator appears without scroll disruption
- [ ] Streaming bubble grows smoothly without bounce
- [ ] Load earlier messages preserves scroll position (anchor on oldest visible message)

---

## Comparison: How Telegram Does It

Telegram macOS (SwiftUI) uses:
- `ScrollView` + `LazyVStack` with `defaultScrollAnchor(.bottom)`
- No `GeometryReader` inside scroll content
- No programmatic `scrollTo` during streaming content growth
- `scrollTo` only for: initial load, topic switch, "jump to bottom" button tap
- Input bar uses `.safeAreaInsetEdge(.bottom)` for keyboard-like behaviour
- Streaming text uses `TimelineView` for cursor animation

Our target is to match this pattern. The fixes above bring us into alignment.

---

*This spec is for Q to implement and Kieran to review. No direct code changes by Bee.*