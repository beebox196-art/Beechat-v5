# FR-002 Tap-to-Reconnect — Kieran Code Review

**Date:** 2026-06-19
**Reviewer:** Kieran
**Commit:** f8d09c3
**Base:** develop (012e7c5)
**Verdict:** PASS WITH CHANGES

## Spec Compliance

| Spec Requirement | Status | Notes |
|---|---|---|
| `reconnect()` method on `AppState` | ✅ | Lines 134–194 of AppRootView.swift |
| Guard 1: `syncBridge != nil` | ✅ | Line 136 |
| Guard 2: `connectionState != .connecting && != .handshaking` | ✅ | Line 138 (Kieran MAJOR #1) |
| Set `.connecting` synchronously before any `await` | ✅ | Line 140, before `Task {}` on line 142 |
| Clear `offlineStatus` + `errorMessage` | ✅ | Lines 145–146 |
| Stop existing bridge before creating new one | ✅ | Lines 148–150 |
| Cancel old `connectionStateTask` | ✅ | Lines 153–154 (Kieran MAJOR #2) |
| Rebuild `GatewayClient` + `SyncBridge` via `loadGatewayConfig` | ✅ | Lines 160–172 |
| `bridge.start()` → `.connected` + `isStartupComplete = true` | ✅ | Lines 176–177 |
| Store new `connectionStateTask` | ✅ | Lines 184–189 |
| Error path sets `.error` + `offlineStatus` | ✅ | Lines 191–193 |
| `isTappable` guards on `isStartupComplete` | ✅ | Line 15 of GatewayStatusBar.swift (Kieran MINOR #1) |
| Arrow icon (`arrow.clockwise`) shown when tappable | ✅ | Lines 67–70 |
| `.contentShape(Rectangle())` for full-width tap | ✅ | Line 76 |
| `.onTapGesture` calls `reconnect()` only when `isTappable` | ✅ | Lines 77–79 |
| Dynamic accessibility hint | ✅ | Line 81 |
| No changes to `MainWindow.swift` call site | ✅ | Confirmed — diff shows only 2 files |

All spec requirements are met. Both MAJOR findings from my spec review are addressed.

## Spec Review Findings — Addressed?

| Finding | Severity | Status | How Addressed |
|---|---|---|---|
| Race condition: rapid taps fire multiple reconnects | MAJOR | ✅ Fixed | Synchronous `connectionState = .connecting` on line 140 before `Task {}`, plus guard on line 138 |
| Old `connectionStateStream` not cancelled → state clobbering | MAJOR | ✅ Fixed | `connectionStateTask?.cancel()` + `= nil` on lines 153–154, new task stored on line 184 |
| Tappable during initialisation | MINOR | ✅ Fixed | `isTappable` checks `appState.isStartupComplete` (GatewayStatusBar.swift line 15) |
| `bridge.stop()` doesn't throw — checklist item misleading | MINOR | ✅ N/A | Spec updated, no code change needed |
| `DatabaseManager.shared` may not be open | MINOR | ✅ Documented | Spec notes the assumption; acceptable degraded behaviour |
| `TopicServer` port conflict on reconnect | MINOR | ✅ Documented | Pre-existing risk noted in spec; out of scope for FR-002 |

## Findings

### [MAJOR] `startup()`'s `connectionStateStream` subscription is not stored — old bridge state clobbering still possible on first reconnect

**Location:** AppRootView.swift lines 98–104 (startup method)

The `reconnect()` method correctly stores its `connectionStateStream` subscription in `connectionStateTask` and cancels it before creating a new bridge. However, the **initial** subscription created by `startup()` is NOT stored:

```swift
// startup(), lines 98-104:
Task {
    let stream = await bridge.connectionStateStream()
    for await state in stream {
        self.connectionState = state
    }
}
```

This is an unowned `Task`. When `reconnect()` runs for the first time:
1. `connectionStateTask` is `nil` (startup never set it)
2. `connectionStateTask?.cancel()` is a no-op
3. The old subscription from `startup()` is still alive
4. `bridge.stop()` fires `updateState(.disconnected)` via `GatewayClient.disconnect()`
5. The old subscription receives `.disconnected` and sets `self.connectionState = .disconnected`
6. This clobbers the `.connecting` state that `reconnect()` set synchronously

The timing here is tight: `reconnect()` sets `.connecting` synchronously, then the `Task` starts and hits `await bridge.stop()`. During `bridge.stop()`, `GatewayClient.disconnect()` calls `updateState(.disconnected)`, which fires all state observers **synchronously** (the `stateObservers` array is called directly in `updateState`). The old subscription's `for await state in stream` loop will receive `.disconnected` and set `self.connectionState = .disconnected`.

But wait — `connectionStateStream()` is an `AsyncStream` backed by `updateConnectionStateObserver`, which appends to `stateObservers`. The observer callback calls `continuation.yield(state)`. The `for await` loop processes yields asynchronously. So there's actually a brief async hop between `updateState(.disconnected)` and `self.connectionState = .disconnected` in the subscription loop.

This means the `.disconnected` from the old subscription arrives **after** `reconnect()` has already set `.connecting`. The `bridge.stop()` call happens inside the `Task`, after `.connecting` is set. So the sequence is:

1. `reconnect()` sets `connectionState = .connecting` (synchronous)
2. `Task {}` starts
3. `await bridge.stop()` — inside this, `updateState(.disconnected)` fires
4. Old subscription's observer fires → `continuation.yield(.disconnected)`
5. Old subscription's `for await` loop picks up `.disconnected` → sets `self.connectionState = .disconnected`
6. New bridge starts → `connectionState = .connected`

Step 5 clobbers step 1's `.connecting` with `.disconnected`. The UI would briefly show "No gateway connection" instead of "Connecting…" during the reconnect. This is a visual flash, not a functional bug — the new bridge's subscription will eventually set the correct state.

**However**, the more dangerous scenario: if the new bridge's `bridge.start()` fails (catches error), the old subscription could still be alive and emit a late `.disconnected` after the error handler has set `.error`. The old subscription would clobber `.error` with `.disconnected`, making the bar show "No gateway connection" instead of "Connection error" — and `isTappable` would still be true (`.disconnected` is tappable), so the user could tap again. Not catastrophic, but confusing.

**Required change:** Store the startup subscription in `connectionStateTask` as well:

```swift
// In startup(), replace the unowned Task with:
connectionStateTask = Task {
    let stream = await bridge.connectionStateStream()
    for await state in stream {
        self.connectionState = state
    }
}
```

This is a 1-line change (adding `connectionStateTask = ` before the `Task`). The spec noted this should be done: "The same pattern should be retrofitted to `startup()` for consistency." Q's build report acknowledged this wasn't done. It needs to be done — it's the difference between the MAJOR #2 fix actually working on first reconnect vs. only working on second+ reconnects.

### [MINOR] `connectionState = .connected` set before subscription is established

**Location:** AppRootView.swift lines 176–189

```swift
try await bridge.start()
connectionState = .connected        // line 176
isStartupComplete = true             // line 177

connectionStateTask = Task {          // line 184
    let stream = await bridge.connectionStateStream()
    for await state in stream {
        self.connectionState = state
    }
}
```

The subscription task is created **after** `connectionState = .connected` is set. Between `bridge.start()` succeeding and the subscription's `for await` loop starting, any state changes emitted by the bridge (e.g., a quick disconnect) would be missed because the subscription wasn't registered yet.

In practice, this window is extremely narrow — `bridge.start()` just succeeded, so the connection is live. The bridge's internal `reconnectWatchTask` and `connectionWatchTask` (both created in `SyncBridge.start()`) already subscribe to `connectionStateStream()` and will receive changes. But `AppState`'s subscription would miss them.

This is the same pattern as `startup()` — consistent, but not ideal. The fix would be to create the subscription before calling `bridge.start()`:

```swift
connectionStateTask = Task {
    let stream = await bridge.connectionStateStream()
    for await state in stream {
        self.connectionState = state
    }
}
try await bridge.start()
connectionState = .connected
isStartupComplete = true
```

But this introduces a different issue: the stream would emit `.connecting` or `.handshaking` from `bridge.start()`, which would overwrite the `.connected` we set afterward. So the current ordering is actually correct for the happy path — it just has a theoretical gap for rapid state changes.

**Required change:** None. The current ordering matches `startup()` and the theoretical gap is negligible. Noting for completeness.

### [MINOR] `onTapGesture` does not provide tactile feedback on macOS

**Location:** GatewayStatusBar.swift line 77

On macOS, `.onTapGesture` doesn't provide visual feedback (no button press animation, no hover state). The status bar looks the same whether tappable or not, except for the arrow icon. A user might not realise the bar is clickable.

The arrow icon mitigates this — it's a standard "refresh/reload" affordance. And the spec explicitly chose `.onTapGesture` over a `Button` for simplicity. This is a UX observation, not a code issue.

**Required change:** None. Acceptable for FR-002. If Adam wants hover feedback later, a `.hoverEffect` or custom `onHover` modifier could be added.

### [NIT] Missing newline at end of GatewayStatusBar.swift

**Location:** GatewayStatusBar.swift — last line

The file ends with `}` without a trailing newline. This was pre-existing (the diff shows `\ No newline at end of file` on both sides). Not introduced by this change, but worth fixing for cleanliness.

**Required change:** Add trailing newline. Trivial.

### [NIT] Comment style — "Kieran MAJOR #1" / "Kieran MINOR #1" references in code

**Location:** AppRootView.swift lines 137, 139, 153; GatewayStatusBar.swift line 15

The code comments reference my review findings by name and number. While helpful for traceability during the review cycle, these should be cleaned up before merge to `develop`. Production code comments should explain *why*, not reference a review document.

Suggested replacements:
- `// Guard 2: already reconnecting (Kieran MAJOR #1 — prevents race on rapid taps)` → `// Prevents concurrent reconnect attempts from rapid taps`
- `// Cancel old connection state subscription (Kieran MAJOR #2 — prevents state clobbering)` → `// Cancel old subscription before creating new bridge — prevents stale state clobbering`
- `// Kieran MINOR #1 — don't show tappable state during initialisation` → `// Don't show tappable state during initialisation`

**Required change:** Clean up review references in comments before merge.

## Summary

The implementation is a faithful, well-structured translation of the spec. Both MAJOR findings from my spec review are addressed correctly in `reconnect()`. The code follows existing patterns in the codebase (same config loading, same bridge creation, same subscription pattern). The blast radius is small — only `AppState` and `GatewayStatusBar` are touched.

The one remaining issue is that the `startup()` method's `connectionStateStream` subscription is **not** stored in `connectionStateTask`. This means the MAJOR #2 fix (cancelling old subscription) doesn't work on the **first** reconnect — only on the second and subsequent reconnects. The fix is a 1-line change: prefix the `Task` in `startup()` with `connectionStateTask = `. Once that's done, the old subscription is properly cancelled on every reconnect.

The other findings are minor or nits — no blockers, no safety issues, no crashes or leaks. The `Task` is stored and cancelled properly (once the startup fix is applied). Memory management is correct — `bridge.stop()` is called before the old bridge is replaced, and the old `Task` is cancelled before the new one is created.

**Verdict: PASS WITH CHANGES** — apply the 1-line fix to `startup()` to store its subscription in `connectionStateTask`, clean up review-reference comments before merge.