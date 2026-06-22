# SPEC: White Space Jump on Message Send — Root Cause & Fix Proposal

**Date:** 2026-05-15
**Status:** Awaiting team review
**Priority:** Medium (not a blocker, but affects UX significantly)
**Related:** `SPEC-scroll-fix.md` (existing spec, partially implemented)

---

## Symptom

After sending a message in BeeChat, the message canvas jumps down into a large blank white space. This affects any topic that's actively streaming — switching to a streaming topic also shows the white space, requiring manual scroll back up to see content.

Does NOT happen in Telegram or iMessage, which handle streaming content smoothly.

---

## Root Cause Analysis

The `onChange(of: messages.count)` handler in `MessageCanvas.swift` (line 112) forces an explicit `scrollToBottom` on every new message, including when `isUserMessage == true`:

```swift
.onChange(of: messages.count) { _, _ in
    ...
    } else if isAtBottom || isUserMessage {
        scrollToBottom(proxy: proxy, animated: false)
    }
}
```

**What happens when you send a message:**

1. Your message appears → `messages.count` increments
2. `isUserMessage` is `true` → `scrollToBottom(animated: false)` fires immediately
3. The scroll targets the bottom of the current content (just your message + existing history)
4. Then `ThinkingBeeIndicator` appears → content height grows → `isAtBottom` recalculates
5. Then `StreamingBubble` starts growing via 50ms poll → content grows continuously
6. `defaultScrollAnchor(.bottom)` tries to pin, but the earlier explicit `scrollToBottom` has set a stale position
7. SwiftUI's layout engine sees a delta between the explicit scroll position and where `.bottom` wants to be → **white space jump**

**Why Telegram doesn't have this:** Telegram uses a single policy: "if at bottom, stay at bottom." It never calls an explicit `scrollTo` on content arrival. The scroll position tracks naturally via `defaultScrollAnchor(.bottom)` and geometry-based `isAtBottom` detection.

---

## Proposed Fix

**Remove `isUserMessage` from the scroll condition.** When a user sends a message, `defaultScrollAnchor(.bottom)` and `isAtBottom` geometry tracking handle staying pinned naturally. No explicit scroll call needed.

### Change 1: Remove `isUserMessage` scroll trigger

**File:** `Sources/App/UI/Components/MessageCanvas.swift`

```swift
// BEFORE (line 121):
} else if isAtBottom || isUserMessage {

// AFTER:
} else if isAtBottom {
    // Only auto-scroll when already at the bottom.
    // Do NOT force scroll on user message — defaultScrollAnchor(.bottom)
    // handles staying pinned. Explicit scrollToBottom on user send
    // causes white-space overshoot because the scroll targets a position
    // that becomes stale when the streaming bubble starts growing.
```

### Change 2: Remove `isUserMessage` computed property (now unused)

**File:** `Sources/App/UI/Components/MessageCanvas.swift`

```swift
// REMOVE:
private var isUserMessage: Bool {
    guard let lastMessage = messages.last else { return false }
    return lastMessage.role == "user"
}
```

### Change 3 (optional): Increase scroll debounce from 100ms → 150ms

The 50ms streaming poll is close to the 100ms debounce window. During rapid delta events, this can allow two scroll calls within ~200ms that cause layout feedback. 150ms gives more breathing room.

```swift
// BEFORE:
if now.timeIntervalSince(lastScrollTime) < 0.1 {

// AFTER:
if now.timeIntervalSince(lastScrollTime) < 0.15 {
```

---

## What This Does NOT Change

- `defaultScrollAnchor(.bottom)` still pins the view to bottom during streaming
- `isAtBottom` geometry tracking (already migrated from `onAppear`/`onDisappear`) still works
- Topic switching still explicitly scrolls to bottom (via `pendingTopicScroll`)
- "Load earlier" anchor scroll still works
- "Jump to latest" button still works
- `onAppear` initial scroll still works

## What This Risk

- **Low risk:** The only behaviour change is that sending a message while scrolled to the bottom will rely on `defaultScrollAnchor(.bottom)` instead of an explicit `scrollToBottom`. This is how it should work — SwiftUI handles this natively.
- **Edge case:** If `defaultScrollAnchor(.bottom)` has a timing issue where it doesn't fire immediately, the user message might not auto-scroll. This is theoretical — macOS 15+ handles this correctly.

---

## Verification Checklist

- [ ] Send a message → no white space jump
- [ ] Streaming response → stays pinned at bottom, no bounce
- [ ] Switch to a streaming topic → no white space, content visible at bottom
- [ ] Two topics streaming simultaneously → no cross-contamination of scroll state
- [ ] Scroll up during streaming → no forced yank back to bottom
- [ ] "Jump to latest" button → works correctly
- [ ] Topic switch → scrolls to bottom correctly

---

## Review Assignments

- **Q:** Implement changes 1-3, build, verify checklist
- **Kieran:** Review for failure modes — especially the `defaultScrollAnchor(.bottom)` timing edge case
- **Mel:** UX verification — compare scroll behaviour with Telegram/iMessage after fix