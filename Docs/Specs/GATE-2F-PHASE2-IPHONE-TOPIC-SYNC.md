# Gate 2F Phase 2 — iPhone Topic Sync (Mac → iPhone)

**Status:** DRAFT — awaiting team review
**Author:** Bee
**Date:** 2026-05-23
**Predecessors:** Phase 0 (Shared Models ✅), Phase 1 (Mac Publishing ✅)

---

## Objective

When a topic is created, renamed, archived, or deleted on the Mac, the iPhone reflects that change within seconds. Same topics on both devices, like Telegram. Mac is master, iPhone is cache. Gateway is the conduit.

---

## Architecture Reminder

```
Mac (master) ──sessions.patch/pluginPatch──► Gateway ──sessions.list + sessions.changed──► iPhone (cache)
```

- **Mac publishes** topic state to gateway (Phase 1 ✅)
- **Gateway broadcasts** `sessions.changed` events to all connected clients
- **iPhone subscribes** to `sessions.changed`, refreshes from `sessions.list`
- iPhone does NOT write topic state to gateway in Phase 2
- **Gateway is truth.** iPhone always overwrites local with gateway data. No LWW, no CRDTs.

---

## What's Already Built

| File | Repo | Status | What It Does |
|------|------|--------|-------------|
| `SessionInfo.swift` | BeeChat-v5 | ✅ Phase 0 | `pluginExtensions` + `beechatMetadata` computed property |
| `BeeChatTopicMetadata.swift` | BeeChat-v5 | ✅ Phase 0 | Typed struct: topicId, isArchived, projectPath, updatedAt |
| `RPCClient.swift` | BeeChat-v5 | ✅ Phase 1 | sessionsList, sessionsSubscribe, sessionsPatch, sessionsPluginPatch |
| `SyncBridge.swift` | BeeChat-v5 | ✅ Phase 1 | publishTopicState, clearTopicState, reconcileAllTopicState |
| `TopicPublishQueue.swift` | BeeChat-v5 | ✅ Phase 1 | Serialises per-topic publishes |
| `GatewayClient.swift` | BeeChat-v5 | ✅ Phase 1 | grantedScopes() for admin scope verification |
| `BeeChatMobileViewModel.swift` | BeeChat-Mobile | ⚠️ needs change | Currently creates topics locally, no gateway metadata consumption |
| `TopicListView.swift` | BeeChat-Mobile | ⚠️ needs change | Local topic CRUD only, no sync indicator |
| `TopicRepository.swift` | BeeChat-v5 | ✅ existing | fetchPendingSyncTopics, resolveTopicId, saveBridge, syncMetadataFromSessions |

---

## Phase 2 Changes — All in BeeChat-Mobile Repo

### Step 1: Consume Gateway Topic Metadata on Connect

**File:** `BeeChatMobileViewModel.swift` — `connect()` method, steps 2-5

**Current flow (lines ~90-130):**
1. Reconcile pending offline topics
2. `bridge.fetchSessions()` → gets `[Session]`
3. Filter with `BeeChatSessionFilter`
4. Create local topics for new gateway sessions (no metadata)
5. `syncMetadataFromSessions` — but this doesn't read `pluginExtensions`

**New flow:**
After `fetchSessions()`, use `SessionInfo.beechatMetadata` to sync topic state:

```swift
// 2. Fetch sessions from gateway (returns [SessionInfo] via SyncBridge)
let sessionInfos = try await bridge.fetchSessionsWithInfo()

// 3. For each SessionInfo with beechatMetadata:
//    - If local topic exists → update name, archive state, projectPath from gateway
//    - If no local topic → create it with the metadata
//    - If local topic exists but NOT in gateway list → mark as pending/orphaned

// 4. Filter to only BeeChat sessions (sessions with beechatMetadata)
let knownTopics = sessionInfos.compactMap { info in
    guard let metadata = info.beechatMetadata else { return nil }
    return (info, metadata)
}

// 5. Upsert local topics from gateway truth
try persistenceStore.topicRepo.upsertTopicsFromGateway(knownTopics)
```

**New method needed:** `SyncBridge.fetchSessionsWithInfo()` → returns `[SessionInfo]` (currently `fetchSessions()` returns `[Session]` which loses `pluginExtensions`).

**OR:** `SyncBridge` already calls `rpcClient.sessionsList()` internally which returns `[SessionInfo]`. We just need to expose the raw `SessionInfo` list, not just the mapped `Session` list.

**Smallest change:** Add a public method to SyncBridge:
```swift
public func fetchSessionInfos() async throws -> [SessionInfo] {
    return try await rpcClient.sessionsList()
}
```

---

### Step 2: Topic Upsert from Gateway Metadata

**File:** `TopicRepository.swift` (BeeChat-v5, shared package)

**New method:** `upsertTopicsFromGateway(_ topics: [(SessionInfo, BeeChatTopicMetadata)])`

For each (sessionInfo, metadata) pair:
1. Look up existing topic by `sessionKey` (bridge table)
2. If exists:
   - Update `name` from `sessionInfo.label`
   - Update `isArchived` from `metadata.isArchived`
   - Update `projectPath` from `metadata.projectPath`
   - Update `updatedAt` timestamp
3. If new:
   - Create topic with `id = metadata.topicId` (use gateway topicId, not new UUID)
   - Set `name`, `isArchived`, `projectPath`, `sessionKey`
   - Create bridge entry

**SQL consideration:** `isArchived` = true → topic disappears from `fetchAllActive()` (which the iPhone topic list uses). This is the correct behaviour — archived topics don't appear.

---

### Step 3: Subscribe to `sessions.changed` Events

**File:** `BeeChatMobileViewModel.swift` — `connect()` method

**After `bridge.start()`, add:**
```swift
// Subscribe to gateway session changes
startSessionChangeSubscription()
```

**New method in ViewModel:**
```swift
private func startSessionChangeSubscription() {
    sessionChangeTask = Task {
        let stream = await syncBridge?.sessionChangedEvents()
        for await event in stream ?? AsyncStream<Never>.empty {
            // Full re-list on any sessions.changed event
            do {
                let sessionInfos = try await syncBridge?.fetchSessionInfos() ?? []
                let knownTopics = sessionInfos.compactMap { info -> (SessionInfo, BeeChatTopicMetadata)? in
                    guard let metadata = info.beechatMetadata else { return nil }
                    return (info, metadata)
                }
                try persistenceStore.topicRepo.upsertTopicsFromGateway(knownTopics)
                self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
            } catch {
                print("[ViewModel] Session change sync failed: \(error)")
            }
        }
    }
}
```

**New method needed on SyncBridge:** `sessionChangedEvents()` → `AsyncStream<GatewayEvent>` filtered to `sessions.changed` type.

**Current SyncBridge already has:**
- `eventProcessingTask` that iterates `gatewayClient.eventStream()`
- `eventRouter` that routes events

**Simplest approach:** Add a passthrough stream to SyncBridge:
```swift
public func sessionChangedEvents() -> AsyncStream<Void> {
    AsyncStream { continuation in
        let task = Task {
            let stream = await config.gatewayClient.eventStream()
            for await event in stream {
                if event.event.type == "sessions.changed" {
                    continuation.yield(())
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

**No incremental sync in Phase 2.** Full re-list on every `sessions.changed` event. Simple, correct, fast enough.

---

### Step 4: Remove Local-Only Topic Creation

**File:** `BeeChatMobileViewModel.swift` — `createTopic()` method

**Current behaviour:** Creates topic locally with `pendingGatewaySync: isOffline` flag, sends bootstrap message if connected.

**Phase 2 change:** Replace with gateway-first topic creation:

```swift
public func createTopic(name: String) async throws -> Topic {
    guard let bridge = syncBridge, connectionState == .connected else {
        throw TopicError.offlineTopicCreationNotSupported
    }

    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw TopicError.nameRequired }
    guard trimmed.count <= 80 else { throw TopicError.nameTooLong(count: trimmed.count) }

    // Create on gateway first → get session key → create local topic
    // The gateway will create the session, we read it back via sessions.list
    let sessionInfos = try await bridge.fetchSessionInfos()
    // Find or create the topic...
    // Actually: we need to CREATE a session on the gateway first.
    // sessions.patch doesn't create sessions — it modifies existing ones.
    // So: send a bootstrap message to create the session, then publish topic state.
}
```

**WAIT — decision point:** How does iPhone create a topic on the gateway?

Options:
A. iPhone sends a bootstrap message via `sendMessage` → gateway creates session → iPhone reads it back → publishes topic state (but iPhone doesn't have `operator.admin` scope for `sessions.pluginPatch`)
B. iPhone tells Mac to create the topic (too complex)
C. iPhone creates topic locally, marks as pending, and on next Mac sync the Mac publishes it (relies on Mac being online)
D. iPhone creates topic locally with `pendingGatewaySync = true`, and the existing reconciliation flow handles it (this is already implemented)

**Decision: Option D** — Keep the existing `pendingGatewaySync` flow for topic creation on iPhone. The v2 spec said "iPhone local topic creation loop: explicitly removed in Phase 2" — but that referred to the loop where iPhone creates topics that NEVER sync to gateway. The current flow DOES sync (via `sendMessage` creating the gateway session). What we need to remove is the **local-only orphan path**, not all local creation.

**Revised change:** `createTopic()` stays largely the same but:
- After creating locally, if connected, call `bridge.publishTopicState()` to publish metadata to gateway (requires `operator.admin` scope on iPhone)
- If `operator.admin` not available on iPhone, the topic stays pending until Mac reconciles

**Actually — simpler:** Check if iPhone has `operator.admin` scope. If yes, publish. If no, topic stays local until Mac picks it up.

---

### Step 5: Topic Deletion → Gateway Cleanup

**File:** `BeeChatMobileViewModel.swift` — `deleteTopic()` method

**Current behaviour:** Local-only `deleteCascading()`.

**Phase 2 change:** If connected, also call `bridge.clearTopicState(sessionKey:)` to remove `pluginExtensions` metadata from the gateway session.

```swift
public func deleteTopic(id: String) async throws {
    guard let topic = try persistenceStore.topicRepo.fetchById(id) else { return }

    // Clear gateway metadata first (if connected)
    if let bridge = syncBridge, connectionState == .connected, let sessionKey = topic.sessionKey {
        await bridge.clearTopicState(sessionKey: sessionKey)
    }

    // Then delete locally
    try persistenceStore.topicRepo.deleteCascading(id)
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()
    if selectedTopicId == id {
        selectedTopicId = topics.first?.id
    }
}
```

**Same for archive:** `archiveTopic()` should call `bridge.publishTopicState()` to update `isArchived` on gateway.

---

### Step 6: Sync Indicator UI

**File:** `TopicListView.swift`

**Add sync state to ViewModel:**
```swift
public enum SyncState {
    case synced(lastSync: Date)
    case syncing
    case disconnected
}
public var syncState: SyncState = .disconnected
```

**Update in ViewModel:**
- On connect → `.syncing` → after fetchSessions + upsert → `.synced(lastSync: Date())`
- On `sessions.changed` event → `.syncing` → after upsert → `.synced(lastSync: Date())`
- On disconnect → `.disconnected`

**UI in TopicListView:** Small text at bottom of sidebar:
```
✅ Synced 2m ago     (green, < 5 min)
⚠️ Synced 15m ago    (amber, > 5 min)
🔴 No connection     (red, disconnected)
```

---

### Step 7: Archive Undo → Gateway Sync

**File:** `BeeChatMobileViewModel.swift` — `archiveTopic()` / `undoArchive()`

**Current:** Local-only archive/unarchive.

**Phase 2:** After archive, call `bridge.publishTopicState()` to set `isArchived = true` on gateway. After undo, call again with `isArchived = false`.

```swift
public func archiveTopic(id: String) async throws -> Topic? {
    guard let topic = try persistenceStore.topicRepo.fetchById(id) else { return nil }
    guard !topic.isArchived else { return nil }

    try persistenceStore.topicRepo.archive(topicId: id)
    self.topics = try persistenceStore.topicRepo.fetchAllActiveWithCounts()

    // Publish archive state to gateway
    if let bridge = syncBridge, connectionState == .connected, let sessionKey = topic.sessionKey {
        bridge.publishTopicState(topic: topic, sessionKey: sessionKey)
    }

    if selectedTopicId == id {
        selectedTopicId = topics.first?.id
    }
    return topic
}
```

---

### Step 8: Reconnect Recovery

**File:** `BeeChatMobileViewModel.swift` — `reconnect()` / `connect()`

**Already handled:** The existing `connect()` method calls `fetchSessions()` and reconciles. We just need to ensure the new `fetchSessionInfos()` + `upsertTopicsFromGateway()` path is called on reconnect.

**Flow on reconnect:**
1. `disconnect()` → `connect()`
2. `fetchSessionInfos()` → `upsertTopicsFromGateway()` → full refresh
3. This recovers any changes that happened while iPhone was offline

**No special reconnect logic needed** — the initial connect path already does a full sync.

---

### Step 9: New Methods Needed on SyncBridge (BeeChat-v5)

**File:** `SyncBridge.swift` (BeeChat-v5)

```swift
/// Returns raw SessionInfo list including pluginExtensions.
/// Unlike fetchSessions() which maps to Session and loses metadata,
/// this preserves the full gateway response for topic sync.
public func fetchSessionInfos() async throws -> [SessionInfo] {
    return try await rpcClient.sessionsList()
}

/// Stream of void signals — yields once for each sessions.changed event.
/// Consumers should call fetchSessionInfos() to get the updated state.
public func sessionChangedEvents() -> AsyncStream<Void> {
    AsyncStream { continuation in
        let task = Task {
            let stream = await config.gatewayClient.eventStream()
            for await event in stream {
                if event.event.type == "sessions.changed" {
                    continuation.yield(())
                }
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
```

---

### Step 10: New Method on TopicRepository (BeeChat-v5)

**File:** `TopicRepository.swift` (BeeChat-v5)

```swift
/// Upserts local topics from gateway SessionInfo + BeeChatTopicMetadata.
/// - If topic exists (by sessionKey bridge): update name, archive state, projectPath
/// - If topic doesn't exist: create with metadata
/// - Topics in DB but not in gateway list are NOT deleted (orphan detection is future work)
public func upsertTopicsFromGateway(_ entries: [(SessionInfo, BeeChatTopicMetadata)]) throws {
    try writer.write { db in
        for (info, metadata) in entries {
            // Check if bridge exists
            let existingBridge = try TopicSessionBridge
                .filter(Column("sessionKey") == info.key)
                .fetchOne(db)

            if let bridge = existingBridge {
                // Update existing topic
                var topic = try Topic.fetchOne(db, key: bridge.topicId)!
                topic.name = info.label ?? topic.name
                topic.isArchived = metadata.isArchived
                if let projectPath = metadata.projectPath {
                    topic.metadataJSON = try? JSONEncoder().encode(
                        ["projectPath": projectPath]
                    ).map { String(data: $0, encoding: .utf8) }.flatMap { $0 }
                }
                topic.updatedAt = Date()
                try topic.update(db)
            } else {
                // Create new topic
                let topic = Topic(
                    id: metadata.topicId,
                    name: info.label ?? "Conversation",
                    sessionKey: info.key,
                    isArchived: metadata.isArchived,
                    metadataJSON: metadata.projectPath.map { path in
                        try? JSONEncoder().encode(["projectPath": path]).map { String(data: $0, encoding: .utf8) }
                    } ?? nil
                )
                try topic.insert(db)
                try TopicSessionBridge(topicId: topic.id, sessionKey: info.key).insert(db)
            }
        }
    }
}
```

---

## Testing Plan

### Unit Tests (BeeChat-v5 + BeeChat-Mobile)

1. `SessionInfo.beechatMetadata` — valid data returns `BeeChatTopicMetadata` ✅ already exists
2. `SessionInfo.beechatMetadata` — missing fields → returns nil ✅ already exists
3. `TopicRepository.upsertTopicsFromGateway` — new topic created from gateway data
4. `TopicRepository.upsertTopicsFromGateway` — existing topic updated (name, archive state)
5. `TopicRepository.upsertTopicsFromGateway` — archived topic excluded from fetchAllActive
6. `SyncBridge.fetchSessionInfos` — returns SessionInfo with pluginExtensions
7. `SyncBridge.sessionChangedEvents` — yields on sessions.changed, ignores other events

### Integration Tests (Real iPhone + Gateway + Mac)

1. iPhone connects → sees all Mac topics
2. Mac creates topic → iPhone sees it within 5 seconds
3. Mac renames topic → iPhone updates within 5 seconds
4. Mac archives topic → iPhone hides it within 5 seconds
5. Mac deletes topic → iPhone removes it within 5 seconds
6. iPhone disconnects → reconnects → full sync recovers
7. iPhone creates topic locally → Mac publishes it → both see it
8. iPhone on WiFi → cellular → Tailscale still works
9. iPhone archive → undo → gateway reflects unarchive

---

## Exit Criteria

- [ ] `SyncBridge.fetchSessionInfos()` implemented (BeeChat-v5)
- [ ] `SyncBridge.sessionChangedEvents()` implemented (BeeChat-v5)
- [ ] `TopicRepository.upsertTopicsFromGateway()` implemented (BeeChat-v5)
- [ ] ViewModel `connect()` consumes `beechatMetadata` from gateway (BeeChat-Mobile)
- [ ] `sessions.changed` subscription active on iPhone (BeeChat-Mobile)
- [ ] Topic CRUD on iPhone publishes to gateway (BeeChat-Mobile)
- [ ] Sync indicator shows correct state (BeeChat-Mobile UI)
- [ ] iPhone builds and deploys to real device via Xcode USB
- [ ] All Mac topic changes reflect on iPhone within 5 seconds
- [ ] Reconnect recovery works (network drop → restore → full sync)
- [ ] Unit tests pass (new + existing)
- [ ] `swift build` succeeds for both macOS and iOS platforms

---

## Phase 3 Preview (For Context)

- Bidirectional topic sync (iPhone → Gateway publishing without Mac intermediary)
- Reconciliation & conflict resolution on reconnect
- Edge cases: simultaneous edits, offline while other device changes
- Message pagination ("load earlier") — parked

---

## Questions for Team

1. **`operator.admin` scope on iPhone:** Does `openclaw-ios` client ID have `operator.admin`? If not, iPhone can't publish topic state to gateway — only Mac can. This affects Step 4 and Step 5.
2. **Topic ID on create:** Should iPhone-created topics use `metadata.topicId` (gateway-controlled) or local UUID? Current flow uses local UUID + bridge. Phase 2 should align with gateway topicId.
3. **Import flow:** The current `importCandidates()` + `importSelected()` flow creates local topics from gateway sessions. Does this stay, or should it be replaced by the new gateway-sync flow?

---

*Awaiting team review: Q (Builder), Kieran (Adversarial), Mel (Designer)*
