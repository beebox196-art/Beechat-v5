# GATE-2F: Mac-Side Topic Publishing via `chat.inject`

**Date:** 2026-05-28
**Status:** REVIEWED — Q approved with warnings, Kieran conditional pass. Both critical issues (debounce logic, Date encoding) fixed in spec. Session bootstrapping added per Kieran C1.
**Scope:** Mac app ONLY (no iPhone changes — iPhone sync receiver is already built and deployed)
**Risk:** HIGH — touches the Mac app, which is the primary comms channel
**Constraint:** Must NOT affect Mac app messaging, topic list, or UI in any visible way. Changes are additive only.

---

## 1. Problem

The iPhone (Gate 2B5 Phase 2) can read a topic list payload from the `agent:main:beechat-sync` session. But the Mac never writes anything there.

The existing `publishTopicState()` method uses `sessionsPluginPatch` to write metadata on **individual gateway sessions**. This is broken — the gateway rejects `sessionsPluginPatch` for sessions without the `beechat` plugin registered. That's why all the call sites are commented out.

**We need a different approach:** bulk publish the entire topic list as a single JSON message into the sync session via `chat.inject`. This bypasses `sessionsPluginPatch` entirely — no plugin registration needed. The gateway is a dumb pipe storing one message in one session.

---

## 2. Solution

### 2A. New method: `publishTopicList()` on SyncBridge

Add a new method to `SyncBridge.swift` that:
1. Fetches all active (non-archived) topics from the Mac's GRDB database
2. Serialises them as a JSON payload matching the format the iPhone expects
3. Ensures the sync session exists (bootstraps if needed)
4. Injects the payload into `agent:main:beechat-sync` via `rpcClient.chatInject()`

```swift
/// Publishes the Mac's complete topic list to the sync session so the iPhone can discover them.
/// Uses `chat.inject` — no plugin registration needed.
/// Trailing-edge debounced to avoid rapid-fire publishes during bulk topic changes.
public func publishTopicList() {
    // Implementation detail — see §4
}
```

### 2B. Payload format (must match iPhone's `TopicSyncPayload`)

```json
{
  "v": 1,
  "timestamp": "2026-05-28T14:30:00Z",
  "topics": [
    {
      "id": "<topic-uuid>",
      "name": "Project Status",
      "sessionKey": "agent:main:main",
      "isArchived": false,
      "lastActivityAt": "2026-05-28T14:00:00Z",
      "lastMessagePreview": "Build succeeded"
    }
  ]
}
```

- `v`: version field, always `1` for now
- `timestamp`: ISO 8601 UTC (Z suffix) — when the payload was generated
- `topics`: array of active topics. **Excludes archived topics** — the iPhone treats missing topics as archived (origin = "mac").
- Each topic: `id` (UUID), `name` (display name), `sessionKey` (gateway key), `isArchived` (always false here since we filter), `lastActivityAt` (ISO 8601), `lastMessagePreview` (first line of last message, or nil)

### 2C. Debounce (trailing-edge)

A **30-second trailing-edge debounce** prevents rapid-fire publishes during topic create/edit/archive/delete sequences:
- Each call to `publishTopicList()` cancels any pending publish and schedules a new one 30s later
- Only the *last* call in a burst actually publishes — intermediate calls are absorbed
- This means a burst of create → rename within 30s results in one publish with the final state, not zero publishes

**Important:** This is NOT a simple throttle (skip-if-within-30s). It's trailing-edge debounce (reschedule-on-each-call). See §4.2 for implementation.

**Review note (Q W1, Kieran B1):** The original spec had a throttle (skip if within 30s of last publish) which would silently drop calls. This is now corrected to proper trailing-edge debounce using `Task` cancellation.

### 2D. Safety guards

| Guard | Behaviour |
|-------|-----------|
| No topics in DB | Don't publish anything (empty payload would archive all iPhone topics) |
| `chat.inject` fails | Log error, don't crash — iPhone works fine with stale data |
| `ensureSyncSessionExists()` fails | Log error, skip publish — will retry on next trigger |
| Gateway not connected | Log error, don't crash — retry on next trigger |
| Payload > 50KB | Truncate to 50 topics (sanity limit — normal use is <20) |

### 2E. Session bootstrapping (critical)

**Problem:** `chat.inject` requires the target session to already exist. The gateway returns `"session not found"` if the session key doesn't correspond to an existing session. On first launch (or after a gateway reset), `agent:main:beechat-sync` may not exist.

**Evidence:** Gateway source code at `chat-CiJszmF6.js` line 2631:
```js
const { cfg, storePath, entry, canonicalKey: sessionKey } = loadSessionEntry(rawSessionKey);
const sessionId = entry?.sessionId;
if (!sessionId || !storePath) {
    respond(false, void 0, errorShape(ErrorCodes.INVALID_REQUEST, "session not found"));
    return;
}
```
`chat.inject` does NOT auto-create sessions. It fails with `INVALID_REQUEST` if the session doesn't exist.

**Solution:** Before the first `chat.inject`, check if the sync session exists by calling `sessionsList()`. If it's not found, bootstrap it with a `chat.send` (which auto-creates sessions). After that, all subsequent publishes use `chat.inject`.

```swift
/// Ensures the sync session exists before injecting.
/// chat.inject requires the session to already exist; chat.send auto-creates.
/// Returns true if the session exists or was successfully created.
private func ensureSyncSessionExists() async throws -> Bool {
    // 1. Check if the session already exists
    let sessions = try await rpcClient.sessionsList()
    if sessions.contains(where: { $0.key == "agent:main:beechat-sync" }) {
        return true // Session exists, proceed with chat.inject
    }
    
    // 2. Bootstrap: send a message to create the session
    // chat.send auto-creates sessions; chat.inject does not
    _ = try await rpcClient.sendMessage(
        sessionKey: "agent:main:beechat-sync",
        message: "[beechat-sync-bootstrap]"
    )
    print("[SyncBridge] Bootstrapped sync session via chat.send")
    return true
}
```

**Why `chat.send` for bootstrapping?** The gateway auto-creates sessions on `chat.send` but returns `"session not found"` on `chat.inject` for non-existent sessions. The bootstrap message is a one-time cost — after the session exists, all subsequent publishes use `chat.inject` (no agent run, just transcript injection). The bootstrap message will trigger an agent run, but that's acceptable as a one-time cost on first launch.

---

## 3. Trigger points (when to call `publishTopicList()`)

### 3A. On Mac app startup (after bridge start)

After `bridge.start()` completes and the initial session fetch finishes, publish the current topic list. This ensures the iPhone gets the latest data when the Mac app launches.

**Where:** `AppRootView.swift`, after the existing `bridge.start()` succeeds.

### 3B. On topic create (in MainWindow)

After a new topic is created and its gateway session exists, publish the updated list.

**Where:** `MainWindow.swift`, inside the `createTopic` action, after `bridge.sendMessage()` succeeds.

### 3C. On topic edit/rename (in MainWindow)

After a topic's name is saved locally, publish the updated list.

**Where:** `MainWindow.swift`, inside `saveTopicEdits()`, after `repo.save(updatedTopic)`.

### 3D. On topic archive/unarchive (in MainWindow or TopicViewModel)

After a topic's `isArchived` flag changes, publish the updated list.

**Where:** `MainWindow.swift` or the relevant action, after the archive save completes.

### 3E. On topic delete (in MainWindow)

After a topic is deleted locally (and its gateway metadata is cleared if applicable), publish the updated list.

**Where:** `MainWindow.swift`, inside `deleteTopic()`, after `topicRepo.deleteCascading(id)`.

### 3F. On `sessions.changed` event

When the gateway reports session changes (e.g., session resets), re-publish the topic list in case a session key has changed.

**Where:** `SyncBridgeObserver.swift`, inside `didReceiveSessionChange()`.

---

## 4. Implementation details

### 4.1 Files changed

| File | Change |
|------|--------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Add `publishTopicList()`, `performPublish()`, `ensureSyncSessionExists()` methods + debounce state |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Add `TopicSyncItem` and `TopicListPayload` structs |
| `Sources/App/AppRootView.swift` | Call `bridge.publishTopicList()` after startup |
| `Sources/App/UI/MainWindow.swift` | Call `bridge.publishTopicList()` after topic CRUD |
| `Sources/App/UI/Observers/SyncBridgeObserver.swift` | Call `bridge.publishTopicList()` in `didReceiveSessionChange` |

### 4.2 `publishTopicList()` implementation sketch

```swift
/// Trailing-edge debounce: cancels any pending publish and reschedules.
/// This means a burst of calls (create → rename within 30s) results in exactly
/// one publish at the END of the burst, not zero publishes.
private var publishTask: Task<Void, Never>?

public func publishTopicList() {
    // Cancel any pending publish and reschedule
    publishTask?.cancel()
    publishTask = Task { [weak self] in
        guard let self = self else { return }
        try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s trailing debounce
        guard !Task.isCancelled else { return }
        await self.performPublish()
    }
}

/// Actual publish logic — separated from debounce for clarity.
private func performPublish() async {
    // 1. Fetch active topics from local GRDB (limit: 50 — only publish what iPhone will see)
    let topicRepo = TopicRepository(dbManager: DatabaseManager.shared)
    guard let allTopics = try? topicRepo.fetchAllActive(limit: 50) else {
        print("[SyncBridge] performPublish: fetchAllActive failed")
        return
    }
    
    // 2. Filter: only topics with a gateway session key (local-only topics can't be synced)
    //    Archived topics are already excluded by fetchAllActive's filter
    let syncableTopics = allTopics.filter { $0.sessionKey != nil }
    guard !syncableTopics.isEmpty else {
        print("[SyncBridge] performPublish: no syncable topics — not publishing (safety: don't empty iPhone topic list)")
        return
    }
    
    // 3. Build payload items
    let items: [TopicSyncItem] = syncableTopics.map { topic in
        return TopicSyncItem(
            id: topic.id,
            name: topic.name,
            sessionKey: topic.sessionKey!,
            isArchived: false,
            lastActivityAt: topic.lastActivityAt,
            lastMessagePreview: topic.lastMessagePreview
        )
    }
    
    // 4. Serialise payload (ISO 8601 dates — must match iPhone's TopicSyncPayload decoder)
    //    CRITICAL: JSONEncoder defaults to encoding Date as Double (seconds since reference date).
    //    The iPhone decoder expects ISO 8601 strings. Must set .iso8601 explicitly.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let payload = TopicListPayload(
        v: 1,
        timestamp: ISO8601DateFormatter().string(from: Date()),
        topics: items
    )
    
    guard let jsonData = try? encoder.encode(payload),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
        print("[SyncBridge] performPublish: serialisation failed")
        return
    }
    
    // 5. Ensure sync session exists (chat.inject requires it)
    do {
        try await ensureSyncSessionExists()
    } catch {
        print("[SyncBridge] performPublish: failed to bootstrap sync session: \(error)")
        return
    }
    
    // 6. Inject into sync session
    do {
        _ = try await rpcClient.chatInject(
            sessionKey: "agent:main:beechat-sync",
            message: jsonString,
            label: "beechat-topic-sync"
        )
        print("[SyncBridge] performPublish: published \(items.count) topics to sync session")
    } catch {
        print("[SyncBridge] performPublish: chatInject failed: \(error)")
    }
}
```

### 4.3 Session bootstrapping

```swift
/// Ensures the sync session exists before injecting.
/// chat.inject requires the session to already exist; chat.send auto-creates.
/// Returns true if the session exists or was successfully created.
private func ensureSyncSessionExists() async throws -> Bool {
    // 1. Check if the session already exists
    let sessions = try await rpcClient.sessionsList()
    if sessions.contains(where: { $0.key == "agent:main:beechat-sync" }) {
        return true // Session exists, proceed with chat.inject
    }
    
    // 2. Bootstrap: send a message to create the session
    // chat.send auto-creates sessions; chat.inject does not
    _ = try await rpcClient.sendMessage(
        sessionKey: "agent:main:beechat-sync",
        message: "[beechat-sync-bootstrap]"
    )
    print("[SyncBridge] Bootstrapped sync session via chat.send")
    return true
}
```

### 4.4 Payload structs (local to SyncBridge)

```swift
/// Single topic item in the published topic list payload.
/// NOTE: `lastActivityAt` is `Date?` here but encodes as ISO 8601 string
/// because `JSONEncoder.dateEncodingStrategy = .iso8601` is set in `performPublish()`.
/// The iPhone decoder expects `String?` in ISO 8601 format.
struct TopicSyncItem: Codable {
    let id: String
    let name: String
    let sessionKey: String
    let isArchived: Bool
    let lastActivityAt: Date?
    let lastMessagePreview: String?
}

/// Top-level payload published to the sync session.
struct TopicListPayload: Codable {
    let v: Int
    let timestamp: String
    let topics: [TopicSyncItem]
}
```

### 4.5 Trigger wiring

**AppRootView.swift** — after bridge start:
```swift
try await bridge.start()
self.connectionState = .connected
self.isStartupComplete = true

// Publish topic list so iPhone can discover Mac topics
await bridge.publishTopicList()
```

**MainWindow.swift** — after topic create:
```swift
// Inside createTopic, after bridge.sendMessage succeeds:
await bridge.publishTopicList()
```

**MainWindow.swift** — after topic edit:
```swift
// Inside saveTopicEdits, after repo.save:
await bridge.publishTopicList()
```

**MainWindow.swift** — after topic delete:
```swift
// Inside deleteTopic, after topicRepo.deleteCascading:
await bridge.publishTopicList()
```

**SyncBridgeObserver.swift** — on session change:
```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    Task { @MainActor in
        // Re-publish topic list when sessions change
        await bridge.publishTopicList()
    }
}
```

---

## 5. Review findings addressed

| Issue | Source | Fix in spec |
|-------|--------|-------------|
| Debounce was a throttle, not a debounce | Q W1, Kieran B1 | ✅ Replaced with Task-based trailing-edge debounce |
| `Date?` encodes as Double, not ISO 8601 | Q W2, Kieran W3 | ✅ Added `encoder.dateEncodingStrategy = .iso8601` |
| `chat.inject` doesn't auto-create sessions | Kieran C1 | ✅ Added `ensureSyncSessionExists()` with `sessionsList` check + `chat.send` bootstrap |
| `fetchAllActive()` fetches 100 but payload caps at 50 | Kieran C2 | ✅ Changed to `fetchAllActive(limit: 50)` — fetch only what will be published |
| Sync session grows unbounded | Q C3, Kieran C3 | ⚠️ Accepted — iPhone reads latest only. Log if needed. |
| `sessions.changed` trigger is broad | Q C2, Kieran W2 | ⚠️ Accepted — debounce absorbs the frequency. |

---

## 6. What this does NOT change

- ❌ No changes to `publishTopicState()` (still commented out, still broken)
- ❌ No changes to `sessionsPluginPatch` (still not used)
- ❌ No changes to Mac topic UI, sidebar, or messaging
- ❌ No changes to gateway plugin registration
- ❌ No changes to the iPhone app (it already reads this payload)
- ❌ No changes to `reconcileAllTopicState()` (still commented out)

## 7. What this DOES change (additive only)

- ✅ One new public method on SyncBridge: `publishTopicList()`
- ✅ Two new private methods: `performPublish()`, `ensureSyncSessionExists()`
- ✅ Two new structs: `TopicSyncItem`, `TopicListPayload`
- ✅ 5 call sites wired into existing flows (startup, create, edit, delete, session change)
- ✅ All wrapped in `await` — non-blocking, fire-and-forget
- ✅ Trailing-edge debounce prevents rapid-fire calls
- ✅ If any call fails, the Mac app continues normally

---

## 8. Success criteria

1. Mac app compiles clean
2. Mac app launches and shows existing topics unchanged
3. Mac app sends/receives messages as before
4. `chat.inject` writes the topic list payload to `agent:main:beechat-sync`
5. After 30 seconds (debounce), the sync session contains the topic list
6. When iPhone reconnects, it sees the Mac topics
7. Sync session is bootstrapped on first launch (if it doesn't exist yet)

## 9. Verification plan

1. Build Mac app — confirm clean compile
2. Launch Mac app — verify existing topics and messaging work
3. Check gateway session `agent:main:beechat-sync` — should contain a JSON payload
4. Parse the payload — should have valid `v`, `timestamp`, and `topics` array with ISO 8601 dates
5. Create a new topic on Mac — verify `chat.inject` fires (after debounce)
6. Delete a topic on Mac — verify updated payload is published
7. Test first-launch scenario: delete `agent:main:beechat-sync` session, restart Mac app — verify session is bootstrapped and payload appears
8. Verify `lastActivityAt` values are ISO 8601 strings, not doubles
9. iPhone connects — should see Mac topics appear

---

## 10. Rollback

If anything goes wrong, revert the 5 call sites and remove `publishTopicList()`, `performPublish()`, `ensureSyncSessionExists()`, and the two structs from SyncBridge. The Mac app continues normally — the only effect is the iPhone won't see Mac topics.