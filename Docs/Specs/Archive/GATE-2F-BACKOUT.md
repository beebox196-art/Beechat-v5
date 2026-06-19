# Gate 2F — Backout Spec: Remove Gateway-Sync Code

> **Status:** v3 — Updated per Q + Kieran v2 review (removed `chatInject`, `sessionsPatch`, `fetchSessionInfos` from keep list; added `pluginExtensions` note; added `ChatHistoryMessage` known issue)  
> **Date:** 2026-05-28  
> **Purpose:** Remove all gateway-based topic sync code before building the REST-over-Tailscale replacement  
> **Principle:** Clean foundation, no dead code, no layered workarounds

---

## What We Keep (Unchanged)

These are **not** gateway-sync code — they're used by other features and must stay:

| Item | Location | Reason |
|------|----------|--------|
| Bounce fixes (4 commits) | `Composer.swift`, `MessageCanvas.swift`, `MessageListView.swift` | Scroll bounce fix — nothing to do with sync |
| `ChatHistoryMessage` | `GatewayRPCResponses.swift` | Used for chat history display, not just sync |
| `ChatMessagePayload` | `ChatMessage.swift` | Used for message rendering |
| ~~`chatInject` RPC method~~ | ~~`RPCClient.swift`~~ | ~~REMOVED — zero callers after backout (only called by `performPublish()`)~~ |
| ~~`sessionsPatch` RPC method~~ | ~~`RPCClient.swift`~~ | ~~REMOVED — zero callers after backout (only called by `publishTopicState()`)~~ |
| `sessionsList` RPC method | `RPCClient.swift` | Used for session management everywhere |
| `TopicRepository` / `BeeChatPersistence` | Shared package | Source of truth for topics, used everywhere |
| `origin` field on `Topic` | `Topic.swift` | Used by reconcile logic (stays) |
| `resolveTopicId` / `saveBridge` | `TopicRepository.swift` | Used for topic↔session mapping |
| `MessageMapper` 10s window + ≥20 char guard | `MessageMapper.swift` | Message dedup — nothing to do with sync |
| `isReconciling` guard | `BeeChatMobileViewModel.swift` | Still needed for REST-based reconciliation |
| `reconcileFromPayload()` | `BeeChatMobileViewModel.swift` | Still needed — fed from REST instead of gateway |
| `TopicSyncPayload` / `TopicPayloadItem` types | `TopicSyncPayload.swift` (iPhone) | Needed by `reconcileFromPayload()` — keep the type definitions |
| `parseISO8601()` function | `TopicSyncPayload.swift` (iPhone) | Needed for date parsing in REST responses |
| `pluginExtensions` field on `SessionInfo` | `SessionInfo.swift` | Keep — part of gateway response schema, harmless to decode even though unused after backout. Add comment noting it's unused post-sync. |

**Known issue for REST spec:** `ChatHistoryMessage.content` is typed as `String` but the gateway returns content as `[{"type": "text", "text": "..."}]` for assistant messages. This is a latent bug that should be addressed in the REST spec. Not a backout concern.

---

## What We Remove

### BeeChat-v5 (macOS App)

#### 1. SyncBridge.swift — Remove ALL gateway-publishing methods

**Remove these methods entirely:**
- `publishTopicList()` (line ~985) — the trailing-edge debounce publisher
- `performPublish()` (line ~997) — the actual publish logic
- `ensureSyncSessionExists()` (line ~1066) — bootstraps the beechat-sync session
- `fetchSyncPayload()` (line ~970) — reads from gateway session (only used by iPhone, not Mac)
- `publishTopicState()` (line ~801) — per-session metadata publisher (all UI calls already commented out)
- `clearTopicState()` (line ~860) — clears session metadata (no callers)
- `clearTopicStateWithResult()` (line ~866) — clears session metadata (no callers)
- `fetchActiveSessionKeys()` (line ~889) — fetches active session keys (no callers)
- `reconcileAllTopicState()` (line ~901) — bulk republish (no callers)
- `verifyAdminScope()` (line ~950) — checks operator.admin scope (no callers)
- `hasAdminScope()` (line ~962) — checks operator.admin scope (no callers)

**Remove these properties:**
- `publishTask: Task<Void, Never>?` (line ~63) — the debounce Task reference
- `publishQueue: TopicPublishQueue` (line ~784) — serialisation queue for publishTopicState

**Remove these types:**
- `TopicSyncItem` struct (line ~634) — only used by `performPublish`
- `TopicListPayload` struct (line ~644) — only used by `performPublish`
- `extractProjectPath(from:)` helper (line ~788) — only used by `publishTopicState`

#### 2. Delete TopicPublishQueue.swift entirely

**File:** `Sources/BeeChatSyncBridge/TopicPublishQueue.swift`

This entire file is only used by the now-removed `publishTopicState()`. No live code references it.

#### 3. Delete BeeChatTopicMetadata.swift

**File:** `Sources/BeeChatPersistence/Models/BeeChatTopicMetadata.swift`

This type is only referenced by `publishTopicState()` and `clearTopicState()`, which we're removing. Not used on iPhone, not used by any live code on Mac.

#### 4. Remove three dead RPC methods from RPCClient

**File:** `Sources/BeeChatSyncBridge/RPCClient.swift`

Remove all three methods (zero callers after backout):
- `sessionsPatch(key:label:)` from `RPCClientProtocol` (line ~14) and `RPCClient` implementation (lines ~159-170) — only called by `publishTopicState()`
- `sessionsPluginPatch(key:pluginId:namespace:value:unset:)` from `RPCClientProtocol` (line ~15) and `RPCClient` implementation (lines ~173-191) — only called by `publishTopicState()` and `clearTopicState()`
- `chatInject(sessionKey:message:label:)` from `RPCClientProtocol` (line ~16) and `RPCClient` implementation (lines ~193-210) — only called by `performPublish()`

All three are dead code after the backout. The REST approach doesn't need any of them.

#### 5. Remove beechatMetadata computed property from SessionInfo

**File:** `Sources/BeeChatSyncBridge/Models/SessionInfo.swift`

Remove the `beechatMetadata` computed property that decodes plugin extensions into `BeeChatTopicMetadata`. This was only used by the sync display logic, which is gone.

#### 6. AppRootView.swift — Remove publishTopicList() call

**Current (line ~98):**
```swift
await bridge.publishTopicList()
```

**Remove this line.** The REST server serves data on-demand instead.

**Also remove the commented-out `reconcileAllTopicState` block** (lines ~101-106) — it's dead code referencing a removed method. Add a comment: `// Topic sync now via REST endpoint (see TopicServer.swift)`

#### 7. MainWindow.swift — Remove publishTopicList() calls (4 call sites)

**Remove from:**
- `createTopic()` success path (line ~421): `await bridge.publishTopicList()`
- `createTopic()` failure path (line ~425): `await bridge.publishTopicList()`
- `deleteTopic()` (line ~482): `await bridge.publishTopicList()`
- `saveTopicEdits()` (line ~453): `await bridge.publishTopicList()`

**Also remove the commented-out `publishTopicState` / `clearTopicState` blocks** — they reference removed methods.

**Also remove the commented-out `publishTopicState` in `saveTopicEdits()`** (lines ~485-487) — dead code.

#### 8. SyncBridgeObserver.swift — Remove publishTopicList() call

**Current (line ~290):**
```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    Task { @MainActor in
        await bridge.publishTopicList()
    }
}
```

**Replace with:**
```swift
nonisolated func syncBridge(_ bridge: SyncBridge, didReceiveSessionChange sessionKeys: [String]) {
    // sessions.changed events are handled by the iPhone via REST re-fetch
    // No action needed on the Mac side — TopicServer serves current data on demand
}
```

Or remove the method entirely if the delegate protocol allows it (check if other observers implement this method).

---

### BeeChat-Mobile (iOS App)

#### 9. BeeChatMobileViewModel.swift — Remove gateway-sync code

**Remove:**
- `syncSessionKey` constant (line ~34): `private static let syncSessionKey = "agent:main:beechat-sync"`
- `lastSyncTimestampKey` constant (line ~36): `private static let lastSyncTimestampKey = "beechat_lastSyncTimestamp"`
- `readSyncPayload()` method (lines ~495-517) — reads from gateway session
- The `beechat-sync` filter in `didReceiveSessionChange` (line ~627): `guard sessionKeys.contains(where: { $0.contains("beechat-sync") })`
- UserDefaults cleanup for `beechat_lastSyncTimestamp` in `connect()` (if present)

**Keep:**
- `isReconciling` guard — still needed for REST-based reconciliation
- `reconcileFromPayload()` — still needed (fed from REST instead of gateway)
- The overall `didReceiveSessionChange` structure — will be repurposed for REST re-fetch

**Stub `connect()`:**
- Remove the `readSyncPayload()` call and staleness guard from `connect()`
- Leave a `// TODO: REST topic fetch` comment where the sync payload read was
- The iPhone falls back to standalone mode (local topics only) until the REST client is built

#### 10. TopicSyncPayload.swift — Refactor to TopicTypes.swift

**Keep:**
- `TopicSyncPayload` struct — needed by `reconcileFromPayload()`
- `TopicPayloadItem` struct — needed by `reconcileFromPayload()`
- `parseISO8601()` function — needed for REST response date parsing
- `timestampDate` computed property — needed by staleness check

**Remove:**
- `extract(from:)` method — gateway-parsing logic, no longer needed
- `maxPayloadSize` constant — gateway-parsing guard, no longer needed
- `validate()` method — gateway-parsing validation, no longer needed

**Rename:** `TopicSyncPayload.swift` → `TopicTypes.swift` (reflects that these are type definitions, not gateway-parsing logic)

**Note:** These types are in the iPhone target, NOT the shared package. The Mac's `TopicSyncItem`/`TopicListPayload` are separate types that will be replaced by `TopicServer`'s own response type. No shared package changes needed for type ownership.

---

### Shared Package (BeeChatSyncBridge)

#### 11. SyncBridge.swift — Remove fetchSyncPayload() and fetchSessionInfos()

**Remove:**
- `fetchSyncPayload(sessionKey:)` — only used by the iPhone's `readSyncPayload()`, which we're removing
- `fetchSessionInfos()` — zero callers anywhere in either repo. Thin wrapper around `rpcClient.sessionsList()`. Any future caller can call `sessionsList()` directly.

---

## Gateway Cleanup

#### 12. Reset the orphaned beechat-sync session

The gateway has an `agent:main:beechat-sync` session created during the gateway-sync attempt. It contains 13 topic payloads + agent responses. After backout, nothing creates or reads this session.

**Action:** Reset this session via the gateway API:
```bash
# Find and reset the session
openclaw gateway call sessions.reset --key "agent:main:beechat-sync" --reason "Gate 2F backout: gateway sync removed, REST approach replaces"
```

This clears the orphaned data. The session itself will be garbage-collected by the gateway.

---

## UserDefaults Cleanup

#### 13. Remove stale sync timestamp from iPhone

After backout, the iPhone's `UserDefaults.standard` will have `beechat_lastSyncTimestamp` set from previous sync attempts. This is harmless but messy.

**Action:** Add a one-time cleanup in `BeeChatMobileViewModel.connect()` or `App.init()`:
```swift
UserDefaults.standard.removeObject(forKey: "beechat_lastSyncTimestamp")
```

This should run once and can be removed in a future version.

---

## Removal Order

Execute in this order to keep both targets compiling at each step:

1. **Mac: AppRootView.swift** — Remove `publishTopicList()` call + commented-out `reconcileAllTopicState` block
2. **Mac: MainWindow.swift** — Remove 4 `publishTopicList()` calls + commented-out `publishTopicState`/`clearTopicState` blocks
3. **Mac: SyncBridgeObserver.swift** — Remove `publishTopicList()` call, replace with no-op or remove method
4. **Mac: Build verify** — Mac target compiles clean
5. **Mac: SyncBridge.swift** — Remove all methods and types listed in §1 above (publishTopicList, performPublish, ensureSyncSessionExists, publishTopicState, clearTopicState, clearTopicStateWithResult, fetchActiveSessionKeys, reconcileAllTopicState, verifyAdminScope, hasAdminScope, fetchSyncPayload, TopicSyncItem, TopicListPayload, publishTask, publishQueue, extractProjectPath)
6. **Mac: Delete `TopicPublishQueue.swift`** — entire file
7. **Mac: Delete `BeeChatTopicMetadata.swift`** — entire file
8. **Mac: RPCClient.swift** — Remove all three dead RPC methods: `sessionsPluginPatch`, `sessionsPatch`, `chatInject` (from protocol + implementation)
9. **Mac: Remove `beechatMetadata`** computed property from `SessionInfo`
10. **Mac: Build verify** — Mac target compiles clean
11. **iPhone: BeeChatMobileViewModel.swift** — Remove `readSyncPayload()`, `syncSessionKey`, `lastSyncTimestampKey`, beechat-sync filter, UserDefaults cleanup
12. **iPhone: Stub `connect()`** — Replace sync payload read with `// TODO: REST topic fetch`
13. **iPhone: Build verify** — iPhone target compiles clean
14. **iPhone: Refactor `TopicSyncPayload.swift`** — Remove `extract(from:)`, `maxPayloadSize`, `validate()`, rename to `TopicTypes.swift`, update doc comment (remove `beechat-sync` reference)
15. **Shared: SyncBridge.swift** — Remove `fetchSyncPayload()` and `fetchSessionInfos()`
16. **Final build verify** — Both targets compile clean, no warnings
17. **Gateway cleanup** — Reset `agent:main:beechat-sync` session
18. **Commit** — Single commit: `backout: remove gateway-sync code, clean foundation for REST (GATE-2F-BACKOUT)`

---

## Verification

After each step:
- Build both targets
- No new warnings introduced
- No dead code left behind

**Final state:**
- Mac app works exactly as before — messaging, topics, sidebar all functional
- iPhone works in standalone mode — local topics, no sync
- No `beechat-sync` session created or read
- No gateway session used for topic data
- No dead sync code remaining
- Clean foundation ready for REST-over-Tailscale implementation

**Dead code audit checklist (should be zero hits after backout):**
- `publishTopicList` / `performPublish` / `ensureSyncSessionExists`
- `publishTopicState` / `clearTopicState` / `reconcileAllTopicState`
- `fetchSyncPayload` / `fetchActiveSessionKeys` / `fetchSessionInfos`
- `TopicPublishQueue` / `BeeChatTopicMetadata`
- `sessionsPluginPatch` / `sessionsPatch` / `chatInject`
- `beechatMetadata` on `SessionInfo`
- `beechat-sync` / `syncSessionKey` / `lastSyncTimestampKey`
- `TopicSyncItem` / `TopicListPayload` (Mac versions)

---

## Commit Strategy

One clean commit at the end: `backout: remove gateway-sync code, clean foundation for REST (GATE-2F-BACKOUT)`

Or multiple commits per step if preferred — each referencing this spec.