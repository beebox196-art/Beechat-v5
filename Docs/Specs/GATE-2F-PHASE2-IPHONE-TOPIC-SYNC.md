# Gate 2F Phase 2 — iPhone Topic Sync (Mac → iPhone)

**Status:** SPEC v4 — final validation complete, ALL blockers resolved, ready for implementation
**Author:** Bee
**Date:** 2026-05-23
**Reviews Round 1:** Q (CONDITIONAL PASS), Kieran (CONDITIONAL PASS), Mel (CONDITIONAL PASS)
**Reviews Round 2 (Final):** Q (PASS), Kieran (PASS), Mel (CONDITIONAL PASS — UX implementation notes)
**Predecessors:** Phase 0 (Shared Models ✅), Phase 1 (Mac Publishing ✅)

---

## Objective

When a topic is created, renamed, archived, or deleted on the Mac, the iPhone reflects that change within seconds. Same topics on both devices, like Telegram. Mac is master, iPhone is cache. Gateway is the conduit.

---

## Architecture

```
Mac (master) ──sessions.patch/pluginPatch──► Gateway ──sessions.list + sessions.changed──► iPhone (cache)
```

- **Mac publishes** topic state to gateway (Phase 1 ✅)
- **Gateway broadcasts** `sessions.changed` events to all connected clients
- **iPhone subscribes** via existing EventRouter (extended to fire delegate callback)
- iPhone does NOT write topic metadata to gateway in Phase 2 (scope-dependent, see Step 8)
- **Gateway is truth.** iPhone always overwrites local with gateway data. No LWW, no CRDTs.

---

## What's Already Built

| File | Repo | Status | What It Does |
|------|------|--------|-------------|
| `SessionInfo.swift` | BeeChat-v5 | ✅ Phase 0 | `pluginExtensions` + `beechatMetadata` computed property |
| `BeeChatTopicMetadata.swift` | BeeChat-v5 | ✅ Phase 0 | Typed struct: topicId, isArchived, projectPath, updatedAt |
| `RPCClient.swift` | BeeChat-v5 | ✅ Phase 1 | sessionsList, sessionsSubscribe, sessionsPatch, sessionsPluginPatch |
| `SyncBridge.publishTopicState()` | BeeChat-v5 | ✅ Phase 1 | Publishes topic label + metadata to gateway |
| `SyncBridge.clearTopicState()` | BeeChat-v5 | ✅ Phase 1 | Clears BeeChat metadata from gateway session |
| `TopicPublishQueue.swift` | BeeChat-v5 | ✅ Phase 1 | Serialises per-topic publishes |
| `GatewayClient.grantedScopes()` | BeeChat-v5 | ✅ Phase 1 | Returns auth scopes from handshake |
| `TopicSessionBridge` model | BeeChat-v5 | ✅ existing | Columns: `topicId`, `spaceId`, `openclawSessionKey`, `bridgeVersion`, `status` |
| `TopicRepository.resolveTopicIdBySuffix()` | BeeChat-v5 | ✅ existing | 5-step lookup cascade for topic→session resolution |
| `EventRouter.handleSessionsChanged()` | BeeChat-v5 | ✅ existing | Already fires on `sessions.changed` — calls `syncBridge.fetchSessions()` |
| `BeeChatMobileViewModel` | BeeChat-Mobile | ⚠️ needs change | Currently creates topics locally, no gateway metadata consumption |
| `TopicListView` | BeeChat-Mobile | ⚠️ needs change | Local topic CRUD only, no sync indicator |

---

## Review Consolidation — Blockers Resolved

### Round 1 Blockers (initial review)
| # | Reviewer | Issue | Resolution |
|---|----------|-------|------------|
| B1 | Kieran/Q | Upsert SQL uses wrong column (`sessionKey` vs `openclawSessionKey`) | All code uses `openclawSessionKey` — the actual bridge table column |
| B2 | Kieran/Q | Upsert ignores `resolveTopicIdBySuffix` 5-step cascade, creating duplicates | `upsertTopicsFromGateway` uses cascade |
| B3 | Kieran | No debounce on `sessions.changed` → event storm | 10-second debounce in delegate callback on ViewModel |
| B4 | Kieran | `operator.admin` scope deferred but code assumes it exists | Hard gate at connect; UI shows "sync unavailable"; publish calls guarded |
| B5 | Mel | Offline topic creation UX unresolved | Keep existing `pendingGatewaySync` flow; inline warning when disconnected |
| B6 | Mel | First-run onboarding missing | Step 14: connection-state-aware empty state variants |
| B7 | Q | 7+ TopicRepository methods called by ViewModel don't exist | Noted as pre-existing — builder implements as prerequisite |
| B8 | Q | Second `eventStream()` consumer kills EventRouter (single continuation) | REMOVED. Extended `EventRouter.handleSessionsChanged()` to fire delegate callback |

### Round 2 Blockers (final validation)
| # | Reviewer | Issue | Resolution |
|---|----------|-------|------------|
| B9 | Q | `syncBridgeSessionsChanged` required protocol method → Mac build breaks | Protocol extension with default no-op — Mac compiles without changes |
| W4 | Q | Nested `read` inside `writer.write` → GRDB deadlock risk | SQL inlined inside write transaction — no nested read |
| W5 (Mel) | Mel | Sync footer collides with archive undo toast | Toast wins; footer hidden during transient undo |

---

## Phase 2 Changes

### Step 1: New Methods on SyncBridge (BeeChat-v5)

**File:** `Sources/BeeChatSyncBridge/SyncBridge.swift`

```swift
/// Returns raw SessionInfo list including pluginExtensions.
public func fetchSessionInfos() async throws -> [SessionInfo] {
    return try await rpcClient.sessionsList()
}

/// Checks if operator.admin scope is available for topic publishing.
public func hasAdminScope() async -> Bool {
    let scopes = await config.gatewayClient.grantedScopes()
    return scopes.contains("operator.admin")
}
```

### Step 2: New Method on SyncBridge — clearTopicStateWithResult

**File:** `Sources/BeeChatSyncBridge/SyncBridge.swift`

```swift
/// Clears the BeeChat metadata for a gateway session.
/// Returns true if cleared successfully, false if all retries exhausted.
public func clearTopicStateWithResult(sessionKey: String) async -> Bool {
    for attempt in 1...2 {
        do {
            let ok = try await rpcClient.sessionsPluginPatch(
                key: sessionKey,
                pluginId: "beechat",
                namespace: "metadata",
                value: nil as BeeChatTopicMetadata?,
                unset: true
            )
            if ok { return true }
        } catch {
            print("[SyncBridge] clearTopicStateWithResult attempt \(attempt): \(error)")
        }
        if attempt < 2 { try? await Task.sleep(for: .seconds(1)) }
    }
    return false
}
```

### Step 3: Extend SyncBridgeDelegate

**File:** `Sources/BeeChatSyncBridge/Protocols/SyncBridgeDelegate.swift`

Add to protocol:
```swift
/// Called when the gateway fires a sessions.changed event.
/// Delegate should call fetchSessionInfos() + upsertTopicsFromGateway() to refresh.
/// Default: no-op. Only iPhone ViewModel overrides this.
func syncBridgeSessionsChanged(_ bridge: SyncBridge)
```

**CRITICAL — Add protocol extension with default no-op (Q B9 fix):**
Immediately after the protocol definition, add:
```swift
extension SyncBridgeDelegate {
    func syncBridgeSessionsChanged(_ bridge: SyncBridge) {
        // Default: no-op. Mac's SyncBridgeObserver doesn't need this.
    }
}
```
This prevents the Mac build from breaking — `SyncBridgeObserver` conforms to `SyncBridgeDelegate` but only needs the existing streaming/error callbacks. The default no-op lets it compile without changes.

### Step 4: Extend EventRouter

**File:** `Sources/BeeChatSyncBridge/EventRouter.swift`

Modify existing `handleSessionsChanged()`:
```swift
private func handleSessionsChanged() async throws {
    // Existing: refresh internal session state
    _ = try await syncBridge.fetchSessions()
    // New: notify delegate so iPhone can refresh topic metadata
    await MainActor.run { [weak syncBridge] in
        guard let bridge = syncBridge else { return }
        bridge.delegate?.syncBridgeSessionsChanged(bridge)
    }
}
```

### Step 5: New Method on TopicRepository (BeeChat-v5)

**File:** `Sources/BeeChatPersistence/Repositories/TopicRepository.swift`

```swift
/// Upserts local topics from gateway SessionInfo + BeeChatTopicMetadata.
/// - Matches via 5-step cascade (inlined to avoid nested read-in-write deadlock) — Q W4 fix
/// - If found: updates name, isArchived, projectPath, updatedAt
/// - If not found: creates new topic with metadata.topicId as primary key
public func upsertTopicsFromGateway(_ entries: [(SessionInfo, BeeChatTopicMetadata)]) throws {
    try writer.write { db in
        for (info, metadata) in entries {
            let strippedKey = SessionKeyNormalizer.stripPrefix(info.key)
            let strippedLower = strippedKey.lowercased()

            // Inlined resolveTopicIdBySuffix (5-step cascade) using the active `db`
            // This avoids calling resolveTopicIdBySuffix which opens its own read transaction
            // — nesting a read inside a write causes GRDB deadlock with DatabasePool.
            let existingTopicId: String?
            // Step 1: exact match on gateway key
            if let id = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [info.key]) {
                existingTopicId = id
            }
            // Step 2: exact match on stripped key
            else if let id = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE sessionKey = ?", arguments: [strippedKey]) {
                existingTopicId = id
            }
            // Step 3: case-insensitive suffix match on topic UUID
            else if let id = try String.fetchOne(db, sql: "SELECT id FROM topics WHERE UPPER(id) = ?", arguments: [strippedLower.uppercased()]) {
                existingTopicId = id
            }
            // Step 4: bridge table match on gateway key
            else if let id = try String.fetchOne(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [info.key]) {
                existingTopicId = id
            }
            // Step 5: bridge table match on stripped key
            else if let id = try String.fetchOne(db, sql: "SELECT topicId FROM topic_session_bridge WHERE openclawSessionKey = ?", arguments: [strippedKey]) {
                existingTopicId = id
            }
            else {
                existingTopicId = nil
            }

            if let topicId = existingTopicId {
                var topic = try Topic.fetchOne(db, key: topicId)!
                if let label = info.label, !label.isEmpty {
                    topic.name = label
                }
                topic.isArchived = metadata.isArchived
                topic.updatedAt = Date()
                try topic.update(db)
            } else {
                let topic = Topic(
                    id: metadata.topicId,
                    name: info.label ?? "Conversation",
                    sessionKey: info.key,
                    isArchived: metadata.isArchived,
                    metadataJSON: metadata.projectPath.map { path in
                        try? JSONSerialization.data(
                            withJSONObject: ["projectPath": path]
                        ).map { String(data: $0, encoding: .utf8) }
                    } ?? nil
                )
                try topic.insert(db)
                let bridge = TopicSessionBridge(
                    topicId: topic.id,
                    openclawSessionKey: info.key  // Kieran B1/Q B2 fix
                )
                try bridge.insert(db)
            }
        }
    }
}
```

### Step 6: New Methods on BeeChatPersistenceStore (BeeChat-v5)

**File:** `Sources/BeeChatPersistence/BeeChatPersistenceStore.swift`

```swift
public func upsertTopicsFromGateway(_ entries: [(SessionInfo, BeeChatTopicMetadata)]) throws {
    try topicRepo.upsertTopicsFromGateway(entries)
}
public func fetchAllActiveWithCounts() throws -> [Topic] {
    try topicRepo.fetchAllActiveWithCounts()
}
public func fetchTopicById(_ id: String) throws -> Topic? {
    try topicRepo.fetchById(id)
}
public func archiveTopic(topicId: String) throws {
    try topicRepo.archive(topicId: topicId)
}
public func saveTopic(_ topic: Topic) throws {
    try topicRepo.save(topic)
}
public func deleteTopicCascading(_ id: String) throws {
    try topicRepo.deleteCascading(id)
}
```

### Step 7: ViewModel connect() — Consume Gateway Metadata

**File:** `BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

Replace session-fetch steps in `connect()`:
```swift
// 2. Fetch raw SessionInfo (preserves pluginExtensions)
let sessionInfos = try await bridge.fetchSessionInfos()

// 3. Filter to sessions with BeeChat metadata
let knownTopics = sessionInfos.compactMap { info -> (SessionInfo, BeeChatTopicMetadata)? in
    guard let metadata = info.beechatMetadata else { return nil }
    return (info, metadata)
}

// 4. Upsert local topics from gateway truth
try persistenceStore.upsertTopicsFromGateway(knownTopics)

// 5. Refresh topic list
self.topics = try persistenceStore.fetchAllActiveWithCounts()

// 6. Auto-select first topic
if self.selectedTopicId == nil, let first = topics.first {
    self.selectedTopicId = first.id
}

// 7. Check admin scope for sync capability
self.hasAdminScope = await bridge.hasAdminScope()
if !self.hasAdminScope {
    self.syncState = .syncUnavailable("Topic sync requires admin scope")
} else {
    self.syncState = .synced(lastSync: Date())
}
```

### Step 8: ViewModel — Delegate Receives sessions.changed (with debounce)

**File:** `BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

Add to ViewModel state:
```swift
private var lastSessionsChangedSync: Date = .distantPast
private var hasAdminScope: Bool = false
public var syncState: SyncState = .disconnected
```

Add to `SyncBridgeDelegate` extension:
```swift
nonisolated public func syncBridgeSessionsChanged(_ bridge: SyncBridge) {
    Task { @MainActor in
        let now = Date()
        guard now.timeIntervalSince(self.lastSessionsChangedSync) >= 10 else { return }
        self.lastSessionsChangedSync = now

        do {
            guard let syncBridge = self.syncBridge else { return }
            let sessionInfos = try await syncBridge.fetchSessionInfos()
            let knownTopics = sessionInfos.compactMap { info -> (SessionInfo, BeeChatTopicMetadata)? in
                guard let metadata = info.beechatMetadata else { return nil }
                return (info, metadata)
            }
            try persistenceStore.upsertTopicsFromGateway(knownTopics)
            self.topics = try persistenceStore.fetchAllActiveWithCounts()
            if self.hasAdminScope {
                self.syncState = .synced(lastSync: Date())
            }
        } catch {
            print("[ViewModel] sessions.changed sync failed: \(error)")
        }
    }
}
```

### Step 9: ViewModel — Topic Creation (Gateway-Aware)

**File:** `BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

After existing local topic creation in `createTopic()`, add:
```swift
// Publish to gateway if connected + admin scope
if !isOffline, let bridge = syncBridge, hasAdminScope, let sessionKey = topic.sessionKey {
    let topicForPublish = try persistenceStore.fetchTopicById(topic.id)!
    bridge.publishTopicState(topic: topicForPublish, sessionKey: sessionKey)
}
```

Offline warning in new-topic sheet: *"This topic will appear on this iPhone now and sync when the gateway reconnects."*

### Step 10: ViewModel — Topic Deletion → Gateway Cleanup

**File:** `BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

```swift
public func deleteTopic(id: String) async throws {
    guard let topic = try persistenceStore.fetchTopicById(id) else { return }

    if let bridge = syncBridge, connectionState == .connected, hasAdminScope, let sessionKey = topic.sessionKey {
        let cleared = await bridge.clearTopicStateWithResult(sessionKey: sessionKey)
        if !cleared {
            connectionError = "Topic deleted locally but gateway metadata may persist."
        }
    }

    try persistenceStore.deleteTopicCascading(id)
    self.topics = try persistenceStore.fetchAllActiveWithCounts()
    if selectedTopicId == id {
        selectedTopicId = topics.first?.id
    }
}
```

### Step 11: ViewModel — Archive + Undo → Gateway Sync

**File:** `BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

```swift
public func archiveTopic(id: String) throws -> Topic? {
    guard let topic = try persistenceStore.fetchTopicById(id) else { return nil }
    guard !topic.isArchived else { return nil }

    try persistenceStore.archiveTopic(topicId: id)
    self.topics = try persistenceStore.fetchAllActiveWithCounts()

    if let bridge = syncBridge, connectionState == .connected, hasAdminScope, let sessionKey = topic.sessionKey {
        let topicForPublish = topic
        bridge.publishTopicState(topic: topicForPublish, sessionKey: sessionKey)
    }

    if selectedTopicId == id { selectedTopicId = topics.first?.id }
    return topic
}

public func unarchiveTopic(id: String) throws {
    guard var topic = try persistenceStore.fetchTopicById(id) else { return }
    topic.isArchived = false
    topic.updatedAt = Date()
    try persistenceStore.saveTopic(topic)
    self.topics = try persistenceStore.fetchAllActiveWithCounts()
    self.selectedTopicId = topic.id

    if let bridge = syncBridge, connectionState == .connected, hasAdminScope, let sessionKey = topic.sessionKey {
        bridge.publishTopicState(topic: topic, sessionKey: sessionKey)
    }
}
```

### Step 12: ViewModel — Disconnect

**File:** `BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

Add to existing `disconnect()`:
```swift
syncState = .disconnected
```

### Step 12a: ViewModel — refreshTopicsFromGateway (light sync)

**File:** `BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

```swift
/// Light refresh: fetch session infos, upsert topics, update sync state.
/// Does NOT reconnect the gateway connection. Use for "Sync Now" button.
public func refreshTopicsFromGateway() async {
    guard connectionState == .connected, let bridge = syncBridge else { return }
    do {
        let sessionInfos = try await bridge.fetchSessionInfos()
        let knownTopics = sessionInfos.compactMap { info -> (SessionInfo, BeeChatTopicMetadata)? in
            guard let metadata = info.beechatMetadata else { return nil }
            return (info, metadata)
        }
        try persistenceStore.upsertTopicsFromGateway(knownTopics)
        self.topics = try persistenceStore.fetchAllActiveWithCounts()
        if hasAdminScope {
            self.syncState = .synced(lastSync: Date())
        }
    } catch {
        // Refresh failed — fall back to full reconnect
        print("[ViewModel] refreshTopicsFromGateway failed: \(error), attempting reconnect")
        await reconnect()
    }
}
```

### Step 13: SyncState + Sync Indicator UI

**File:** `BeeChatMobile/Sources/BeeChatMobileKit/BeeChatMobileViewModel.swift`

```swift
public enum SyncState: Equatable {
    case synced(lastSync: Date)
    case syncing
    case disconnected
    case syncUnavailable(String)
}
public var syncState: SyncState = .disconnected
```

**File:** `BeeChatMobile/Sources/BeeChatUI/TopicListView.swift`

```swift
.safeAreaInset(edge: .bottom) {
    VStack(spacing: 4) {
        Divider()
        HStack(spacing: 6) {
            Image(systemName: syncState.symbol)
                .font(.caption)
                .foregroundStyle(syncState.color)
            Text(syncState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if syncState.isStale {
                Button("Sync Now") {
                    Task { await viewModel.refreshTopicsFromGateway() }
                }
                .font(.caption)
                .accessibilityLabel("Sync topics now")
                .accessibilityHint("Refreshes topics from the gateway.")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}
```

**SyncState extensions:**

```swift
extension SyncState {
    var symbol: String {
        switch self {
        case .synced: return "checkmark.icloud.fill"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .disconnected: return "exclamationmark.icloud.fill"
        case .syncUnavailable: return "info.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .synced(let lastSync):
            return Date().timeIntervalSince(lastSync) < 300 ? .secondary : .orange
        case .syncing: return .blue
        case .disconnected: return .red
        case .syncUnavailable: return .secondary
        }
    }
    var label: String {
        switch self {
        case .synced(let lastSync):
            let interval = Date().timeIntervalSince(lastSync)
            if interval < 60 { return "Synced just now" }
            let minutes = Int(interval / 60)
            return "Synced \(minutes)m ago"
        case .syncing: return "Syncing..."
        case .disconnected: return "Gateway disconnected"
        case .syncUnavailable(let reason): return reason
        }
    }
    var isStale: Bool {
        guard case .synced(let lastSync) = self else { return false }
        return Date().timeIntervalSince(lastSync) > 300
    }
}
```

**Implementation notes (Mel UX requirements):**

- **Footer vs toast collision:** When `showArchiveToast` is true, hide the synced footer (show only the toast). Toast wins for transient undo. Footer visible only for actionable states: syncing, stale, sync unavailable.
- **Footer vs offline banner:** When `OfflineBannerView` is visible (disconnected/error), hide the sync footer. The banner owns disconnected state. Footer returns when banner is dismissed.
- **"Sync Now" action:** Prefer `refreshTopicsFromGateway()` (light fetch + upsert) over full `reconnect()`. Fall back to `reconnect()` only if refresh fails due to connection state.
- **Empty state transitions:** If first-run onboarding hasn't been dismissed, keep it stable until dismissed. After dismissal, use `syncing, no cache` during active gateway fetch. Transition empty-state variants with opacity/crossfade (respect Reduce Motion). When first topic arrives, use standard list insertion animation.
- **VoiceOver labels:**
  - Empty states: one combined accessibility element (e.g. `"Welcome to BeeChat. Topics from your Mac will appear here automatically."`)
  - Offline banner: include exact state and action (e.g. `"Cannot reach gateway. Showing cached topics. Reconnect available."`)
  - Sync footer: accessibility should include exact sync time for stale/synced states
  - `Sync Now`: label `"Sync topics now"`; hint `"Refreshes topics from the gateway."`
  - Animated syncing icon: hidden from VoiceOver, stop animation under Reduce Motion

### Step 14: First-Run Onboarding + Empty State Variants

**First-run** (stored in `UserDefaults.beechatOnboardingShown`):
> "Topics from your Mac appear here automatically. Create topics on either device — they'll stay in sync." [Got it]

**Empty state variants:**

| State | Icon | Headline | Subtext | Action |
|-------|------|----------|---------|--------|
| First run, no cache | `sparkles` | `Welcome to BeeChat` | `Topics from your Mac will appear here automatically.` | `+ Start a Topic` |
| Syncing, no cache | `arrow.triangle.2.circlepath` (animated) | `Loading topics...` | `Connecting to your Mac.` | None |
| Disconnected, no cache | `wifi.slash` | `No connection` | `Connect to the gateway to load topics.` | `Reconnect` |
| All archived | `archivebox` | `All topics archived` | `No active conversations.` | `+ New Topic` |
| Connected, no topics | `bubble.left.and.bubble.right` | `No topics yet` | `Create a topic to start chatting.` | `+ New Topic` |

**Offline banner variants:**
- No network: `No network. Showing cached topics.`
- Gateway unreachable: `Cannot reach gateway. Showing cached topics.` + `Reconnect`
- Auth/config error: `Gateway config needs attention.` + `Check Settings`

---

## Prerequisites (Pre-Phase 2)

These methods are called by the existing iOS ViewModel but don't exist in `TopicRepository.swift` on disk. Builder must implement before or alongside Phase 2:

| Method | Purpose |
|--------|---------|
| `fetchAllActiveWithCounts()` | Topics with unread count + last message preview |
| `fetchPendingSyncTopics()` | Topics with `pendingGatewaySync = true` |
| `markSynced(topicId:)` | Clear `pendingGatewaySync` flag |
| `syncMetadataFromSessions(_:)` | Sync session metadata to local topics |
| `fetchAllActiveSessionKeys()` | Set of session keys for active topics |
| `fetchById(_:)` | Fetch single topic by ID |
| `create(name:pendingGatewaySync:)` | Create topic with optional pending flag |
| `archive(topicId:)` | Archive topic (SQL UPDATE) |
| `saveAndBridgeInTransaction(_:sessionKey:)` | Atomic topic + bridge creation |
| `saveTopic(_:)` | Save/update topic |

---

## Testing Plan

### Unit Tests
1. `SyncBridge.fetchSessionInfos()` → returns `[SessionInfo]` with `pluginExtensions`
2. `SyncBridge.hasAdminScope()` → true/false based on granted scopes
3. `SyncBridge.clearTopicStateWithResult()` → true on success, false on failure
4. `TopicRepository.upsertTopicsFromGateway()` → new topic from gateway data
5. `TopicRepository.upsertTopicsFromGateway()` → existing topic updated (name, archive)
6. `TopicRepository.upsertTopicsFromGateway()` → uses `resolveTopicIdBySuffix` (no duplicates)
7. `TopicRepository.upsertTopicsFromGateway()` → matches by `sessionKey` (bridge table)
8. `EventRouter.handleSessionsChanged()` → fires delegate callback
9. `syncBridgeSessionsChanged` delegate → debounced (10 rapid events = 1 sync)
10. `syncBridgeSessionsChanged` delegate → no-op when not connected

### Integration Tests (Real iPhone + Gateway + Mac)
1. iPhone connects → sees all Mac topics
2. Mac creates topic → iPhone sees it within 15 seconds
3. Mac renames topic → iPhone updates within 15 seconds
4. Mac archives topic → iPhone hides it within 15 seconds
5. Mac deletes topic → iPhone removes it within 15 seconds
6. iPhone disconnects → reconnects → full sync recovers
7. iPhone creates topic locally → Mac publishes it → both see it
8. iPhone archive → undo → gateway reflects unarchive
9. iPhone without `operator.admin` → creates locally → Mac picks it up

---

## Exit Criteria

- [ ] `SyncBridge.fetchSessionInfos()` implemented
- [ ] `SyncBridge.hasAdminScope()` implemented
- [ ] `SyncBridge.clearTopicStateWithResult()` implemented
- [ ] `SyncBridgeDelegate.syncBridgeSessionsChanged()` added to protocol + default no-op extension
- [ ] `EventRouter.handleSessionsChanged()` fires delegate callback
- [ ] `TopicRepository.upsertTopicsFromGateway()` (inlined SQL, no nested read, `openclawSessionKey`)
- [ ] ViewModel `connect()` consumes `beechatMetadata` from gateway
- [ ] Delegate callback with 10-second debounce implemented
- [ ] `refreshTopicsFromGateway()` implemented (light sync, fallback to reconnect)
- [ ] Topic CRUD publishes to gateway (when admin scope available)
- [ ] Sync indicator (SF Symbols, semantic colors, safeAreaInset)
- [ ] Footer ↔ toast ↔ offline banner visibility rules implemented
- [ ] First-run onboarding shown once
- [ ] Empty state variants with transitions + VoiceOver labels
- [ ] iPhone builds and deploys to real device via Xcode USB
- [ ] All Mac topic changes reflect on iPhone within 15 seconds
- [ ] Reconnect recovery works
- [ ] Unit tests pass
- [ ] `swift build` succeeds (macOS); iOS via `xcodebuild`

---

## Phase 3 Preview

- Bidirectional topic sync (iPhone → Gateway without Mac intermediary)
- Orphan detection (topics on iPhone but not on gateway)
- Reconciliation & conflict resolution
- Message pagination ("load earlier") — parked

### Phase 3 Debt (tracked for awareness)

| Phase 2 choice | Debt level | Phase 3 mitigation |
|--------|-----------|------------|
| `hasAdminScope` cached at connect | LOW | Per-publish async re-check or periodic refresh |
| Mac-is-master overwrite model | MEDIUM | Add per-topic ownership flag + event origin tracking to prevent echo loops |
| 10-second time-based debounce | LOW | Replace with per-event dedup when bidirectional |
| `compactMap` filters out no-metadata sessions | LOW | Handle sessions without metadata (iPhone-direct topics) |
| Delegate callback pattern | NONE | Scales — add methods for conflict/orphan detection |

---

*Spec v4 — all team blockers resolved. No second event consumer. Mac build safe. GRDB deadlock-free. Ready for Q to implement.*
