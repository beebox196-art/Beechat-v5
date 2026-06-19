# FR-002 Tap-to-Reconnect — Kieran Spec Review

**Date:** 2026-06-19
**Reviewer:** Kieran
**Verdict:** PASS WITH CHANGES
**Spec:** Docs/Specs/Active/FR-002-TAP-TO-RECONNECT.md

## Findings

### [MAJOR] Race condition: rapid taps can fire multiple reconnect attempts

The spec's success criterion #6 says "only one reconnect attempt fires (guard on `syncBridge != nil` after stop)". The proposed `reconnect()` code does guard on `guard syncBridge != nil else { return }`, but this guard is insufficient because `syncBridge` is only set to `nil` never — the method sets `self.syncBridge = bridge` (the new bridge) at the end of the happy path. Between the initial guard and the `await bridge.stop()` call, there is an suspension point where another tap can enter. The flow:

1. Tap 1 enters `reconnect()`, passes `guard syncBridge != nil` (old bridge exists)
2. Tap 1 sets `connectionState = .connecting`
3. Tap 1 hits `await bridge.stop()` — **suspends**
4. Tap 2 enters `reconnect()`, passes `guard syncBridge != nil` (old bridge still there — we haven't replaced it yet)
5. Tap 2 sets `connectionState = .connecting` (no-op, already connecting)
6. Tap 2 hits `await bridge.stop()` on the same old bridge
7. Both proceed to create new bridges, second one overwrites first in `self.syncBridge`

The `isTappable` check in `GatewayStatusBar` helps (`connectionState == .connecting` is not tappable), but there's a window between the tap landing and `connectionState` being set to `.connecting` inside the `Task` — the `Task` is async, so the state update doesn't happen synchronously with the tap.

**Required change:** Add a re-entrancy guard at the top of `reconnect()` that checks `connectionState` before the Task launches, AND set the state synchronously before the first await:

```swift
func reconnect() {
    guard syncBridge != nil else { return }
    guard connectionState != .connecting && connectionState != .handshaking else { return }
    connectionState = .connecting  // Set synchronously before any await
    
    Task {
        // ... rest of the body, remove the early connectionState = .connecting line
    }
}
```

This closes the window: the state is set synchronously on the main actor before any suspension point, and the second guard prevents re-entry while a reconnect is in flight. The `isTappable` check in `GatewayStatusBar` then becomes a second layer of defense rather than the primary guard.

---

### [MAJOR] Old `connectionStateStream` subscription is never cancelled — potential state clobbering

The spec acknowledges the old `connectionStateStream` subscription in `startup()` finishes "naturally when the old bridge's event stream closes." This is partially correct but has a subtle problem.

Looking at the actual code in `SyncBridge.stop()`:
```swift
public func stop() async {
    eventProcessingTask?.cancel()
    reconnectWatchTask?.cancel()
    connectionWatchTask?.cancel()
    // ...
    await config.gatewayClient.disconnect()
}
```

And `GatewayClient.disconnect()`:
```swift
public func disconnect() async {
    eventContinuation?.finish()
    // ...
    updateState(.disconnected)
}
```

When `disconnect()` calls `updateState(.disconnected)`, all registered state observers fire — including the one from the old bridge's `connectionStateStream()`. This means the old subscription's `for await state in stream` loop will receive `.disconnected` and set `self.connectionState = .disconnected` — potentially overwriting the `.connecting` state that `reconnect()` just set, or clobbering a `.connected` state from the new bridge if timing is unlucky.

The old stream will then finish (the continuation finishes), so the old subscription loop ends. But the last value it emits (`.disconnected`) can race with the new bridge's state updates.

**Required change:** Cancel the old subscription explicitly. Store the old subscription's Task and cancel it before creating the new bridge:

```swift
// In AppState, add a property:
private var connectionStateTask: Task<Void, Never>?

// In reconnect(), after bridge.stop():
connectionStateTask?.cancel()
connectionStateTask = nil

// When creating the new subscription:
connectionStateTask = Task {
    let stream = await bridge.connectionStateStream()
    for await state in stream {
        self.connectionState = state
    }
}
```

The same should be applied to `startup()` for consistency. This ensures the old observer is removed before the new one starts writing state.

---

### [MINOR] `bridge.stop()` does not throw — error handling path is unreachable

The spec's review checklist asks "what if `bridge.stop()` throws?" Looking at the actual `SyncBridge.stop()` signature:

```swift
public func stop() async {
```

It's `async` but not `throws`. It cannot throw. The spec's code calls `await bridge.stop()` without try/catch, which is correct. But the review checklist item is misleading — it implies `bridge.stop()` could throw and needs handling. It cannot.

**Required change:** No code change needed. Remove the review checklist item "what if `bridge.stop()` throws?" — it's a non-issue. The spec should note that `stop()` is non-throwing by design.

---

### [MINOR] Missing edge case: `startup()` hasn't run yet

The spec mentions `hasStarted` guard in `startup()` but doesn't address what happens if `reconnect()` is called before `startup()` completes. In that case:
- `syncBridge` is `nil` (startup hasn't created it yet)
- The `guard syncBridge != nil else { return }` catches this — silent return, no reconnect

This is safe but the UX is poor: if the status bar shows "Initialising…" and the user taps, nothing happens and there's no feedback. However, `GatewayStatusBar` only shows the arrow icon when `connectionState == .disconnected || .error`, and during startup the state is `.disconnected` (set before `bridge.start()`). So the arrow would show and the bar would be tappable, but the tap would silently fail.

**Required change:** Add a guard on `isStartupComplete` in `reconnect()`:

```swift
guard isStartupComplete else { return }
```

Or alternatively, make `isTappable` in `GatewayStatusBar` also check `appState.isStartupComplete`:

```swift
private var isTappable: Bool {
    appState.isStartupComplete && (connectionState == .disconnected || connectionState == .error)
}
```

The latter is better — it prevents the arrow from showing during initialisation, so the user never sees a tappable control that doesn't work.

---

### [MINOR] `DatabaseManager.shared` may not be open if `startup()` failed early

The spec says "Reuses `DatabaseManager.shared` (already open from startup)". But if `startup()` threw during database opening (the outer `catch` block in `startup()`), `DatabaseManager.shared` may not have a valid open database. `reconnect()` creates a `BeeChatPersistenceStore(dbManager: DatabaseManager.shared)` with an unopened DB, which would then fail at `bridge.start()` when the persistence layer tries to use it. The error would be caught by the `catch` block and shown to the user, but the error message would be confusing (something about database, not gateway).

This is a low-probability edge case — if the DB didn't open, the app is in a broken state anyway. But the spec should acknowledge it.

**Required change:** Add a note in the spec that `reconnect()` assumes `startup()` successfully opened the database. If startup failed at the DB level, reconnect will fail with a persistence error, which is acceptable (the app is already in a degraded state). No code change needed, but document the assumption.

---

### [MINOR] `TopicServer` port conflict on reconnect

`SyncBridge.start()` creates a `TopicServer` on macOS, and `SyncBridge.stop()` stops it. But `TopicServer.start()` logs and continues if port 8976 is occupied (by design — see the code). If the old `TopicServer` hasn't fully released the port before the new one starts, the new one will silently fail to bind, and iPhone sync will break after reconnect.

Looking at `TopicServer.start()`:
```swift
guard listener == nil else { return }
```

And `stop()` sets `listener = nil`. So if `stop()` is called before `start()`, the port should be released. But NWListener release is asynchronous — there may be a brief window where the port isn't freed yet.

This is a pre-existing issue in the codebase, not introduced by this spec. But reconnect makes it more likely to surface because it cycles the bridge while the app is running.

**Required change:** No spec change needed. Flag as a known risk in the spec's Notes section. If it surfaces during testing, Q should add a small delay or retry in `TopicServer.start()` — but that's out of scope for FR-002.

---

### [NIT] Spec code creates `GatewayClient` with default `clientMode: "webchat"` but startup uses `"webchat"` explicitly

In the spec's `reconnect()` code:
```swift
let gatewayClient = GatewayClient(config: gatewayConfig, tokenStore: tokenStore)
```

The `GatewayClient.Configuration` init has `clientMode: String = "webchat"` as a default. The `loadGatewayConfig` method in `AppState` sets `clientMode: "webchat"` explicitly. This is consistent — no issue. Just confirming the spec's code matches existing patterns.

**Required change:** None. Verified consistent.

---

### [NIT] Spec's line count estimate is realistic

The spec says ~40 lines across 2 files. Counting the actual code:
- `reconnect()` method: ~30 lines
- `GatewayStatusBar` changes (isTappable, arrow icon, contentShape, onTapGesture, accessibility): ~10 lines modified/added
- Total: ~40 lines

This is accurate. No scope creep risk. The spec's out-of-scope section is clear and appropriate.

**Required change:** None.

---

### [NIT] `connectionState = .connected` set prematurely

In the spec's `reconnect()` code:
```swift
try await bridge.start()
connectionState = .connected
```

But `bridge.start()` also starts a `connectionStateStream` subscription internally (for reconnect watch and connection watch). The `connectionStateStream()` subscription in `reconnect()` will also yield `.connected` when the bridge connects. So `connectionState` is set to `.connected` twice — once explicitly, once via the stream. This is harmless (idempotent) but slightly redundant.

The existing `startup()` code does the same thing, so this is consistent with the existing pattern. Not a problem, just an observation.

**Required change:** None. Consistent with existing code.

---

## Summary

The spec is well-scoped, minimal, and follows existing patterns correctly. The ~40-line estimate is accurate and there's no scope creep. The iOS reference implementation confirms the UX pattern. The main concerns are:

1. **Race condition on rapid taps** (MAJOR) — needs a synchronous state guard before the Task to prevent multiple concurrent reconnect attempts. The current `guard syncBridge != nil` is insufficient because the old bridge isn't replaced until late in the flow.

2. **Old connection state stream clobbering** (MAJOR) — the old `connectionStateStream` subscription in `startup()` will receive a final `.disconnected` from the old bridge's `stop()` call, which can race with the new bridge's state updates. Needs explicit cancellation of the old subscription task.

3. **Tappable during initialisation** (MINOR) — the arrow icon shows during startup before the bridge is ready, but tapping silently fails. Guard on `isStartupComplete` in `isTappable`.

4. **TopicServer port release timing** (MINOR) — pre-existing risk, just document it.

The remaining items are nits or non-issues. Once the two MAJOR findings are addressed, this is safe to implement. The blast radius is small — only `AppState` and `GatewayStatusBar` are touched, no changes to `SyncBridge`, `GatewayClient`, or persistence layers. No existing tests will break (there are no tests for these files).

**Verdict: PASS WITH CHANGES** — address the two MAJOR findings before implementation. The MINOR findings should be addressed during implementation but don't block the spec.