# Gate 2F Phase 2 — Builder Review (Q)

**Date:** 2026-05-23
**Reviewer:** Q, Senior Developer
**Spec:** `GATE-2F-PHASE2-IPHONE-TOPIC-SYNC.md`
**Verdict:** CONDITIONAL PASS

---

## Summary

The Phase 2 spec is architecturally sound — the "Mac is master, iPhone is cache, Gateway is truth" model is clean and avoids the CRDT/LWW complexity that would bloat Phase 2. The proposed `SyncBridge` additions (`fetchSessionInfos()`, `sessionChangedEvents()`) are small, well-scoped, and leverage existing infrastructure.

However, there are **two genuine blockers** and several significant gaps that must be addressed before implementation begins. The most critical finding is that the spec references **seven TopicRepository methods that do not currently exist** in the codebase — and the ViewModel calls them. This isn't a spec problem per se; it's a sign that either (a) the codebase has untracked divergence, or (b) those methods exist in a local/feature branch that isn't the current main state.

---

## Blockers

### B1 — Missing TopicRepository Methods (7 undefined references)

The ViewModel calls these `persistenceStore.topicRepo` methods that **do not exist** in `TopicRepository.swift` (verified — the file has 129 lines, only 9 public methods):

| Missing Method | Called In ViewModel |
|---|---|
| `fetchPendingSyncTopics()` | `connect()`, line 112 |
| `markSynced(topicId:)` | `connect()`, line 117; `createTopic()`, line 231 |
| `syncMetadataFromSessions(_:)` | `connect()`, line 152 |
| `fetchAllActiveWithCounts()` | `connect()`, line 155; many refreshes |
| `fetchAllActiveSessionKeys()` | `importCandidates()`, line 307; `importSelected()`, line 332 |
| `fetchById(_:)` | `archiveTopic()`, line 251; `unarchiveTopic()`, line 271 |
| `create(name:pendingGatewaySync:)` | `createTopic()`, line 223 |
| `archive(topicId:)` | `archiveTopic()`, line 255 |
| `saveAndBridgeInTransaction(_:sessionKey:)` | `importSelected()`, line 353 |

**Impact:** The ViewModel **will not compile** against the current `TopicRepository`. This means either:
- The project is built from a feature branch with these methods already added (not reflected in disk), or
- These methods were planned but never implemented, or
- There's a Swift protocol/conformance layer I'm not seeing

**Action required:** Confirm the canonical state of `TopicRepository`. If these methods don't exist yet, they must be implemented as part of Phase 2 (or a pre-Phase 2). The spec assumes they exist but doesn't list them as "needs implementation."

**Confidence:** HIGH — verified against filesystem, not speculation.

---

### B2 — TopicSessionBridge Schema Mismatch in Upsert SQL

The spec's `upsertTopicsFromGateway` method queries `TopicSessionBridge` by `sessionKey`:

```swift
let existingBridge = try TopicSessionBridge
    .filter(Column("sessionKey") == info.key)
    .fetchOne(db)
```

But the actual `TopicSessionBridge` struct has:
- `topicId: String`
- `spaceId: String`
- `openclawSessionKey: String`

**There is no `sessionKey` column.** The spec should use `Column("openclawSessionKey")`. This is a one-character column name error but it's a SQL runtime crash waiting to happen.

Similarly, the new topic creation in the spec sets:
```swift
let topic = Topic(
    id: metadata.topicId,
    ...
    sessionKey: info.key,
    ...
)
try topic.insert(db)
try TopicSessionBridge(topicId: topic.id, sessionKey: info.key).insert(db)
```

But `TopicSessionBridge`'s initializer takes `openclawSessionKey`, not `sessionKey`. The compiler would catch this for the Swift struct, but the SQL filter using `"sessionKey"` is a string literal that won't be caught until runtime.

**Action required:** Fix column name to `openclawSessionKey` in the spec's upsert implementation.

**Confidence:** HIGH — verified against actual struct definition.

---

## Warnings

### W1 — SyncBridge is `actor` but `sessionChangedEvents()` Returns `AsyncStream<Void>` Without Async Isolation Context

The spec proposes:

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

`SyncBridge` is a `public actor`. The `eventStream()` call on `GatewayClient` (also an actor) is `async`, so the `Task` inside the closure properly uses `await`. However, there's a subtle issue: **each call to `sessionChangedEvents()` creates a new Task that iterates the entire `eventStream()` from scratch**. If this method is called twice (e.g., reconnect), you'll have two tasks consuming the same `eventContinuation` in `GatewayClient`, and events will be interleaved between them.

The existing `eventProcessingTask` in `SyncBridge.start()` already consumes `eventStream()` via the `EventRouter`. Adding a second consumer means **event routing will be non-deterministic** — events may be consumed by the router or the session-changed stream or both, depending on timing.

**Recommended fix:** Instead of a second consumer, emit session-changed signals from within the existing `EventRouter` pipeline. Either:
1. Add a `SessionChangedPublisher` (Combine/AsyncStream) that the EventRouter feeds into, OR
2. Make `sessionChangedEvents()` consume from a shared passthrough rather than the raw eventStream

**Confidence:** MODERATE — this depends on how `GatewayClient.eventStream()` delivers to multiple consumers. If it broadcasts (each continuation gets every event), there's no data loss but there's duplicate work. If it's fan-out (each event goes to one consumer), this silently drops events.

### W2 — `TopicError.offlineTopicCreationNotSupported` Not Defined

The spec's Step 4 references `TopicError.offlineTopicCreationNotSupported`, but the current `TopicError` enum only has three cases: `nameRequired`, `nameTooLong`, `gatewayNotConnected`.

**Action required:** Either add the case or use an existing one. Minor but the spec should be accurate.

### W3 — Full Re-list on Every `sessions.changed` Event Is Inefficient

The spec explicitly says "No incremental sync in Phase 2" and proposes a full `fetchSessionInfos()` → `upsertTopicsFromGateway()` on every `sessions.changed` event. This works, but:

- If the Mac creates/renames 5 topics in rapid succession, the gateway may emit 5 `sessions.changed` events, and the iPhone will run 5 full syncs.
- `sessions.list` is not free — it involves an RPC call through the gateway, JSON decode, and metadata extraction.

**Recommended mitigation:** Add a debounce coalesce — e.g., yield one sync signal for all `sessions.changed` events within a 2-second window. The ViewModel already has `reconnectDebounceSeconds` config; apply a similar pattern here.

Not a blocker for Phase 2, but should be noted for Phase 3.

### W4 — `TopicRepository.upsertTopicsFromGateway` Doesn't Handle `lastMessagePreview` or `lastActivityAt`

The spec's upsert only touches: `name`, `isArchived`, `projectPath`, `updatedAt`. But the `Topic` struct has `lastMessagePreview`, `lastActivityAt`, and `unreadCount` which are populated from gateway sessions in the existing `connect()` flow (Step 4 of the current code).

The new `upsertTopicsFromGateway` should either:
- Also update `lastMessagePreview` and `lastActivityAt` from `SessionInfo`, OR
- Be called alongside a metadata refresh that handles these fields

Otherwise, after the Phase 2 upsert, topic preview and timestamp data will become stale.

### W5 — iOS Build Cannot Be Validated via `swift build`

The BeeChat-Mobile Package.swift declares `.iOS(.v17)` but the BeeChat-v5 dependency declares `.macOS(.v14)`. The `swift build` on macOS cross-compiling for iOS fails with platform mismatch errors (confirmed). The mobile project must be built via Xcode (`xcodebuild -sdk iphoneos`), which means:
- CI/automated validation isn't straightforward
- The spec's exit criterion "`swift build` succeeds for both macOS and iOS platforms" is not achievable as written

**Recommendation:** Update the spec's exit criteria to use `xcodebuild` for iOS, or add iOS platform support to BeeChat-v5's Package.swift.

### W6 — Spec File References Are Partially Inaccurate

| Spec Says | Actual |
|---|---|
| `SessionInfo.swift` → `BeeChatModels` repo | Actually at `BeeChat-v5/Sources/BeeChatSyncBridge/Models/SessionInfo.swift` |
| `BeeChatTopicMetadata.swift` → `BeeChatModels` repo | Actually at `BeeChat-v5/Sources/BeeChatSyncBridge/Models/BeeChatTopicMetadata.swift` |
| `GatewayClient.swift` has `grantedScopes()` | Actually `grantedScopes()` is a method on `GatewayClient`, but the spec table calls it a file reference — the file exists at `BeeChat-v5/Sources/BeeChatGateway/GatewayClient.swift` |

These are documentation nits but worth cleaning up so the spec is a reliable reference.

---

## Nits

### N1 — `TopicRepository.upsertTopicsFromGateway` — JSON Encoding Is Overwrought

The spec's SQL section for `metadataJSON` does:
```swift
topic.metadataJSON = try? JSONEncoder().encode(
    ["projectPath": projectPath]
).map { String(data: $0, encoding: .utf8) }.flatMap { $0 }
```

This creates a `[String: String]` dictionary, encodes to Data, then converts back to String. It would be cleaner to directly create:
```swift
topic.metadataJSON = """{"projectPath":"\(projectPath.escaped())"}"""
```
Or use a dedicated metadata struct. The current approach works but is fragile — any special characters in `projectPath` would break the JSON.

### N2 — Spec Uses `info.key` But ViewModel Uses `session.id` Consistently

The `Session` struct has `id` (which IS the session key). `SessionInfo` has `key`. The spec switches between these without noting the mapping. In the ViewModel, gateway sessions are referenced as `session.id`. In the spec, it's `info.key`. These are the same value but the naming inconsistency could cause confusion during implementation.

### N3 — `TopicListView.swift` Doesn't Need Major Changes for Sync Indicator

The spec says TopicListView "needs change" for sync indicator UI, but the actual change is minimal — just a status text at the bottom of the sidebar. The existing `.overlay(alignment: .bottom)` pattern for the archive toast could be reused for the sync state. Worth noting the change is smaller than the spec implies.

### N4 — `SyncBridge.publishTopicState` Already Exists (Phase 1)

The spec's Step 5 (delete → gateway cleanup) and Step 7 (archive → gateway sync) call `bridge.publishTopicState()` and `bridge.clearTopicState()`. These already exist in SyncBridge. The spec should reference the existing methods rather than implying new work is needed on SyncBridge for these paths. The only new work is the ViewModel wiring to call them.

### N5 — `SessionInfo.beechatMetadata` Already Returns `nil` for Malformed Data

The spec's testing plan includes tests for "missing fields → returns nil." This is already handled by the `SessionInfo.beechatMetadata` computed property (uses optional chaining on `as? String` / `as? Bool`). The tests are still worth writing as regression guards, but they're testing existing behaviour, not new code.

### N6 — `Topic` Primary Key Is `id` (String UUID), But Spec Uses `metadata.topicId` for New Topics

The spec says for new topics: `id = metadata.topicId`. But the `Topic` init defaults `id` to `UUID().uuidString`. The spec code does correctly override this: `Topic(id: metadata.topicId, ...)`. However, `metadata.topicId` is a UUID string that **must match the session key suffix** (per `BeeChatTopicMetadata` docs: "UUID that MUST match the suffix of the session key"). The sync bridge's `publishTopicState` already validates this at runtime. The upsert method should include the same guard or at least log a warning on mismatch.

---

## Architecture Assessment

### What's Good
- **Gateway-as-truth model** avoids sync complexity. Correct choice for Phase 2.
- **`fetchSessionInfos()`** is a one-liner that exposes existing `rpcClient.sessionsList()` — minimal surface area, low risk.
- **`sessionChangedEvents()`** as an `AsyncStream<Void>` signal (not payload) keeps the consumer simple — caller does a full refresh.
- **No iPhone-side writes to gateway metadata** in Phase 2 — this keeps the trust model simple.
- **Existing `publishTopicState` / `clearTopicState`** are reused, not reimplemented.

### What's Risky
- **Multiple consumers on `GatewayClient.eventStream()`** (W1 above).
- **`operator.admin` scope unknown on iOS** — if the iPhone client doesn't have this scope, `sessions.pluginPatch` will fail silently, and iPhone topic CRUD won't sync. The spec acknowledges this in "Questions for Team" but doesn't gate on it.
- **Reconcile loop interaction** — `SyncBridge.start()` already calls `reconcileAllTopicState()`. The new `upsertTopicsFromGateway()` in `connect()` runs before `reconcileAllTopicState()`. If reconcile republishes topics that the upsert just modified, there's potential for a race where gateway metadata is overwritten by stale local data.

---

## Verdict: CONDITIONAL PASS

The spec is sound in architecture and approach. Implementation can proceed once:

1. **B1 is resolved** — confirm which TopicRepository methods exist vs need implementation, and add any missing ones to the implementation plan.
2. **B2 is fixed** — correct the `sessionKey` → `openclawSessionKey` column name in the upsert SQL.
3. **W1 is addressed** — decide on a single-consumer pattern for gateway events before adding a second `eventStream()` consumer.

Warnings W2–W6 should be addressed during implementation but are not showstoppers. Nits are optional improvements.

---

*Reviewed by Q · 2026-05-23T16:47:00+01:00*
