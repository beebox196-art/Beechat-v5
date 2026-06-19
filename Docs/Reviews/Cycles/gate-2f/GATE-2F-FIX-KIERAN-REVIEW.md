# Kieran Review: GATE-2F-FIX Safe Startup Reconcile

**Reviewer:** Kieran (adversarial)  
**Date:** 2026-05-26  
**Spec:** GATE-2F-FIX-SAFE-RECONCILE.md  
**Verdict:** ✅ Safe to implement, with one required change and two recommendations

---

## 1. Spec vs Implementation Alignment

### Root Cause — Confirmed

The spec correctly identifies the root cause. `reconcileAllTopicState()` (line 861) iterates all local topics and calls `publishTopicState()` for each one with a `sessionKey`. `publishTopicState()` (line 775) fires `sessionsPluginPatch` and `sessionsPatch` RPCs. If the session no longer exists on the gateway, these fail with `INVALID_REQUEST`, but the reconcile loop doesn't stop — it continues for every stale topic. With 30+ subagent sessions in a typical local DB, this floods the WebSocket within ~1 second.

The fix is correctly targeted: filter before you send, not after.

### `sessionsList()` — Verified

The spec claims `sessionsList()` "already exists in the gateway client." Verified:

- `RPCClientProtocol` (RPCClient.swift:6) declares `func sessionsList() async throws -> [SessionInfo]`
- `RPCClient` (RPCClient.swift:41) implements it, calling `gateway.call(method: "sessions.list", params: [:])`
- `SessionInfo` (SessionInfo.swift:5) has a `key: String` property
- `SyncBridge` already calls `sessionsList()` in `fetchSessions()` (line 104) and in `Reconciler.reconcile()` (Reconciler.swift:20)

**No new gateway endpoint needed. Confirmed.**

---

## 2. Proposed Changes — Detailed Review

### Change 1: `fetchActiveSessionKeys()` on SyncBridge

```swift
public func fetchActiveSessionKeys() async -> Set<String> {
    do {
        let sessions = try await rpcClient.sessionsList()
        return Set(sessions.map { $0.key })
    } catch {
        print("[SyncBridge] fetchActiveSessionKeys failed: \(error) — skipping reconcile")
        return []
    }
}
```

**Assessment:** ✅ Sound.

- Failure mode is safe: returns empty set → reconcile publishes nothing → no flood.
- This is the same RPC call already used in `fetchSessions()`, so there's no new dependency.
- Minor note: `SyncBridge` is an actor, so this method runs on the actor's executor. Since it's `async` and calls an `async` RPC, this is fine — no blocking concerns.

**One concern:** The spec shows this called from `AppRootView.swift` as:
```swift
Task {
    let activeSessionKeys = await bridge.fetchActiveSessionKeys()
    await bridge.reconcileAllTopicState(filteringTo: activeSessionKeys)
}
```

Since `SyncBridge` is an actor, `reconcileAllTopicState` is actor-isolated. The `await` is correct. But there's a **TOCTOU race**: between `fetchActiveSessionKeys()` returning and `reconcileAllTopicState(filteringTo:)` executing, sessions could be created or destroyed on the gateway. This is acceptable because:
- A new session appearing means we skip it (harmless — the next `sessions.changed` event triggers a reconcile for it).
- A session disappearing means we try to publish for a dead session (same failure mode, but only for sessions that died in the ~100ms window — far better than the current 30+ failures).

**Verdict: Acceptable TOCTOU, no change needed.**

### Change 2: Modified `reconcileAllTopicState(filteringTo:)`

The spec proposes a new overload with `activeKeys: Set<String>? = nil`:

```swift
public func reconcileAllTopicState(filteringTo activeKeys: Set<String>? = nil) {
    // ...
    if let keys = activeKeys, !keys.contains(sessionKey) {
        print("[SyncBridge] reconcileAllTopicState: skipping \(topic.name) — session \(sessionKey) not active")
        continue
    }
    // ...
}
```

**Assessment:** ✅ Sound, with one required change.

**REQUIRED CHANGE — `Task.detached` should be `Task`, not `Task.detached`:**

The current implementation uses `Task.detached` (line 864). This means:
1. It inherits no actor context from `SyncBridge`.
2. `TopicRepository(dbManager: DatabaseManager.shared)` is called inside the detached task, which is fine (DatabaseManager is a singleton).
3. `self.publishTopicState(topic:sessionKey:)` is called via `await self.publishTopicState(...)` — since `SyncBridge` is an actor, this re-hops onto the actor's executor for each call.

However, the real issue is: **`Task.detached` means the reconcile cannot be cancelled by the caller**. If the app disconnects or the bridge stops during reconcile, the detached task keeps running until completion. This isn't a regression (the current code already uses `Task.detached`), but it's worth noting.

**More importantly:** The `publishTopicState` method already enqueues via `TopicPublishQueue` (an actor), which serialises per-session-key. The concurrent task group with `active >= 5` throttling is therefore partially redundant with the queue. But this is existing behaviour, not introduced by this spec.

**My recommendation (not blocking):** Replace `Task.detached` with `Task` so the reconcile is scoped to the actor and cancellable. But this is pre-existing, so don't mix it into this change.

### Change 3: `didReceiveSessionChange` filter

The spec proposes:
```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    Task { @MainActor in
        let activeKeys = Set(sessionKeys)
        await bridge.reconcileAllTopicState(filteringTo: activeKeys)
    }
}
```

**Assessment:** ⚠️ **Requires a critical fix.**

Looking at the actual event flow in `EventRouter.handleSessionsChanged()` (line 137):

```swift
private func handleSessionsChanged() async throws {
    let sessions = try await syncBridge.fetchSessions()
    let sessionKeys = sessions.map { $0.id }
    await syncBridge.delegate?.syncBridge(syncBridge, didReceiveSessionChange: sessionKeys)
}
```

The `sessionKeys` parameter is `[String]` built from `sessions.map { $0.id }`. But `fetchSessions()` already **filters** sessions through `sessionShouldAppearByDefault()` (line 85), which excludes sessions with zero tokens unless they're `agent:main:main`. So `sessionKeys` is **not** the full set of active gateway sessions — it's the subset that appears in the sidebar.

This means using `Set(sessionKeys)` as the filter for `reconcileAllTopicState` would **skip topics whose sessions exist on the gateway but don't pass the visibility filter**. For example, a subagent session that has received messages (totalTokens > 0) would be included, but one with zero messages wouldn't — even though its session key is perfectly valid on the gateway.

**Why this matters for the fix:** If a subagent session exists on the gateway (is active) but has no messages yet (totalTokens = 0), it would be excluded from the filter, and we'd skip publishing its topic metadata. This is probably fine for the UI (it wouldn't appear anyway), but it creates an inconsistency: the topic exists locally with a session key, the session exists on the gateway, but we skip syncing its metadata. If that session later gets messages, its metadata wouldn't be synced until the next `sessions.changed` event.

**Required fix for Change 3:** Use `fetchActiveSessionKeys()` (which calls `sessionsList()` unfiltered) instead of the filtered `sessionKeys`:

```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    Task { @MainActor in
        let activeKeys = await bridge.fetchActiveSessionKeys()
        await bridge.reconcileAllTopicState(filteringTo: activeKeys)
    }
}
```

Alternatively, if the spec's approach of using `sessionKeys` directly is preferred for performance (avoids an extra RPC), then add a comment explicitly documenting the trade-off: we skip zero-token sessions, which is acceptable because they have no UI presence anyway. But the safer approach is to fetch the full list.

**I recommend the `fetchActiveSessionKeys()` approach.** It's one extra RPC call, but it happens only on `sessions.changed` events (infrequent), not on every startup. The safety of having the complete active set outweighs the marginal cost.

---

## 3. Edge Cases & Race Conditions

### Edge Case A: Empty topics table on first launch

- `fetchAllActive()` returns `[]` → reconcile completes immediately with zero publishes.
- **Verdict:** ✅ Safe. No stale sessions, no flood.

### Edge Case B: Gateway offline during startup

- `fetchActiveSessionKeys()` throws → returns `[]` → reconcile publishes nothing.
- **Verdict:** ✅ Safe. No flood. Topics will sync on reconnection via `sessions.changed` event (which triggers `didReceiveSessionChange`).

### Edge Case C: All local topics are stale subagent sessions

- `fetchActiveSessionKeys()` returns e.g. `{agent:main:main}` → reconcile skips all subagent topics.
- **Verdict:** ✅ Correct. These sessions don't exist on the gateway, so publishing would fail anyway.

### Edge Case D: Session created between `fetchActiveSessionKeys()` and `reconcileAllTopicState()`

- Already addressed in Section 2 (TOCTOU). New sessions will be picked up on the next `sessions.changed` event.

### Edge Case E: `sessions.changed` event fires during startup reconcile

- `didReceiveSessionChange` would call `reconcileAllTopicState(filteringTo:)` again while the first call is still running.
- Both would filter through `TopicPublishQueue` which serialises per session key, so there's no data race.
- Double-publishing is idempotent (same metadata, same session key), so this is safe.
- **Verdict:** ✅ Safe. Minor wasted bandwidth but no correctness issue.

### Edge Case F: Topic with nil sessionKey

- Already handled: `guard let sessionKey = topic.sessionKey else { continue }` skips topics without a session key.
- **Verdict:** ✅ Safe.

### Edge Case G: `publishTopicState` runtime guard

- The existing guard at line 782 checks `topic.id.lowercased() != keySuffix?.lowercased()` and skips publishing if they don't match.
- This is an additional safety layer independent of the filter.
- **Verdict:** ✅ Good defence in depth.

---

## 4. Safety Assessment for Mac App

### Will this break the Mac app?

**No.** Here's why:

1. **Existing `reconcileAllTopicState()` with no filter remains unchanged.** The spec adds a new overload with `activeKeys: Set<String>? = nil`. Passing `nil` preserves original behaviour. The existing call site in `didReceiveSessionChange` (line 291) currently calls `reconcileAllTopicState()` with no arguments, and this will need to be updated — but the default parameter means existing callers (if any) are not broken.

2. **The startup call is currently removed (reverted).** The spec restores it with a filter. If the filter works correctly, this is strictly safer than the original. If the filter somehow fails, `fetchActiveSessionKeys()` returns `[]` and nothing is published — which is the same as the current reverted state (no startup reconcile). **The worst case is equivalent to the status quo.**

3. **No gateway protocol changes.** Uses existing `sessions.list` RPC.

4. **No database schema changes.**

5. **No UI changes.** The observer and view layer are not modified except for passing the filter.

### What could go wrong?

1. **Performance regression on startup:** One extra `sessions.list` RPC call. This is already called in `fetchSessions()` during `start()`, so the gateway can serve it from cache. Negligible impact.

2. **Stale filter if gateway sessions change rapidly:** Already addressed — `sessions.changed` events trigger re-reconcile. The startup filter is a best-effort snapshot.

3. **If `fetchActiveSessionKeys()` is slow (network timeout), startup is delayed.** The `Task {}` wrapping means it's async and non-blocking to the UI. But the reconcile won't run until it completes. This is acceptable — the alternative (running reconcile without a filter) is worse.

---

## 5. Recommendations (Non-Blocking)

### R1: Cache `knownSessionKeys` from `fetchSessions()`

`SyncBridge` already maintains `knownSessionKeys: Set<String>` (line 34), populated in `fetchSessions()` (line 114). Instead of making a separate `sessionsList()` call in `fetchActiveSessionKeys()`, consider reusing this cache:

```swift
public func fetchActiveSessionKeys() async -> Set<String> {
    // If we already have keys from fetchSessions(), use them
    if !knownSessionKeys.isEmpty {
        return knownSessionKeys
    }
    // Otherwise, fetch fresh
    do {
        let sessions = try await rpcClient.sessionsList()
        return Set(sessions.map { $0.key })
    } catch {
        return []
    }
}
```

**Trade-off:** `knownSessionKeys` is filtered by `sessionShouldAppearByDefault()`, which has the same problem as Change 3's `sessionKeys` — it excludes zero-token sessions. To make this safe, you'd need to store the unfiltered set separately. This is a good follow-up but not worth blocking this fix.

### R2: Log the skip reason with the session key pattern

For debugging, when skipping a topic, log whether the session key looks like a subagent session (`agent:main:*:subagent:*`) vs a stale main session. This helps future debugging.

### R3: Consider throttling `didReceiveSessionChange` → reconcile

If `sessions.changed` fires rapidly (e.g., bulk session creation), each event triggers a full reconcile. The `TopicPublishQueue` serialises per-key, but the reconcile still iterates all topics each time. A debounce (e.g., 500ms) would be a good follow-up.

---

## 6. Summary

| Item | Status | Action |
|------|--------|--------|
| `sessionsList()` exists and works | ✅ Verified | None |
| `fetchActiveSessionKeys()` | ✅ Sound | Implement as spec |
| `reconcileAllTopicState(filteringTo:)` | ✅ Sound | Implement as spec |
| Change 3: `didReceiveSessionChange` filter | ⚠️ **Fix needed** | Use `fetchActiveSessionKeys()` instead of `sessionKeys` from delegate parameter, OR document the trade-off explicitly |
| Startup reconcile in AppRootView | ✅ Safe | Implement as spec |
| TOCTOU between fetch and reconcile | ✅ Acceptable | No change needed |
| Mac app breakage risk | ✅ None | Worst case = status quo (no reconcile) |
| New gateway endpoint needed | ✅ No | Uses existing `sessions.list` |

**Overall verdict: ✅ Safe to implement, with the Change 3 fix.**

The spec is well-reasoned, correctly identifies the root cause, and proposes a minimal fix with safe failure modes. The one required change is to Change 3: don't trust the `sessionKeys` parameter from `didReceiveSessionChange` as a complete filter, because it's pre-filtered by `sessionShouldAppearByDefault()`. Use `fetchActiveSessionKeys()` (unfiltered `sessions.list`) instead.