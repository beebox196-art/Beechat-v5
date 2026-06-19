# SPEC: Concurrent Session Send & Streaming Fix

**Date:** 2026-04-30  
**Priority:** High — messages silently lost  
**Scope:** SyncBridge + MessageViewModel + SyncBridgeObserver + Reconciler + Tests  
**Risk:** Low — converting single-value guards to per-session dictionaries  
**Review:** Q ⚠️ NEEDS CHANGES · Kieran ⚠️ NEEDS CHANGES — both approved architecture, flagged 7 items (2 critical, 2 moderate, 3 minor). All incorporated below.  

---

## Problem

SyncBridge uses **global single-value guards** for send and streaming state. When two topics are active concurrently, the second one gets blocked or its state is corrupted.

### Bug 1: `isSending` is a global lock

```swift
private var isSending = false

guard !isSending else {
    throw SyncBridgeError.concurrentSendInProgress
}
isSending = true
defer { isSending = false }
```

- User sends to Topic A → `isSending = true`
- User sends to Topic B while A is still in flight → throws `concurrentSendInProgress`
- MessageViewModel retries after 100ms → if A is still going, retry also fails → **message silently lost**

### Bug 2: `currentStreamingSessionKey` is a single value

```swift
public private(set) var currentStreamingSessionKey: String?
```

- Topic A starts streaming → `currentStreamingSessionKey = "A"`
- Topic B starts streaming → `currentStreamingSessionKey = "B"` (overwrites A)
- `processChatFinal` for A checks `if currentStreamingSessionKey == "A"` → **false** → streaming state for A never clears
- `clearStalledStream` also uses the single value → can only clear whichever session wrote last
- `currentStreamingContent` computed property only returns content for the **one** tracked session

---

## Fix

Convert both single-value guards to **per-session dictionaries**. The actor isolation already ensures thread safety — no additional synchronization needed.

### Change 1: `isSending` → `sendingSessionKeys: Set<String>`

```swift
// BEFORE
private var isSending = false

guard !isSending else {
    throw SyncBridgeError.concurrentSendInProgress
}
isSending = true
defer { isSending = false }

// AFTER
private var sendingSessionKeys: Set<String> = []

guard !sendingSessionKeys.contains(sessionKey) else {
    throw SyncBridgeError.concurrentSendInProgress
}
sendingSessionKeys.insert(sessionKey)
defer { sendingSessionKeys.remove(sessionKey) }
```

**Effect:** Sending to Topic A no longer blocks Topic B. Only duplicate sends to the **same** topic are rejected (which is correct — prevents double-send from UI bug).

### Change 2: `currentStreamingSessionKey` → `streamingSessionKeys: Set<String>`

> **Kieran CRITICAL:** `abortGeneration` currently does `streamingBuffer.removeAll()` — wipes ALL sessions' buffers when aborting just one. Must become `removeValue(forKey: sessionKey)`.
>
> **Q:** `processAgentEvent` final/error handlers also need to remove from `streamingSessionKeys`, not just `currentStreamingSessionKey`.

```swift
// BEFORE
public private(set) var currentStreamingSessionKey: String?

// AFTER
public private(set) var streamingSessionKeys: Set<String> = []
```

All references update from single-value checks to set operations:

| Location | Before | After |
|---|---|---|
| `processChatDelta` | `currentStreamingSessionKey = sessionKey` | `streamingSessionKeys.insert(sessionKey)` |
| `processChatFinal` | `if currentStreamingSessionKey == sessionKey { currentStreamingSessionKey = nil }` | `streamingSessionKeys.remove(sessionKey)` |
| `processChatError` | same pattern | `streamingSessionKeys.remove(sessionKey)` |
| `clearStalledStream` | `guard let key = currentStreamingSessionKey` + `currentStreamingSessionKey = nil` | Iterate all streaming keys, clear each, or clear by sessionKey parameter |
| `abortGeneration` | `currentStreamingSessionKey = nil` + `streamingBuffer.removeAll()` | `streamingSessionKeys.remove(sessionKey)` + `streamingBuffer.removeValue(forKey: sessionKey)` |
| `stop()` | `currentStreamingSessionKey = nil` | `streamingSessionKeys.removeAll()` |
| `start()` reconnect | `reconcile(activeSessionKey: currentStreamingSessionKey)` | `reconcile(activeSessionKeys: Array(streamingSessionKeys))` |
| `start()` connection watch | `currentStreamingSessionKey != nil` | `!streamingSessionKeys.isEmpty` |

### Change 3: `Reconciler.reconcile` signature + implementation

Currently takes `activeSessionKey: String?`. Change to `activeSessionKeys: [String]` so reconciliation knows about all in-flight sessions.

```swift
// BEFORE
func reconcile(activeSessionKey: String?) async throws

// AFTER  
func reconcile(activeSessionKeys: [String]) async throws
```

> **Q:** Reconciler internally does `if let key = activeSessionKey { ... fetch one history ... }`. Must become a loop over `activeSessionKeys`, fetching history for each active stream. Update the internal implementation, not just the signature.

### Change 4: `clearStalledStream` → per-session + `clearAllStalledStreams` for broadcast

> **Kieran CRITICAL:** Connection-drop case must clear ALL streaming sessions, not just one. The old code relied on there only being one `currentStreamingSessionKey`. With concurrent sessions, we need both per-session and broadcast variants.

```swift
// Per-session — called by stall timer
internal func clearStalledStream(sessionKey: String, reason: String) async throws {
    guard streamingSessionKeys.contains(sessionKey) else { return }
    cancelStallTimer(for: sessionKey)
    streamingBuffer.removeValue(forKey: sessionKey)
    streamingSessionKeys.remove(sessionKey)
    try await fetchHistory(sessionKey: sessionKey)
    delegate?.syncBridge(self, didStopStreaming: sessionKey)
}

// Broadcast — called when connection drops
internal func clearAllStalledStreams(reason: String) async throws {
    let keys = streamingSessionKeys  // snapshot under actor isolation
    for key in keys {
        do {
            try await clearStalledStream(sessionKey: key, reason: reason)
        } catch {
            print("[SyncBridge] Stream cleanup error for \(key): \(error)")
        }
    }
}
```

Update `connectionWatchTask`:
```swift
// BEFORE
if state != .connected, currentStreamingSessionKey != nil {
    try await clearStalledStream(reason: "Connection lost while streaming")
}

// AFTER
if state != .connected, !streamingSessionKeys.isEmpty {
    try await clearAllStalledStreams(reason: "Connection lost while streaming")
}
```

### Change 5: Stall timer → per-session

Current `stallTimerTask` is a single task. Convert to `stallTimerTasks: [String: Task<Void, Never>]` so each session gets its own 30s timer.

```swift
// BEFORE
private var stallTimerTask: Task<Void, Never>?

private func resetStallTimer() {
    stallTimerTask?.cancel()
    stallTimerTask = Task { ... }
}

// AFTER
private var stallTimerTasks: [String: Task<Void, Never>] = [:]

private func resetStallTimer(for sessionKey: String) {
    stallTimerTasks[sessionKey]?.cancel()
    stallTimerTasks[sessionKey] = Task {
        try? await Task.sleep(nanoseconds: UInt64(Self.streamStallInterval * 1_000_000_000))
        guard !Task.isCancelled else { return }
        try? await clearStalledStream(sessionKey: sessionKey, reason: "Stream stalled - no delta for \(Int(Self.streamStallInterval))s")
    }
}

private func cancelStallTimer(for sessionKey: String) {
    stallTimerTasks[sessionKey]?.cancel()
    stallTimerTasks.removeValue(forKey: sessionKey)  // ← Q: remove entry to prevent timer dict leaks
}
```

> **Kieran MODERATE + Q:** `stop()` must cancel ALL stall timer tasks:
> ```swift
> for task in stallTimerTasks.values { task.cancel() }
> stallTimerTasks.removeAll()
> ```
> Add this to `stop()` alongside `streamingSessionKeys.removeAll()`.

### Change 6: `currentStreamingContent` → per-session

```swift
// BEFORE
public var currentStreamingContent: String {
    guard let key = currentStreamingSessionKey,
          let content = streamingBuffer[key] else { return "" }
    return content
}

// AFTER — needs sessionKey parameter
public func streamingContent(for sessionKey: String) -> String {
    return streamingBuffer[sessionKey] ?? ""
}
```

### Change 7: `SyncBridgeObserver` / UI layer

> **Q + Kieran:** The observer's streaming state is currently single-value (`isStreaming`, `streamingSessionKey`, `streamingContent`, `streamingPollTask`, `streamingTimeoutTask`). With concurrent sessions, `didStopStreaming` for one session resets global state even if another session is still streaming. The spec's original claim that the observer is "already per-session" was wrong — only `unreadCounts` is per-session.

The observer needs per-session streaming tracking. However, the **UI only shows one topic at a time**, so the observer only needs to poll streaming content for the **currently selected** session:

```swift
// SyncBridgeObserver streaming poll — use currentSelectedSessionKey
let content = await bridge.streamingContent(for: self.currentSelectedSessionKey ?? "")
```

The `isStreaming` / `streamingSessionKey` / `streamingContent` state in the observer tracks what's visible, not all active streams. This is correct — the user sees one topic at a time.

When `didStopStreaming(sessionKey:)` fires for a session that ISN'T the currently selected one, the observer should not reset its visible streaming state. Fix:
```swift
func syncBridge(_ bridge: SyncBridge, didStopStreaming sessionKey: String) {
    if sessionKey == currentSelectedSessionKey {
        isStreaming = false
        streamingContent = ""
        streamingPollTask?.cancel()
        streamingTimeoutTask?.cancel()
    }
    // If it's a different session, our visible state is unaffected
}
```

**Check:** Any UI code that reads `syncBridge.currentStreamingSessionKey` directly must be updated to use `syncBridge.streamingSessionKeys` or the new `streamingContent(for:)` method.

### Change 8: Remove `concurrentSendInProgress` retry hack from MessageViewModel

With per-session locking, cross-topic sends never hit this error. The retry with 100ms sleep can be removed — it was a workaround for the global lock:

```swift
// REMOVE this catch block:
} catch SyncBridgeError.concurrentSendInProgress {
    BeeChatLogger.log("[ThinkingBee] sendMessage — concurrent send, retrying in 100ms")
    try? await Task.sleep(nanoseconds: 100_000_000)
    _ = try await bridge.sendMessage(sessionKey: sessionKey, text: text)
}
```

Keep the error type itself for the edge case of double-send to the **same** topic — but surface it properly instead of silently retrying:

```swift
} catch SyncBridgeError.concurrentSendInProgress {
    BeeChatLogger.log("[ThinkingBee] sendMessage — duplicate send to same session blocked: \(sessionKey)")
    // Don't retry — this means the same topic is already sending, which is a UI bug
}
```

---

## Files Changed

| File | Change |
|---|---|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | isSending → sendingSessionKeys, currentStreamingSessionKey → streamingSessionKeys, per-session stall timers, clearStalledStream takes sessionKey, currentStreamingContent → streamingContent(for:) |
| `Sources/BeeChatSyncBridge/Reconciler.swift` | reconcile(activeSessionKey:) → reconcile(activeSessionKeys:), internal loop over active keys |
| `Sources/App/UI/ViewModels/MessageViewModel.swift` | Remove retry hack, replace with proper handling |
| `Sources/App/UI/Observers/SyncBridgeObserver.swift` | Per-session streaming: poll `streamingContent(for: currentSelectedSessionKey)`, guard `didStopStreaming` against wrong session resetting visible state |

---

## What Does NOT Change

- Gateway protocol — zero changes
- Database schema — zero changes
- RPC calls — zero changes (already work fine per-session)
- EventRouter routing logic — unchanged
- Delivery ledger — unchanged
- UI layout — unchanged (streaming indicator, bubbles, etc.)
- Any existing single-topic flow — behaves identically

---

## Validation

1. **Build:** `swift build -c release` — must pass
2. **Existing tests:** All Component 1-3 tests must still pass
3. **Test updates:** `SyncBridgeTests.swift` calls to `reconcile(activeSessionKey:)` → `reconcile(activeSessionKeys: [])` must be updated
3. **Manual test — single topic:** Send message → receive response → same as before
4. **Manual test — concurrent:** Open 2+ topics, send to both within seconds → both should get responses, no dropped messages
5. **Manual test — stall:** Leave a topic streaming >30s → per-session stall timer clears only that session's state, other topics unaffected

---

## Rollback

All changes are internal to SyncBridge actor. If something goes wrong, revert to single-value guards — the old code is straightforward and the bug only manifests when using multiple topics simultaneously.