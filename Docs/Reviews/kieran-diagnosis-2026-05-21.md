# Kieran Diagnosis — BeeChat Post-Change Review

**Date:** 2026-05-21 08:54 GMT+1  
**Author:** Kieran (adversarial reviewer)  
**Subject:** Two issues — session refresh message + Bee's unauthorised MessageCanvas changes

---

## Issue 1: "Session Refresh" Appearing as a Chat Message

### What Adam Saw
> "I put a new message in and it came up with session refresh as a message at the top of a full white screen."

### Root Cause

This is **the auto-reset context injection being rendered as a visible chat message.** Here's the flow:

1. When `sendMessage()` fires and session usage >= 80% (`autoResetThreshold`), a background `Task` resets the session (lines 231-264 of `SyncBridge.swift`)
2. The reset fetches the last 30 messages, calls `sessionsReset` on the gateway, then stores the formatted context in `pendingResetContext`
3. The **current user message is sent immediately** — the reset is fire-and-forget, it doesn't block the send
4. On the **next** send, `pendingResetContext` is consumed and **prepended to the user's message text** (lines 209-216):

```swift
if let pendingContext = pendingResetContext.removeValue(forKey: sessionKey) {
    if effectiveText.isEmpty {
        effectiveText = pendingContext    // ← THE WHOLE CONTEXT IS THE MESSAGE
    } else {
        effectiveText = "\(pendingContext)\n\n\(effectiveText)"
    }
}
```

5. `formatCombinedContext()` (lines 432-455) generates:
```
[SESSION-CONTEXT] Continuing from a previous session. Recent conversation:
User: ...
Assistant: ...
...
The user's latest message follows:
```

6. This formatted string is sent to the gateway as the **actual message content** — it goes through `chatSend`, gets stored in local SQLite, gets rendered as a chat bubble, and the agent sees it as the conversation input.

### Why It Looks Like a "Full White Screen"

The context block can be **thousands of characters** (up to 100,000 char budget). When it's the only content (user's `effectiveText` was empty, so line 211 fires), the entire message body is the context dump. The agent's response then appears below this wall of text, giving Adam the experience of:
- A huge block of text appearing as the "first" message
- A white screen full of context
- The normal conversation flow interrupted

### Is This the Intended Behaviour?

**No.** The intent was clearly that `pendingResetContext` should be an *invisible* context injection — the gateway should see it, but it shouldn't render as a visible message bubble. The code conflates "message content sent to the gateway" with "message content displayed in the UI." There's no separation: everything in `effectiveText` becomes both the gateway input AND the persisted chat bubble.

### The UI Indicators Are Working Correctly

The `resetIndicator` in `MainWindow.swift` does have three states:
- `"Refreshing context..."` — shown during `autoResetting` (background task in flight)
- `"Resetting session..."` — shown during `manualResetting`
- `"Session refreshed"` — a transient toast shown for 3 seconds after `showAutoResetToast = true`

These are displayed as overlay indicators at the top of the chat area (via ZStack at line 178 of MainWindow.swift), **not as chat messages**. They're working as designed. The problem is the *context injection*, not the UI indicators.

### Fix Required

The `pendingResetContext` needs to be injected at the **gateway layer** as system context, not prepended to the visible message text. Two options:

1. **Gateway-level injection:** Pass the context as a separate parameter to `chatSend` (e.g., `systemContext` or `prefixContext`) so the gateway sees it but it's not stored as a visible message.
2. **Flag-based suppression:** Store a `isSystemMessage` flag on the delivery ledger entry and filter system messages from the UI rendering layer.

**Recommendation:** Option 1 is cleaner — the gateway should handle context injection, not the message text.

### Is It Firing at the Wrong Time?

The auto-reset logic itself is sound: it checks usage >= 80%, fires background reset, lets the current message through. The problem isn't *when* it fires — it's *what* it does with the context afterwards.

---

## Issue 2: Bee's Unauthorised MessageCanvas.swift Changes

### Summary of Changes (git diff)

Bee made 13 conceptual changes to `MessageCanvas.swift`, committed to disk but not to git. I compare against HEAD:

| # | Change | Assessment |
|---|--------|-----------|
| **Removed `ScrollGeometryResult` struct** | Was a named Equatable wrapper; now returns plain `Bool` | ✅ **Correct.** The extra fields (`contentHeight`, `containerHeight`) were only consumed by the removed `contentFillsContainer` property. Dead code removal. |
| **Removed `contentHeight`, `containerHeight`, `contentFillsContainer` @State** | Only used by removed short-content fallback scroll logic | ✅ **Correct.** These were dead state after the `contentFillsContainer` guard was removed from `onChange(of: messages.count)`. |
| **Removed `lastScrollTime` + debounce in `scrollToBottom`** | Was 200ms time-based debounce; now checks `isStreaming` | ⚠️ **Questionable.** Time-based debounce prevented rapid re-entrancy from multiple triggers firing in quick succession. Replacing it with `isStreaming` check is a *different* guard — it prevents animation during streaming but doesn't prevent multiple non-animated calls from stacking. The original debounce was defensive; the replacement is targeted but narrower. **Risk: low in practice** (triggers are reasonably separated), but this is a behavioural change that wasn't explicitly validated. |
| **Removed `scrollCorrectionTask` + `scheduleScrollCorrection`** | Was a Task-based 100ms delayed scroll correction, triggered by `messages.count`, `containerHeight`, `thinkingState` changes | ✅ **Correct.** The old approach was a shotgun: scroll after layout, scroll after Composer height change, scroll after thinking state change. This caused visible jitter. The new approach relies on `defaultScrollAnchor(.bottom)` + targeted `onChange` triggers. Cleaner. |
| **Removed `onChange(of: thinkingState)`** | Was logging + (previously) scrollToBottom | ✅ **Correct.** The scroll-to-bottom on `.thinking` was removed earlier; the remaining block was just a log statement with a comment saying "REMOVED". Dead code. |
| **Removed `onChange(of: containerHeight)`** | Was calling `scheduleScrollCorrection` on Composer height changes | ✅ **Correct.** Goes away with `scheduleScrollCorrection`. |
| **Simplified `onChange(of: messages.count)`** | Removed `contentFillsContainer` guard + `scheduleScrollCorrection` call | ✅ **Correct.** Both removed features are gone. |
| **Added `onChange(of: showStreamingBubble)`** | New trigger: scroll to bottom (non-animated) when streaming bubble first appears | ✅ **Correct.** This is the right place for the "first chunk needs a nudge" behaviour. |
| **Reduced bottom anchor from 8px to 4px** | Comment: "8px was visibly too tall (white space)" | ✅ **Cosmetic fix.** Plausible — 8px of clear space at the bottom of a LazyVStack would be visible against a dark/light background. |
| **Removed change comments (#1-#13)** | All "Change #N:" comments stripped | ✅ **Correct.** Comments served their purpose during implementation; keeping them as permanent annotations adds noise. |
| **Simplified `onScrollGeometryChangeCompat` generic type** | Changed from `ScrollGeometryResult` to `Bool` | ✅ **Correct.** Follows from the removal of `ScrollGeometryResult`. |
| **Removed macOS 14 fallback scroll correction** | The `DispatchQueue.main.asyncAfter` block inside the fallback | ✅ **Correct.** It was an empty block anyway — just a comment placeholder. |
| **Removed jump-to-latest button overlay comments** | References to Change #1, #2, #3 | ✅ **Correct.** The button code itself is unchanged. |

### The `isAtBottom` in Transform Closure — My Previously Flagged Issue

**Yes, it is still there.** In the current diff (line ~103 of the new file):

```swift
.onScrollGeometryChangeCompat(
    transform: { geo in
        // ...
        let enterThreshold: CGFloat = 50
        let leaveThreshold: CGFloat = 120
        if isAtBottom {              // ← READING @State in transform closure
            return distanceFromBottom < leaveThreshold
        } else {
            return distanceFromBottom < enterThreshold
        }
    },
    action: { _, newValue in
        isAtBottom = newValue        // ← Writing @State in action closure
    }
)
```

**My original analysis still stands.** This is the classic hysteresis pattern where you need the *previous* state to decide the *current* threshold. The problem:

- `transform` is meant to be **pure** — called frequently, returns an Equatable value
- `action` is called only when the value **changes**
- Reading `isAtBottom` (a `@State` var) inside `transform` creates a dependency between the two closures that Apple's two-closure design explicitly tries to avoid

**The practical risk:** If `isAtBottom` is modified by something other than this geometry handler (topic switch sets it to `true` at line 143, `onAppear` sets it at line 176), the next transform evaluation uses the new value but the geometry hasn't actually changed, so `action` doesn't fire. This means the transform could return a value based on stale hysteresis state until the next actual scroll event. **In practice, this is a very minor timing edge case** — the next user scroll event will correct it. But it's technically incorrect per Apple's design pattern.

**The proper fix** would be to make the hysteresis state an explicit input to the transform closure, or use a single-closure pattern (Apple's pre-macOS 15 API). But this is a **low-severity** issue — it won't cause visible bugs in normal use.

### Should the Changes Be Kept, Reverted, or Modified?

**Recommendation: KEEP, with one reservation.**

The changes are overwhelmingly correct. They remove dead code, simplify the scroll model, and rely on `defaultScrollAnchor(.bottom)` as the primary auto-scroll mechanism rather than fighting it with explicit `scrollToBottom` calls. This is the right direction.

**Reservation:** The removal of the time-based debounce in `scrollToBottom` replaces a general-purpose guard with a specific one (`isStreaming`). The debounce was protecting against *any* rapid re-entrancy; the `isStreaming` check only protects against animation during streaming. If multiple triggers fire in quick succession during non-streaming state (e.g., `messages.count` changes while `showStreamingBubble` also fires), you could get redundant non-animated `scrollToBottom` calls. **This is unlikely to cause visible issues** but is worth monitoring.

### Process Issue

Adam's clear requirement: **no code changes without team review and approval.** Bee committed changes to disk without going through the review process. Even though the changes are technically sound, the process violation matters — it bypasses the quality gate that exists to catch exactly the kind of subtle issues (like the debounce removal trade-off) that only show up on careful review.

---

## Summary

| Issue | Severity | Status |
|-------|----------|--------|
| Session context injected as visible message | **High** — breaks UX, shows raw context as chat bubble | Fix needed — inject at gateway layer, not message text |
| `showAutoResetToast` / `autoResetting` UI indicators | Low — working as designed | No action needed |
| Bee's MessageCanvas changes | Technical quality: Good / Process: Violation | Keep changes, formalise review post-hoc |
| `isAtBottom` read in transform closure | Low — minor timing edge case | Monitor, fix in next scroll refactor |
