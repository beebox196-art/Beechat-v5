# BC5-SPEC-005 Issue: Blank White Space Below Messages on Topic Switch

**Date:** 2026-05-08  
**Priority:** High (broken UX — can't see messages without scrolling)  
**Status:** DRAFT — Team Review  

---

## Problem

When switching between topics, the user is presented with a blank white screen. They have to scroll up approximately two screen heights to see the actual messages. The Jump to Latest button also takes them down into this blank space rather than to the last message.

It appears as though there are "ghost messages" — large empty areas below the last real message.

## Likely Cause

The 120pt `Color.clear` bottom anchor (introduced in the `onAppear`/`onDisappear` fix) may be contributing to excess scroll space, but 120pt alone wouldn't create two screens of blank space. More likely culprits:

1. **Streaming/thinking bubble residual height** — If a previous topic had a streaming session, the `StreamingBubble` or `ThinkingBee` view may have left residual layout space that persists after topic switch
2. **LazyVStack rendering ghost items** — `LazyVStack` may be allocating space for deallocated messages from the previous topic
3. **`scrollToBottom(animated: true)` overshooting** — The animated scroll with 200ms fallback may be scrolling past the content to the bottom of the ScrollView's content area, which includes the 120pt anchor plus any residual space
4. **`onAppear` timing** — The 120pt anchor's `onAppear` fires when it enters the viewport, but `scrollToBottom(animated: true)` may scroll past it, causing SwiftUI to allocate more space

## What to Investigate

1. **Check the actual content height** — Is the ScrollView's content taller than it should be? Add temporary debug logging for the content height vs the number of messages
2. **Check what `scrollToBottom` scrolls to** — Is `"bottom-anchor"` actually at the bottom of the messages, or is there space below it?
3. **Check if StreamingBubble/ThinkingBee leave residual height** — After streaming ends, do these views fully collapse (0 height) or retain their last size?
4. **Check if the 120pt anchor height is causing problems** — 120pt is tall for a `Color.clear` spacer. Could it be reduced to 1pt (with debounced `onAppear`/`onDisappear` handling the hysteresis instead)?
5. **Check if `onChange(of: topicId)` is firing correctly** — Does the topic switch set `isAtBottom = true` and scroll to the bottom of the NEW topic's messages?

## Current State

- Commit `48a6783` — scroll bounce fix (animated/non-animated scrollToBottom)
- Commit `5358a38` — onAppear/onDisappear detection (120pt bottom anchor)
- The topic-switch fix from BC5-SPEC-004 is also in play

## Files to Review

- `/Users/openclaw/Projects/BeeChat-v5/Sources/App/UI/Components/MessageCanvas.swift` — main scroll view, bottom anchor, scrollToBottom
- `/Users/openclaw/Projects/BeeChat-v5/Sources/App/UI/MainWindow.swift` — topic switch handling
- `/Users/openclaw/Projects/BeeChat-v5/Sources/App/UI/ViewModels/MessageViewModel.swift` — message loading on topic switch
- `/Users/openclaw/Projects/BeeChat-v5/Sources/App/UI/Observers/MessageListObserver.swift` — message list observation

---

*Awaiting team diagnosis before any code changes.*