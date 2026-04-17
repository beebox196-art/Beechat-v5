# COMPONENT-1-REVIEW: BeeChatPersistence
**Reviewer:** Kieran — Continuous Review Gate
**Date:** 2026-04-17
**Component:** BeeChatPersistence (Phase 1)
**Status:** ⚠️ CONDITIONS PASS — ATTENTION ITEMS BEFORE COMPONENT 2

---

## Review Summary

The implementation is functionally sound for the happy path and meets all stated exit criteria. However, there are 4 **FAIL** findings that must be addressed before Component 2 (Gateway) builds on top, and several **WARN** items that will cause pain at scale or under adversarial conditions.

---

## PASS ✅

### Spec Compliance
- Schema matches spec exactly: all 4 tables present (`sessions`, `messages`, `attachments`), correct column names/types, all 3 indexes created.
- `MessageStore` protocol matches spec verbatim.
- `GatewayEventConsumer` protocol matches spec exactly.
- Package structure matches spec's directory layout.
- GRDB 7.x dependency declared correctly.

### Data Model
- All 4 models correctly conform to `Codable`, `FetchableRecord`, `MutablePersistableRecord`.
- `MessageBlock` exists as a model even though it's not persisted (used for content block representation in the UI layer — this is fine).
- Proper use of `public static let databaseTableName` on all persisted records.
- Date handling is consistent — all `Date` properties map to GRDB `.datetime` columns, which stores as ISO8601 text. Correct for GRDB's default behavior.

### Concurrency
- `DatabasePool` is the right choice over `DatabaseQueue` — allows concurrent reads via snapshots while serialising writes. Correct for a chat app with async UI.
- `prepareDatabase` hook correctly sets WAL mode before any transactions run. This is the correct place for it.
- Foreign keys explicitly disabled (`PRAGMA foreign_keys=OFF`) — matches spec rationale (partial sync scenarios).
- `DatabaseManager.shared` singleton pattern is acceptable for a single-package internal architecture.

### Migrations
- Migrations are named (`Migration001_CreateSessions`, `Migration002_CreateMessages`) and registered in order.
- GRDB's migrator is idempotent by design — re-running a registered migration is a no-op.

### Test Coverage (Happy Path)
- Tests use `XCTestCase` with proper `setUp`/`tearDown` creating unique temp DBs per test — test isolation is correct.
- WAL mode verified in `testDatabaseOpenAndWal`.
- Session CRUD verified.
- Message CRUD with mark-as-read verified.
- Attachment fetch by message verified.
- Upsert dedup behaviour verified (session count stays at 2 after re-upsert).

---

## WARN ⚠️

### 1. `createdAt` gets overwritten on every upsert (MutablePersistableRecord default)

**File:** `Session.swift`, `Message.swift`, `Attachment.swift`

GRDB's `MutablePersistableRecord.save()` defaults to `INSERT OR REPLACE` semantics when a record with the same primary key exists. This means:
- `createdAt` is **NOT** preserved on update — it gets overwritten with `Date()` (the default value expression in the INSERT).
- The `DEFAULT CURRENT_TIMESTAMP` on `createdAt` in the schema only applies to raw SQL INSERT; GRDB's `save()` builds an explicit INSERT with all columns, bypassing the default.

**Impact:** If the gateway sends a session update (e.g., new `title` or `lastMessageAt`), the `createdAt` timestamp will silently reset to the current time. For a cache that needs to preserve original creation time, this is wrong.

**Workaround needed:** Override `save()` to use `INSERT ... ON CONFLICT DO UPDATE SET ... WHERE` (upsert) that explicitly excludes `createdAt` from the SET clause, or use GRDB's `Request.merge` / `upsert` methods.

### 2. `fatalError` in `reader`/`writer`/`read`/`write` on unopened DB

**File:** `DatabaseManager.swift`

```swift
public var reader: DatabaseReader {
    guard let pool = dbPool else {
        fatalError("Database not open")  // ⚠️
    }
    return pool
}
```

`fatalError` will crash the app in production if code accidentally accesses the DB before opening. Should throw a proper error (`DatabaseError`) or return `nil`.

**Severity:** Medium — indicates design assumption that DB is always open before use, but that assumption may be violated during testing or early app startup.

### 3. `try!` in test `setUp`

**File:** `BeeChatPersistenceTests.swift`

```swift
try! store.openDatabase(at: dbPath)
```

If this fails, the test crashes with a silent trap rather than an XCTest failure. Use `try` and let XCTest's error propagation handle it, or at minimum use `try?` with an `XCTAssertNotNil`.

### 4. `markAsRead` SQL injection risk is mitigated but fragile

**File:** `MessageRepository.swift`

```swift
try db.execute(sql: "UPDATE messages SET isRead = 1 WHERE id IN (\(ids.map { _ in "?" }.joined(separator: ",")))", arguments: StatementArguments(ids))
```

The `\(ids.map...)` interpolation builds the `?,?,?` placeholder string safely, and `StatementArguments(ids)` binds them safely. This is **not** SQL injection — it's safe — but the code is hard to read and the intent could be misinterpreted. Consider using GRDB's `FilterColumn` or building the query more idiomatically:

```swift
try db.execute(sql: "UPDATE messages SET isRead = 1 WHERE id IN (\(ids: [String]))", arguments: ids)
// or
try Message.filter(ids: ["m1", "m2"]).updateAll(db, ["isRead": true])
```

### 5. `upsert` loops in a write transaction — N+1 writes

**File:** `SessionRepository.swift`, `MessageRepository.swift`

```swift
public func upsert(_ sessions: [Session]) throws {
    try dbManager.write { db in
        for session in sessions {   // ⚠️ N separate save() calls
            var session = session
            try session.save(db)
        }
    }
}
```

This is N individual INSERT/REPLACE operations. For large bulk syncs (e.g., 500 sessions), this could be slow. GRDB supports batch upsert. However, since `save()` uses SQLite's `INSERT OR REPLACE`, this is actually a single transaction with N statements — not as bad as N separate transactions, but still suboptimal. GRDB's `BatchInsert` or a single `INSERT ... ON CONFLICT DO UPDATE` would be better.

### 6. No cursor-based pagination — `limit/offset` is unsafe at scale

**File:** `SessionRepository.fetchAll`, `MessageRepository.fetchBySession`

Using `limit/offset` for pagination is correct for lazy loading in a chat UI (scrolling from newest backwards). However, if the UI re-sorts or inserts arrive mid-scroll, offsets become inconsistent. For a cache-backed chat UI this is generally acceptable, but it should be documented. Cursor-based (anchor timestamp + ID) would be more robust for real-time data.

### 7. No delete cascade — orphaned messages when session is deleted

**File:** `SessionRepository.delete`

```swift
try Session.deleteOne(db, key: id)  // Deletes only the session
```

Messages belonging to the deleted session remain in the DB as orphans. Attachments also remain. No `ON DELETE CASCADE` in schema, and no manual cascade in code. Component 2's gateway won't send messages for deleted sessions, so orphan messages won't affect sync — but they will waste storage and appear in any future "re-scan."

If Component 2 needs to clean up orphans, there's no `deleteSessionAndMessages` method.

### 8. `DatabaseManager.shared` singleton + default argument in repositories

**Files:** `BeeChatPersistenceStore.swift`, `SessionRepository.swift`, `MessageRepository.swift`, `AttachmentRepository.swift`

```swift
public init(dbManager: DatabaseManager = .shared) {
```

This creates a hidden global dependency. If `DatabaseManager.shared` is not opened before use, any repository call will `fatalError`. The singleton pattern is acceptable for this package, but it should be explicitly documented.

### 9. Schema extensibility — adding columns requires migration + code change

The schema uses `metadata TEXT` as an escape hatch (spec rationale #5), which is good. But adding a new required or indexed column requires:
1. A new migration file
2. A new `DatabaseMigrator.registerMigration` call in `DatabaseManager`
3. A model property (which GRDB won't persist without migration)

This is standard but worth noting: there is no mechanism to auto-generate migrations from model changes. Every schema evolution = manual migration.

### 10. No test for concurrent write safety

No test exercises simultaneous write attempts from multiple threads/actors. GRDB's serial write queue should handle this, but it's untested.

### 11. No test for Unicode, very long strings, or empty content

`content TEXT` in messages could legitimately be empty string, `nil`, or very long (e.g., 10KB+). These are untested. GRDB handles `String?` correctly, but `content = ""` vs `content = nil` may have different query behaviour.

### 12. `MessageBlock` is defined but never persisted or used

It exists in the models folder, conforms to `Codable`, but has no `FetchableRecord`/`MutablePersistableRecord`. It's essentially dead code unless Component 2 or the UI layer plans to use it as a separate table (not in the schema). Flag for clarification: is this a future table, or should it be removed?

---

## FAIL ❌

### FAIL-1: `createdAt` overwritten on every upsert (critical for cache correctness)

As noted in WARN #1. The `createdAt` column is supposed to track original creation time, but GRDB's default `save()` behaviour replaces the entire row on conflict. This silently corrupts cache metadata.

**Fix:** Override `save()` in `Session`, `Message`, and `Attachment` to use explicit upsert SQL that excludes `createdAt` from the SET clause, or use GRDB's `DatabaseRecord.upsert()` method with `onConflict: .replace` and an `set` parameter that omits `createdAt`.

### FAIL-2: No `upsertSessions` implementation in `SessionRepository` — code doesn't compile

Actually wait — `SessionRepository` does have `upsert`. But `BeeChatPersistenceStore.upsertSessions` calls `sessionRepo.upsert(sessions)` which is correct. The spec also defines `upsertMessages`. These are implemented.

**Correction:** Not a compile failure. But see WARN #1 about `createdAt` corruption on upsert.

### FAIL-3: No `deleteSessionAndMessages` or cascade — delete leaves orphan messages

When a session is deleted via `deleteSession(id:)`, existing messages remain as orphans. If Component 2's GatewayEventConsumer ever needs to delete a session and all its messages (e.g., user-initiated delete, GDPR request), there's no method for it.

**Fix:** Add `deleteSessionCascading(id: String)` that deletes messages and attachments in the same write transaction. Alternatively add `func deleteSession(id: String, cascade: Bool)` to the protocol.

### FAIL-4: `testDatabaseOpenAndWal` reads from `DatabaseManager.shared` not the local instance

```swift
var store: BeeChatPersistenceStore!   // local
// ...
let mode = try DatabaseManager.shared.read { ... }  // ⚠️ shared, not store's db
```

This test opens a DB at `dbPath` via `store` (which uses `DatabaseManager.shared` internally), then reads from `DatabaseManager.shared` — which should be the same instance. However, if `DatabaseManager.shared` is accessed before `store.openDatabase` is called, the test order matters. More critically, this couples the test to the global singleton rather than testing the store's own DB. For rigorous isolation, the test should open the DB, use the store's reader, and not touch the shared singleton directly.

**Fix:** Use `store` (via the store's internal dbManager access) or inject a test-specific `DatabaseManager`.

---

## ACTION ITEMS

### Priority 1 — MUST fix before Component 2

1. **[FAIL-1]** Fix `createdAt` overwrite on upsert. Override `save()` in `Session`, `Message`, `Attachment` to use explicit `INSERT ... ON CONFLICT DO UPDATE` that excludes `createdAt` from the SET. Test this specifically.

2. **[FAIL-3]** Add cascade delete for sessions. Add `deleteSessionCascading(id:)` to `SessionRepository` and surface it through `MessageStore.deleteSession` (or add a new protocol method). Delete messages first ( FK is not enforced, so manual ordering), then attachments, then the session — all in one write transaction.

3. **[FAIL-4]** Fix `testDatabaseOpenAndWal` to read from the local store's DB, not `DatabaseManager.shared`. Use `try store.using郭` or expose the store's reader. Or better: make `DatabaseManager` injectable and test against an isolated instance.

### Priority 2 — Should fix before Component 2

4. **[WARN-2]** Replace `fatalError` in `reader`/`writer`/`read`/`write` with throwing `DatabaseError.notOpen` or return `nil`. Make `reader` and `writer` computed properties throw or be optional.

5. **[WARN-3]** Change `try! store.openDatabase` in test `setUp` to `try`. Let XCTest's error handling work properly.

6. **[WARN-5]** Batch the upsert in a single SQL statement rather than N `save()` calls inside a transaction. Use `INSERT INTO sessions (...) VALUES (...), (...), (...) ON CONFLICT(id) DO UPDATE SET ...`. GRDB's `Database.batch` or raw SQL with multiple value tuples.

7. **[WARN-9]** Clarify `MessageBlock` purpose. Either remove it (dead code) or confirm it's the planned schema for a future `message_blocks` table and update the spec.

### Priority 3 — Nice to have before Component 2

8. **[WARN-6]** Document pagination approach and its limitations for real-time data. Consider a comment in the code.

9. **[WARN-10]** Add a concurrent write test: spawn N threads doing simultaneous inserts, verify all succeed and data is consistent.

10. **[WARN-11]** Add edge case tests: empty content, nil content, very long strings (10KB+), Unicode content including emoji and RTL scripts.

---

## Verdict

| Area | Status |
|------|--------|
| Spec compliance | ✅ PASS |
| Schema correctness | ✅ PASS |
| Compilation | ✅ PASS |
| Happy-path tests | ✅ PASS |
| Test isolation | ✅ PASS |
| Upsert correctness | ❌ FAIL (createdAt overwrite) |
| Delete cascade | ❌ FAIL (orphan messages) |
| Error handling robustness | ⚠️ WARN (fatalError) |
| Bulk operation efficiency | ⚠️ WARN (N+1 writes) |
| Future extensibility | ⚠️ WARN (no auto-migration) |

**Component 2 can start building** but must be aware that:
- `saveSession`/`saveMessage` as called from `handleSessionUpdate`/`handleMessageUpdate` will silently overwrite `createdAt`
- `deleteSession` does NOT delete messages
- The test that verifies WAL mode has a shared-singleton read that could be misleading

**Recommendation:** Fix FAIL-1, FAIL-3, and FAIL-4 before Component 2 begins integration. These will cause silent data corruption (FAIL-1) or missing data (FAIL-3) in production that will be hard to debug later.
