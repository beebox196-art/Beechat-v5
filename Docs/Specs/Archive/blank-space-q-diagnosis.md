# Diagnosis: Blank White Space on Topic Switch

**Date:** 2026-05-08  
**Author:** Q

## Symptom

When switching topics, ~2 screens of blank white space appear below messages. The Jump button scrolls INTO that blank space rather than to the latest message.

## Root Cause (3 interacting problems)

### 1. Bottom anchor was 120pt — too tall

The `Color.clear.frame(height: 120).id("bottom-anchor")` was 120pt tall. This spacer existed only to trigger `onAppear`/`onDisappear` for scroll-position detection, but 120pt is far more than needed. With the 100ms debounce, even 1-2pt is sufficient. The 120pt didn't directly cause "2 screens" of blank, but it contributed to visual misalignment.

### 2. Scroll fired before LazyVStack rendered messages

The critical bug: on topic switch, `onChange(of: topicId)` called `scrollToBottom(animated: true)` immediately. But `LazyVStack` hadn't rendered any messages for the new topic yet — the scrollable content was just the 120pt anchor. `scrollTo("bottom-anchor", anchor: .bottom)` then scrolled this tiny anchor to the viewport bottom, leaving the entire viewport as blank space. When messages eventually rendered, the scroll position didn't adjust.

### 3. Scrolling to "bottom-anchor" instead of the last message

`scrollTo("bottom-anchor")` targets an invisible spacer. When LazyVStack renders lazily, the anchor may be the only laid-out element. Scrolling to the last **message** ID is more reliable because it forces LazyVStack to materialize that content.

## Fix (4 changes)

| Change | Before | After |
|--------|--------|-------|
| Anchor height | 120pt | 2pt |
| Topic switch scroll | Immediate `scrollToBottom` | Defer with `pendingTopicScroll` flag — scroll when `messages.count` changes |
| Scroll target | `"bottom-anchor"` | `messages.last?.id ?? "bottom-anchor"` |
| Fallback delay | 0.2s | 0.5s |

### How the defer mechanism works

1. `onChange(of: topicId)` sets `pendingTopicScroll = true` instead of scrolling immediately (when `messages.isEmpty`)
2. `onChange(of: messages.count)` checks `pendingTopicScroll` — if true, scrolls to bottom and clears the flag
3. This ensures messages are rendered before we attempt to scroll to them

### Why anchor: .bottom is correct

Using `anchor: .bottom` positions the target item so its bottom edge aligns with the viewport bottom. This is the correct anchor for the last message — it should appear at the bottom of the visible area, not centered. The bug was never about the anchor parameter; it was about timing.

## Build & Test

- ✅ Build succeeded
- ✅ 87/87 tests passed
- ✅ Committed as `b40e9db`