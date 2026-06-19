# GATE-2F-FIX: Safe Startup Reconcile (Change 1 Revision)

**Created:** 2026-05-26  
**Status:** DRAFT — awaiting Kieran review  
**Priority:** High — blocks iOS sync, must not break Mac app  
**Parent:** GATE-2F-MAC-APP-WIRING (Change 1)

---

## Problem

The original Change 1 called `reconcileAllTopicState()` on startup, which iterates ALL local topics and publishes their metadata to the gateway. This caused the Mac app to show empty messages because:

1. Local DB contains topics with session keys for subagent sessions (e.g. `agent:main:02c13e0e-9413-4547-af36-1c660b2860e2`)
2. These sessions no longer exist on the gateway
3. The gateway rejects these with `INVALID_REQUEST — unknown session key`
4. The rapid-fire failures (30+ in under 1 second) flood the WebSocket connection
5. This causes the UI to display empty message states

**Change 1 was reverted.** Changes 2 and 3 remain in place and work correctly (they only fire for known active sessions).

---

## Root Cause

`reconcileAllTopicState()` in `SyncBridge.swift` (line 861) publishes for every topic with a session key, with no check whether that session still exists on the gateway. The `publishTopicState()` method (line 775) sends `sessionsPluginPatch` calls which fail for unknown sessions, but the failure doesn't stop the reconcile loop — it just logs and continues.

---

## Fix

### Option A: Filter by active sessions (recommended)

Before calling `reconcileAllTopicState()`, query the gateway's session list and build a set of active session keys. Then only publish topics whose `sessionKey` is in that set.

**Implementation:**

In `AppRootView.swift`, after `self.isStartupComplete = true`, replace the simple `reconcileAllTopicState()` call with:

```swift
// Safe startup reconcile: only publish topics whose sessions exist on the gateway
Task {
    let activeSessionKeys = await bridge.fetchActiveSessionKeys()
    await bridge.reconcileAllTopicState(filteringTo: activeSessionKeys)
}
```

**New method on SyncBridge:**

```swift
/// Fetches the set of currently active session keys from the gateway.
/// Returns an empty set on failure (safe default: don't publish if we can't verify).
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

**Modified `reconcileAllTopicState` with filter:**

```swift
public func reconcileAllTopicState(filteringTo activeKeys: Set<String>? = nil) {
    print("[SyncBridge] reconcileAllTopicState() called (filter: \(activeKeys?.count.description ?? "none"))")
    Task.detached { [weak self] in
        guard let self = self else { return }
        let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
        guard let topics = try? topicRepo.fetchAllActive() else { return }
        print("[SyncBridge] reconcileAllTopicState: found \(topics.count) topics")

        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for topic in topics {
                guard let sessionKey = topic.sessionKey else { continue }
                
                // If we have a filter set, skip topics whose session no longer exists
                if let keys = activeKeys, !keys.contains(sessionKey) {
                    print("[SyncBridge] reconcileAllTopicState: skipping \(topic.name) — session \(sessionKey) not active")
                    continue
                }
                
                group.addTask {
                    await self.publishTopicState(topic: topic, sessionKey: sessionKey)
                }
                active += 1
                if active >= 5 {
                    await group.next()
                    active -= 1
                }
            }
        }
        print("[SyncBridge] reconcileAllTopicState: completed")
    }
}
```

**Key properties:**
- `activeKeys = nil` → original behaviour (publish all, for backwards compatibility)
- `activeKeys = []` → publish nothing (safe if gateway query fails)
- `activeKeys = Set(...)` → only publish topics with matching sessions
- The `sessionsList()` RPC already exists in the gateway client — no new gateway endpoint needed

### Option B: Swallow errors silently (not recommended)

Add error handling in `publishTopicState()` to silently ignore `INVALID_REQUEST` responses. This prevents the flood but still wastes bandwidth on dead sessions.

**Why not recommended:** It masks a real problem (stale sessions) and doesn't address the root cause. Option A is cleaner because it never sends the request in the first place.

---

## Safety Properties

1. **Mac app is never blocked:** If `fetchActiveSessionKeys()` fails, we return an empty set and skip the reconcile entirely. No flood, no errors.
2. **No gateway changes needed:** Uses existing `sessionsList()` RPC.
3. **Changes 2 & 3 are unaffected:** They already only fire for sessions the user just created/edited — always active.
4. **Change 3 (`didReceiveSessionChange`) is also safe:** When the gateway tells us sessions changed, we re-reconcile. With the filter, we'll only publish for sessions that still exist.

---

## Change 3 Update Required

`SyncBridgeObserver.didReceiveSessionChange` currently calls `reconcileAllTopicState()` without a filter. It should also use the safe version:

```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    Task { @MainActor in
        // Use the provided sessionKeys as the filter — the gateway already told us which changed
        let activeKeys = Set(sessionKeys)
        await bridge.reconcileAllTopicState(filteringTo: activeKeys)
    }
}
```

This is even better than querying the session list — the gateway provides the changed keys directly.

---

## Verification

1. Build Mac app — compiles clean
2. Launch Mac app — existing topics work as before
3. Check Xcode console — should see `[SyncBridge] reconcileAllTopicState: skipping X — session not active` for stale sessions
4. Create a new topic — should publish to gateway
5. No `INVALID_REQUEST` errors in gateway log
6. No empty message states in the UI

---

## Files Changed

| File | Change |
|------|--------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Add `fetchActiveSessionKeys()`, modify `reconcileAllTopicState()` to accept optional filter |
| `Sources/App/AppRootView.swift` | Restore startup reconcile with session filter |
| `Sources/App/UI/Observers/SyncBridgeObserver.swift` | Update `didReceiveSessionChange` to pass session keys as filter |