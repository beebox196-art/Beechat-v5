# BeeChat Diagnosis — Session Reset Interference + MessageCanvas Changes

**Date:** 2026-05-21  
**Reviewer:** Q  
**File:** `Docs/Reviews/q-diagnosis-2026-05-21.md`

---

## Issue 1: Session Reset Appearing as Message (White Screen)

### Root Cause Identified: `showAutoResetToast` State Pollution

In `SyncBridgeObserver.swift`, the auto-reset completion handler sets `showAutoResetToast = true`:

```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didStopAutoReset sessionKey: String) {
    Task { @MainActor in
        self.autoResetting = false
        self.showAutoResetToast = true          // ← THIS IS THE BUG
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.showAutoResetToast = false
        }
    }
}
```

**The `showAutoResetToast` is a `@MainActor @Observable` property.** It is read in `MainWindow.swift` here:

```swift
@ViewBuilder
private var resetIndicator: some View {
    if syncBridgeObserver.autoResetting {
        // ... ProgressView + "Refreshing context..."
    } else if syncBridgeObserver.manualResetting {
        // ... ProgressView + "Resetting session..."
    } else if syncBridgeObserver.showAutoResetToast {
        Text("Session refreshed")               // ← THIS APPEARS AT TOP OF SCREEN
            .font(.caption)
            .padding(...)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .transition(.opacity)
    }
}
```

**How it causes the white screen:**
1. `sendMessage()` detects usage >= 80%, fires fire-and-forget background reset Task
2. `delegate?.syncBridge(self, didStartAutoReset: sessionKey)` sets `autoResetting = true`
3. The reset runs in background, `delegate?.syncBridge(self, didStopAutoReset: resetKey)` sets `showAutoResetToast = true` and `autoResetting = false`
4. The `resetIndicator` view transitions from `ProgressView` to the toast Text("Session refreshed")
5. Because `resetIndicator` lives in a `ZStack(alignment: .top)` overlay on the MessageCanvas, this toast appears at the top
6. Meanwhile, `resetSession()` calls `rpcClient.sessionsReset(sessionKey:sessionKey, reason:"new")` — this **wipes the gateway-side chat history**
7. `fetchHistory()` is called after `processChatFinal` to reload messages from gateway, but the gateway now has no messages
8. Result: MessageCanvas is empty (white) with a "Session refreshed" toast at the top — exactly what Adam described

### Why Messages Disappear

The auto-reset flow calls `resetSession()` which hits the gateway with `reason: "new"`. This clears all messages server-side. The local SQLite cache still has the old messages, but `processChatFinal` calls `fetchHistory()` which overwrites local state with the now-empty gateway history.

**This is by design** — the reset is supposed to clear context server-side. But the UI feedback ("Session refreshed" toast) makes it look like an error rather than intended behavior.

### `pendingResetContext` Injection — NOT a Visible Message

The `pendingResetContext` is a `[String: String]` dictionary. It is injected into the *next* `sendMessage()` call by prepending to `effectiveText`:

```swift
if let pendingContext = pendingResetContext.removeValue(forKey: sessionKey) {
    if effectiveText.isEmpty {
        effectiveText = pendingContext
    } else {
        effectiveText = "\(pendingContext)\n\n\(effectiveText)"
    }
}
```

The `pendingContext` string is formatted as:
```
[SESSION-CONTEXT] Continuing from a previous session. Recent conversation:
User: <msg>
Assistant: <msg>
...
The user's latest message follows:
```

This is sent as the *user's message content* to the gateway. It appears as a user message bubble in the UI, but **only if the message is successfully sent and received**. The `[SESSION-CONTEXT]` prefix is visible to the user inside the message bubble. This is expected — it's the context carry-forward mechanism.

### `didAutoReset` Flag Logic Bug

In `sendMessage()`:
```swift
var didAutoReset = false
if let pendingContext = pendingResetContext.removeValue(forKey: sessionKey) {
    // ...
    didAutoReset = true  // ← Named poorly — this means "context was injected"
}
```

Later:
```swift
// Auto-reset at 80% safety ceiling
if !didAutoReset {  // ← Skips usage check if manual reset context was injected
```

This is actually **correct behavior** — if we just manually reset and injected context, we don't need to auto-reset again on the same send. But the variable name `didAutoReset` is misleading. The comment says "Reuse flag to skip topic context injection below" which is also correct — we skip the `[TOPIC-CONTEXT]` header if we're already carrying session context.

However, the fire-and-forget auto-reset Task sets `pendingResetContext` **after** the reset completes:
```swift
Task {
    // ... resetSession() completes ...
    pendingResetContext[resetKey] = combinedContext  // ← Set AFTER reset
}
```

So on the *current* send, `pendingResetContext` won't be consumed (it hasn't been set yet). It will be consumed on the *next* send. This means:
1. User sends message at 80%+ usage
2. Message goes through with original text
3. Background: reset fires, context is formatted and stored
4. Next user message: context is injected

This is the intended hybrid flow, but there's a race: the user might send another message before the background reset completes, and that second message won't have context yet.

---

## Issue 2: MessageCanvas Changes Review

### Git Diff Summary

Bee made these changes (unauthorized, post-reviewer-kill):

1. **Removed `ScrollGeometryResult` struct** — simplified to `Bool` (just `isAtBottom`)
2. **Removed `contentHeight`, `containerHeight`, `contentFillsContainer`** tracking
3. **Removed `lastScrollTime` debounce** and `scrollCorrectionTask`
4. **Changed `onScrollGeometryChangeCompat` signature** from `ScrollGeometryResult` to `Bool`
5. **Removed `scheduleScrollCorrection` entirely**
6. **Removed `.onChange(of: containerHeight)` and `.onChange(of: thinkingState)` scroll triggers**
7. **Added `.onChange(of: showStreamingBubble)` trigger** — scrolls to bottom when streaming starts
8. **Simplified `scrollToBottom`** — no debounce, no `lastScrollTime`, streams without animation
9. **Reduced bottom anchor from 8px to 4px**
10. **Removed macOS 14 fallback `DispatchQueue.main.asyncAfter`**
11. **Updated doc comments** with "scroll philosophy" justification

### Technical Assessment

**Good changes:**
- ✅ Simplifying `ScrollGeometryResult` to `Bool` is cleaner — the extra fields were only used for `contentFillsContainer` which was removed
- ✅ Removing `scheduleScrollCorrection` removes a known source of bounce (async scroll after layout)
- ✅ `scrollToBottom` during streaming without animation is correct — animation fights layout
- ✅ 4px anchor is fine if 8px caused visible whitespace
- ✅ `.onChange(of: showStreamingBubble)` is a valid trigger for first-chunk scroll

**Questionable changes:**
- ⚠️ **Removed `lastScrollTime` debounce**: The old code had a 200ms debounce to prevent rapid re-triggering. Without it, multiple `onChange` observers could fire in quick succession and call `scrollToBottom` repeatedly. However, the new code only triggers on `messages.count`, `showStreamingBubble`, `topicId`, and `onAppear` — fewer triggers, so less risk.
- ⚠️ **Removed `.onChange(of: thinkingState)` scroll**: The old code deliberately did NOT scroll on `.thinking` (the comment says "REMOVED: scrollToBottom on .thinking"). Wait — looking at the diff, the OLD code had:
```swift
.onChange(of: thinkingState) { oldState, newState in
    // REMOVED: scrollToBottom on .thinking
}
```
This was already a no-op. Bee didn't change behavior here, just removed dead code. ✅ Safe.

**The Hysteresis/Feedback Loop Question (Kieran's Flag):**

The `onScrollGeometryChangeCompat` transform closure reads `isAtBottom` (a `@State` property) for hysteresis:
```swift
transform: { geo in
    if isAtBottom {
        return distanceFromBottom < leaveThreshold
    } else {
        return distanceFromBottom < enterThreshold
    }
}
```

**Is this a feedback loop?**
- `isAtBottom` is `@State` in `MessageCanvas`
- The transform closure is called by SwiftUI's `onScrollGeometryChange` whenever scroll geometry changes
- Reading `isAtBottom` inside the transform is technically a side-effect (it's not pure)
- BUT: `isAtBottom` only changes when the `action` closure runs (which only runs when the transform's return value changes)
- The transform's return value determines when `action` runs, which mutates `isAtBottom`
- This creates a potential cycle: geometry changes → transform reads isAtBottom → returns different value → action updates isAtBottom → next geometry change reads new isAtBottom...

**Does it cause continuous bounce?**
- In practice, no — the geometry change events are driven by actual scroll position, not by `isAtBottom`
- The hysteresis thresholds (50px enter, 120px leave) create a dead zone that prevents oscillation
- The real bounce Adam reported was caused by `scheduleScrollCorrection` (removed) and animated scrolls during streaming (also addressed)
- **However**, on macOS 15+ where `onScrollGeometryChange` is native, Apple explicitly documents that the transform should be pure. Reading `@State` in the transform is undefined behavior territory.

**Verdict:** This is not the cause of Adam's current bounce. The bounce was from `scheduleScrollCorrection` + animated streaming scrolls. But it's a code smell that could break in future SwiftUI versions.

### Should These Changes Be Reverted?

**No — keep them.** The changes are technically sound and fix known issues:
1. `scheduleScrollCorrection` was a confirmed bounce source
2. Animated scroll during streaming was a confirmed bounce source
3. The simplification reduces surface area for future bugs

**But add these fixes:**
1. Make the `onScrollGeometryChangeCompat` transform pure by passing the old value as a parameter (requires API change, or use a closure-captured local variable)
2. Actually, the simplest fix: capture `isAtBottom` into the transform as a local copy at closure creation time. Since `transform` is `@escaping` and stored, it captures the current value. But `isAtBottom` is `@State` which has special semantics...

Actually, looking more carefully: `isAtBottom` is a `@State` property. In SwiftUI, `@State` properties accessed inside a View body or modifier closure are automatically tracked for dependencies. When `isAtBottom` changes, SwiftUI re-evaluates the View body, which reconstructs the `onScrollGeometryChangeCompat` modifier with a fresh closure. The fresh closure captures the new `isAtBottom` value. So there's no actual feedback loop — each closure instance is independent.

**Verdict: Safe to keep. The transform reading `@State` is unconventional but not harmful in this specific pattern because the closure is re-created on every body evaluation.**

---

## Recommendations

### Immediate Fixes (for white screen + "session refresh" message)

1. **In `SyncBridgeObserver.swift`:** Remove or relocate the `showAutoResetToast` indicator. The "Session refreshed" toast appearing on a blank canvas is confusing UX. Options:
   - Remove the toast entirely (the reset is invisible and intentional)
   - Show it only if the canvas still has messages (i.e., local history wasn't wiped)
   - Move it to the sidebar or status bar instead of overlaying the canvas

2. **In `SyncBridge.swift`:** The fire-and-forget auto-reset Task doesn't block the send, but it also doesn't guarantee the reset completes before the next send. Consider:
   - Setting a flag `isResetPending` that blocks sends until reset completes
   - Or: making the reset synchronous (block the send) when usage is critically high

3. **In `MainWindow.swift`:** The `resetIndicator` overlay at `.top` in the ZStack creates the visual impression that "session refresh" is a message. Consider:
   - Moving `resetIndicator` to `.bottom` (near Composer) as a subtle status
   - Or: using a non-blocking status bar instead of an overlay

### For the MessageCanvas Changes

1. **Keep all changes** — they are sound and fix bounce
2. **Optional cleanup:** Rename `didAutoReset` to `contextInjected` or `skipTopicHeader` in `SyncBridge.swift` for clarity
3. **Optional cleanup:** Add a small debounce back to `scrollToBottom` if rapid-fire `messages.count` changes become an issue (unlikely with current architecture)

---

## Summary

| Issue | Finding | Action |
|-------|---------|--------|
| "Session refresh" as message | `showAutoResetToast` overlay on blank canvas after reset clears history | Move/remove toast indicator |
| White screen | Gateway reset clears history; `fetchHistory()` overwrites local cache with empty gateway state | Expected behavior, but needs better UX |
| `pendingResetContext` as visible message | Context is injected into user's message text — appears as a user bubble with `[SESSION-CONTEXT]` header | Expected by design |
| MessageCanvas changes | Simplification is sound, removes confirmed bounce sources | Keep changes |
| Hysteresis feedback loop | Transform reads `@State` but closures are recreated on body eval — not harmful | Code smell, not urgent |
