# Q Gate 2F Phase 2 — Final Validation (Spec v3)

**Date:** 2026-05-23
**Reviewer:** Q
**Spec:** `GATE-2F-PHASE2-IPHONE-TOPIC-SYNC.md` (v3)
**Verdict:** ❌ **FAIL** — 1 critical blocker + 3 warnings

---

## B9 (CRITICAL BLOCKER): Mac build will break — missing protocol method implementation

**Location:** Step 3 (extend `SyncBridgeDelegate`) + Step 4 (EventRouter fires new callback)

**Issue:** The spec adds `syncBridgeSessionsChanged(_ bridge:)` to the `SyncBridgeDelegate` protocol as a **required** method (no default implementation in a protocol extension). The Mac's `SyncBridgeObserver` in `Sources/App/UI/Observers/SyncBridgeObserver.swift` conforms to `SyncBridgeDelegate` and implements the 6 existing protocol methods. It does **not** implement `syncBridgeSessionsChanged`.

When Step 4's EventRouter change calls `bridge.delegate?.syncBridgeSessionsChanged(bridge)`, it dispatches to the same delegate object. On Mac, `SyncBridgeObserver` is the delegate. On iPhone, `BeeChatMobileViewModel` is the delegate. **The Mac won't compile** after Step 3 because `SyncBridgeObserver` doesn't satisfy the protocol conformance.

The previous reviewers all missed this. The B8 fix (remove second eventStream consumer → use delegate callback) is architecturally correct, but the delegate protocol change needs a default implementation:

```swift
// In SyncBridgeDelegate.swift, AFTER the protocol definition:
extension SyncBridgeDelegate {
    func syncBridgeSessionsChanged(_ bridge: SyncBridge) {
        // Default: no-op. Only iPhone ViewModel needs this.
    }
}
```

**Why this is a blocker:** Breaking the Mac build is unacceptable for an iPhone-only feature. The fix is trivial (one-line protocol extension), but it MUST be in the spec before implementation starts.

**Fix:** Add a protocol extension with a default no-op implementation for `syncBridgeSessionsChanged`. This way Mac's `SyncBridgeObserver` compiles without changes, and iPhone's `BeeChatMobileViewModel` overrides it.

---

## W4 (WARNING): Step 5 `upsertTopicsFromGateway` — GRDB write-transaction deadlock risk

**Location:** Step 5 — `TopicRepository.upsertTopicsFromGateway()`

**Issue:** The spec's `upsertTopicsFromGateway` calls `writer.write { db in ... }` (a GRDB write transaction). Inside that transaction, it calls `resolveTopicIdBySuffix(gatewayKey:stripped:)`. 

Looking at the actual `resolveTopicIdBySuffix` implementation:

```swift
public func resolveTopicIdBySuffix(gatewayKey: String, stripped: String) throws -> String? {
    try dbManager.reader.read { db in  // ← This acquires a reader from the pool
        // SQL queries...
    }
}
```

This is called **inside** a `writer.write` block. With `DatabasePool` (which is what `DatabaseManager` uses — see `dbPool: DatabasePool?`), `pool.write { db }` holds exclusive write access. Calling `pool.read { db }` from within that write closure attempts to acquire a reader from the pool's concurrent reader pool while the writer is active. 

GRDB's `DatabasePool` handles this correctly in most cases — nested `read` inside `write` on a `DatabasePool` will use the same database connection (it detects the existing write transaction). **However**, the nested call goes through `dbManager.reader.read`, which creates a *separate* `read { }` closure. GRDB may attempt to use a different reader connection from the pool, which will block waiting for the write lock that the outer closure already holds → **deadlock**.

This is not hypothetical — GRDB documentation explicitly warns about this pattern. When you're already inside a `write` closure, you should use the `db` parameter directly for reads, not call another method that opens its own `read` transaction.

**Evidence:** The current `TopicRepository` methods follow the same pattern (`dbManager.reader.read { }` or `dbManager.write { }` as entry points), but `upsertTopicsFromGateway` is the first method that calls one repository method from inside another repository method's write transaction.

**Two fixes:**
1. **Inline the resolution logic** inside the `writer.write` closure — use the `db` parameter directly for the SQL lookups instead of calling `resolveTopicIdBySuffix`.
2. **Change `resolveTopicIdBySuffix`** to accept an optional `db: Database` parameter. When called from inside a write transaction, pass the existing `db`; when called standalone, it opens its own read.

Fix option 1 is simpler and keeps the write atomic.

---

## W5 (WARNING): `nonisolated` delegate method accesses `self.lastSessionsChangedSync` without synchronization

**Location:** Step 8 — `syncBridgeSessionsChanged` delegate callback

**Issue:** The delegate method is declared `nonisolated` (correct — it's called from the `SyncBridge` actor). Inside it:

```swift
nonisolated public func syncBridgeSessionsChanged(_ bridge: SyncBridge) {
    Task { @MainActor in
        let now = Date()
        guard now.timeIntervalSince(self.lastSessionsChangedSync) >= 10 else { return }
        self.lastSessionsChangedSync = now  // ← Write from nonisolated context
        // ...
    }
}
```

The ViewModel is `@MainActor` (class-level isolation). The method is `nonisolated`, meaning it runs on whatever thread calls it (the SyncBridge actor's event processing task). The `self.lastSessionsChangedSync` read and write happen inside `Task { @MainActor in }`, which is correct for the MainActor hop.

However, there's a race condition: if two `sessions.changed` events arrive back-to-back, two `nonisolated` calls execute concurrently. Both enter their respective `Task { @MainActor in }` blocks. The MainActor serialises them, so only one executes at a time. The debounce guard (`timeIntervalSince >= 10`) works correctly under MainActor serialisation.

**This is actually fine** — the debounce state is only accessed on the MainActor. No real issue here. Downgrading to informational.

---

## W6 (WARNING): Step 6 PersistenceStore wrappers — method signature mismatch

**Location:** Step 6 — `BeeChatPersistenceStore` convenience wrappers

The spec adds 6 wrappers. Checking against actual `TopicRepository.swift` signatures:

| Spec wrapper | Actual TopicRepository method | Match? |
|---|---|---|
| `topicRepo.upsertTopicsFromGateway(entries)` | New method (defined in Step 5) | ✅ OK |
| `topicRepo.fetchAllActiveWithCounts()` | `fetchAllActive(limit:)` exists | ❌ **Method doesn't exist** — already noted in prerequisites |
| `topicRepo.fetchById(id)` | `fetchById` doesn't exist | ❌ **Method doesn't exist** — already noted in prerequisites |
| `topicRepo.archive(topicId:)` | `archive(topicId:)` doesn't exist | ❌ **Method doesn't exist** — already noted in prerequisites |
| `topicRepo.save(topic)` | `save(_ topic:)` exists | ✅ OK |
| `topicRepo.deleteCascading(id)` | `deleteCascading(_ id:)` exists | ✅ OK |

These mismatches are already captured in the spec's **Prerequisites** section (the table of 10 missing methods). The wrapper signatures in Step 6 match the *intended* signatures listed in prerequisites. This is a pre-existing dependency, not a spec defect.

**Note:** The `BeeChatPersistenceStore` currently has `private let topicRepo = TopicRepository()` as a property, and the ViewModel accesses it as `persistenceStore.topicRepo` (e.g., line 45: `persistenceStore.topicRepo.fetchAllActive(limit: 1)`). The `topicRepo` property is `private` in `BeeChatPersistenceStore` but the ViewModel accesses it directly. This already works because the Swift file likely has `internal` or `public` visibility in practice, or the compiler accepts it within the same module. Worth verifying at build time.

---

## W7 (WARNING): `BeeChatMobileViewModel` implements protocol methods not in the protocol

**Observation (not a blocker):** The ViewModel's `SyncBridgeDelegate` extension implements:

```swift
nonisolated public func syncBridge(_ bridge: SyncBridge, didStartManualReset sessionKey: String) {}
nonisolated public func syncBridge(_ bridge: SyncBridge, didStopManualReset sessionKey: String) {}
```

These methods are **not** declared in `SyncBridgeDelegate.swift`. They compile (Swift allows extra methods on protocol conformances), but they're dead code — nothing will ever call them through the protocol dispatch. If manual reset support is needed, the protocol should be extended. If not, these methods should be removed to avoid confusion.

---

## Phase 3 Pitfalls

### P1: `hasAdminScope` hard gate creates brittle dependency

The v3 spec gates all publishing on `hasAdminScope` at connect time. If the Mac publishes a topic while the iPhone is disconnected, then the iPhone reconnects and sees the topic via `sessions.changed` — but if `hasAdminScope` is false, the iPhone can't publish changes back. Phase 3's "bidirectional sync" will need to handle this asymmetric state. **Recommendation:** Track per-topic `canPublish` state rather than a global gate.

### P2: "Mac is master" model limits Phase 3 bidirectional sync

The v3 architecture assumes Mac → iPhone unidirectional flow. Phase 3 adds iPhone → Gateway direct publishing. The current `upsertTopicsFromGateway` always overwrites local with gateway data (no LWW, no CRDTs). When Phase 3 introduces iPhone-originating changes, the gateway's `sessions.changed` event will fire back to the iPhone with its own changes, creating a potential echo loop. **Recommendation:** Phase 3 should add an `origin` field or event dedup mechanism to distinguish self-originated changes from external ones.

### P3: 10-second debounce is aggressive for Phase 3's reconciliation

The 10-second debounce in Step 8 suppresses `sessions.changed` events. In Phase 3, when both devices can publish, rapid back-and-forth updates could be delayed by up to 10 seconds. This is acceptable for Phase 2 (metadata-only), but Phase 3 may need per-event dedup instead of time-based debounce.

### P4: `resolveTopicIdBySuffix` 5-step cascade is a Phase 3 enabler

The 5-step lookup (direct key → stripped key → case-insensitive suffix → bridge table ×2) is well-designed for Phase 3. It handles the key-format transition gracefully. No pitfalls here — this is actually good forward planning.

---

## Summary

| # | Type | Issue | Severity |
|---|---|---|---|
| B9 | Blocker | Mac build breaks — `SyncBridgeObserver` missing `syncBridgeSessionsChanged` | 🔴 Critical |
| W4 | Warning | GRDB write-transaction deadlock risk in `upsertTopicsFromGateway` | 🟡 Fix before impl |
| W5 | Warning→OK | Debounce state access — actually fine under MainActor serialisation | ✅ Resolved |
| W6 | Info | Wrapper signatures match prerequisites | ✅ Already tracked |
| W7 | Info | Dead `didStartManualReset`/`didStopManualReset` methods | ℹ️ Cleanup |

## Verdict: FAIL

The spec cannot pass until **B9** is resolved. The fix is a one-line protocol extension default, but it must be documented in the spec before implementation. Without it, the Mac build breaks and the team ships a regression.

**W4** should also be fixed in the spec (inline the read logic inside the write closure), though it's less severe — GRDB might handle the nested read gracefully in some pool configurations. Better to be explicit.

**Required changes for PASS:**
1. Add `extension SyncBridgeDelegate { func syncBridgeSessionsChanged(_ bridge: SyncBridge) { } }` default impl
2. Rewrite Step 5's `upsertTopicsFromGateway` to use `db` directly for resolution instead of calling `resolveTopicIdBySuffix` from inside the write transaction
