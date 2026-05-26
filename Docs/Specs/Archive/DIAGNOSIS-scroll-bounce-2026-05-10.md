# DIAGNOSIS: Scroll Bounce — Why Our Fixes Made It Worse

**Date:** 2026-05-10  
**Author:** Bee  
**Status:** Diagnosis only — no code changes until Adam decides  

---

## The Problem

Each round of scroll fixes has made the bounce worse, not better. The app was actually more stable before we started patching.

## Git History Tells the Story

| Commit | What it did | Effect |
|---|---|---|
| `696b33a` | **Original** — simple `scrollTo("bottom-anchor")` with animation, three `onChange` handlers, no dedup, no conditional targets, no asyncAfter | Worked. Simple. |
| `48a6783` | Added dedup guard (0.3s), `scrollProxy` state, animated/non-animated split, `asyncAfter(0.5)` | Introduced double-scroll |
| `5358a38` | Replaced `onAppear`/`onDisappear` with debounced Task-based detection | More complex, same bounce |
| `b40e9db` | Reduced anchor height, deferred scroll, targeted last message | Still bouncing |
| **Our Fix D** | Conditional bounce behaviour, conditional scroll targets, removed `onChange(showStreamingBubble)`, removed `asyncAfter` | **Worse than all of the above** |

## Why It's Worse Now

Our Fix D made two critical mistakes:

### 1. `.scrollBounceBehavior(.automatic)` during streaming

We changed from `.basedOnSize` to `.automatic` during streaming. But `.automatic` means "use the platform default" — on macOS, that's **always allow bounce**. `.basedOnSize` (the original) only bounces when content exceeds the viewport. So we **increased** bounce, not decreased it.

The entire premise of this change was wrong. We wanted `.never` (suppress bounce entirely) but that doesn't exist in SwiftUI. The closest thing is `.basedOnSize`, which was already what the code had before we touched it.

### 2. Targeting `"streaming-bubble"` instead of `"bottom-anchor"`

When `scrollTo("streaming-bubble", anchor: .bottom)` fires, the streaming bubble is **growing every 50ms**. Each time it grows, SwiftUI re-layouts, and the scroll position recalculates. Scrolling to the middle of a growing element means the scroll target keeps shifting — that's the bounce.

The original code always scrolled to `"bottom-anchor"` — a fixed 1px spacer that never moves. The scroll target was stable. By changing the target to the streaming bubble, we made the target itself unstable.

### 3. Removing `onChange(of: showStreamingBubble)`

This removed a necessary scroll trigger. When the streaming bubble first appears (empty → has content), something needs to scroll to it. The original code had this handler and it worked. Removing it means the first chunk of streaming content may not trigger a scroll at all.

## What Was Actually Wrong With the Original

Looking at the original `696b33a` code, it was simple and mostly worked. The problems were:

1. **White space on topic switch** — the `bottom-anchor` was 1px, and `LazyVStack` might not render it immediately, so `scrollTo("bottom-anchor")` could overshoot. This is a real but minor issue.

2. **Bounce during streaming** — caused by `withAnimation` on `scrollToBottom`. Every `onChange(of: messages.count)` or `onChange(of: isStreaming)` triggers an animated scroll, and during streaming that means rapid animated scrolls that fight each other.

3. **`isAtBottom` detection flickering** — `onAppear`/`onDisappear` on a 1px spacer is fragile during rapid layout changes.

## What Every Other Chat App Does

Every major chat UI (iMessage, WhatsApp, Telegram, Discord) handles auto-scroll the same way:

1. **Don't animate during streaming.** Only animate on user-initiated scrolls (new message from user, topic switch).
2. **Pin to bottom, don't scrollTo.** Use `defaultScrollAnchor(.bottom)` and let SwiftUI handle it. Don't fight the layout engine.
3. **One scroll trigger, not many.** React to "new content at bottom" once, not to multiple state changes.
4. **No bounce suppression hacks.** Let the scroll view behave naturally.

## Root Cause Summary

| Our change | What it actually did | Why it's worse |
|---|---|---|
| `.scrollBounceBehavior(.automatic)` during streaming | Changed from "bounce only when content > viewport" to "bounce always" | More bounce, not less |
| Target `"streaming-bubble"` instead of `"bottom-anchor"` | Scrolling to a growing element | Target is unstable, causes jitter |
| Removed `onChange(of: showStreamingBubble)` | No scroll when streaming bubble first appears | Content may not scroll into view |
| Removed `asyncAfter` | Removed the re-scroll that handled LazyVStack settling | Less relevant — the original issue was animation, not asyncAfter |

## Recommendation: Revert to Simplicity

**Revert `MessageCanvas.swift` to the working `696b69a` version** (the original simple implementation), then make exactly two minimal, targeted changes:

### Change 1: No animation during streaming

The original `scrollToBottom` always used `withAnimation`. During streaming, this causes bounce because every 50ms content update can trigger a new animated scroll.

**Fix:** Skip animation during streaming. One line.

```swift
private func scrollToBottom(proxy: ScrollViewProxy) {
    if isStreaming {
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    } else {
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}
```

### Change 2: Keep the bottom anchor but make it slightly taller

The original 1px anchor could cause overshoot on topic switch. Increase to 4px — enough for LazyVStack to render reliably, invisible to the user.

```swift
Color.clear
    .frame(height: 4)
    .id("bottom-anchor")
```

That's it. Two changes. No conditional targets, no bounce behaviour switching, no dedup, no asyncAfter, no removing onChange handlers.

### Why this works

- **No animation during streaming** eliminates the bounce. SwiftUI's `defaultScrollAnchor(.bottom)` handles content growth naturally without explicit scrolls.
- **Stable `"bottom-anchor"` target** never moves, so scrollTo always lands in the same place.
- **`onChange(of: showStreamingBubble)` stays** — it scrolls when the bubble first appears, then `defaultScrollAnchor(.bottom)` keeps the view pinned as content grows.
- **`onChange(of: isStreaming)` stays** — scrolls to bottom when streaming starts.
- **`onChange(of: messages.count)` stays** — scrolls when the assistant message is committed.

### What about the "Jump to Latest" button and other features?

The current code has features the original doesn't:
- `isAtBottom` detection and "Jump to Latest" button
- `thinkingState` and `ThinkingBeeIndicator`
- `canLoadEarlier` and "Load earlier messages"
- Topic switch scroll handling

These should all be preserved. The revert is only for the `scrollToBottom` logic and the scroll-related `onChange` handlers. The UI features stay.

### What about Fix A/B/C (crash/hang)?

Those are in completely different files (`GatewayClient.swift`, `PendingRequestMap.swift`, `SyncBridgeObserver.swift`). A revert of `MessageCanvas.swift` does NOT affect them. They remain in place.

---

## What Not To Do

- **Don't add conditional scroll targets.** Scrolling to a growing element is the bounce.
- **Don't switch bounce behaviour.** `.basedOnSize` is correct. `.automatic` makes it worse.
- **Don't remove onChange handlers.** They're needed for initial scroll.
- **Don't add dedup guards.** They mask the real problem (animation during streaming).
- **Don't add asyncAfter.** Double-scrolling is worse than single-scrolling.

## The Lesson

We overcomplicated this. Every iteration added more logic to fight SwiftUI's layout engine. The fix is simpler: stop animating during streaming, let `defaultScrollAnchor(.bottom)` do its job, and use a stable scroll target.