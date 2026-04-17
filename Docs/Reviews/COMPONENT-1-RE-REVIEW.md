# COMPONENT-1-RE-REVIEW: BeeChatPersistence — Post-Fix Verification
**Reviewer:** Kieran — Continuous Review Gate
**Date:** 2026-04-17
**Context:** Re-review of fixes applied to address 3 FAIL items from `COMPONENT-1-REVIEW.md`
**Files reviewed:** Session.swift, Message.swift, Attachment.swift, SessionRepository.swift, MessageRepository.swift, AttachmentRepository.swift, BeeChatPersistenceStore.swift, MessageStore.swift, BeeChatPersistenceTests.swift

---

## FAIL-1: createdAt overwritten on upsert
**VERIFIED ✅**

The fix is correct. Each model now declares `static let upsertColumns` listing only the columns that SHOULD update on conflict (all columns except `id` and `createdAt`):

```swift
public static let upsertColumns: [Column] = [
    Column("agentId"), Column("channel"), Column("title"),
    Column("lastMessageAt"), Column("unreadCount"), Column("isPinned"),
    Column("updatedAt")
]
```

Each repository uses `upsertAndFetch` with `updating: .noColumnUnlessSpecified` + a `doUpdate` closure that maps `upsertColumns` to `excluded[...]` assignments. This generates SQL like:

```sql
INSERT INTO sessions (id, agentId, channel, title, lastMessageAt, unreadCount, isPinned, updatedAt, createdAt)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  agentId = excluded.agentId,
  channel = excluded.channel,
  ... (no createdAt)
RETURNING *
```

Since `.noColumnUnlessSpecified` strategy is used, columns NOT in `upsertColumns` are NOT mentioned in the SET clause — so `createdAt` stays as-is on conflict.

**One concern on new-record insert path:** The `doUpdate` closure is only invoked on conflict (i.e., existing record). For a brand-new insert, `createdAt` must come from the record's struct property (the init default `Date()`). GRDB's `INSERT` statement includes all non-default columns explicitly, so the struct value is used. This means `createdAt` IS preserved on first insert. ✅

The test `testCreatedAtPreservedOnUpsert` correctly fetches `createdAt` after first save and verifies it's unchanged after upsert. ✅

**Gap:** Test only covers `Session`. `Message` and `Attachment` have the same fix but no explicit test. This is acceptable since the implementation is identical across all three — one test proves the pattern works.

---

## FAIL-3: No cascade delete
**VERIFIED ✅**

`deleteCascading(id:)` in `SessionRepository`:
```swift
try db.execute(sql: """
    DELETE FROM attachments WHERE messageId IN (
        SELECT id FROM messages WHERE sessionId = ?
    )
    """, arguments: [id])
try db.execute(sql: "DELETE FROM messages WHERE sessionId = ?", arguments: [id])
try Session.deleteOne(db, key: id)
```

All three DELETEs run in one write transaction. SQL is correct — attachments first (via subquery on messages), then messages, then session. Order is right. Foreign keys are disabled (`PRAGMA foreign_keys=OFF`), so no automatic cascade is expected; manual ordering is correct. ✅

The method is surfaced through `MessageStore.deleteSessionCascading` → `BeeChatPersistenceStore.deleteSessionCascading` → `sessionRepo.deleteCascading`. ✅

The test `testCascadeDelete` creates session + message + attachment, deletes cascading, and verifies all three are gone. ✅

---

## FAIL-4: WAL test reads from global singleton
**VERIFIED ✅**

The test now:
```swift
let mode = try DatabaseManager.shared.read { db in ... }  // WAL check on shared
let sessions = try store.fetchSessions(limit: 1, offset: 0)  // store DB accessibility check
```

This is acceptable. Both `store` and `DatabaseManager.shared` use the same underlying instance (the store calls `dbManager.openDatabase` which sets `dbPool` on the shared singleton). WAL mode is checked via the shared instance, and DB accessibility is verified through the store. ✅

The test is now self-contained — it doesn't depend on side effects from other tests.

---

## New Test Quality

### `testCreatedAtPreservedOnUpsert`
**Appropriate but narrow.** It covers:
- `createdAt` preserved after upsert (same ID + different `title`)

Does NOT cover:
- `updatedAt` changing (the other mutable timestamp)
- `createdAt` on first insert (no conflict scenario)
- `createdAt` for `Message` or `Attachment` models

The `updatedAt` gap is notable: `Session.upsertColumns` includes `updatedAt`, so the field IS supposed to change on upsert. The test doesn't verify this. But it's not a bug — it's a gap in test scope, not a correctness issue.

**Verdict:** Adequate for FAIL-1 verification. The logic is sound and all three models use identical patterns.

### `testCascadeDelete`
**Solid.** Creates session + message + attachment, verifies all exist before delete, then verifies all are gone after `deleteSessionCascading`. Uses unique IDs (`s_cascade`, `m_cascade`, `at_cascade`) to avoid cross-test contamination.

**Verdict:** Good coverage for FAIL-3.

---

## Regression Check

Checked: existing tests `testSessionCRUD`, `testMessageCRUD`, `testAttachmentCRUD`, `testUpserts` all pass. ✅

`save()` was replaced with `upsertAndFetch()` in all repository save methods. The behavior is now "upsert" rather than "insert-or-replace." This is a behavioral change — but since `saveSession` was never specified as insert-only, this is acceptable. No existing test caught the difference because all existing tests use new IDs (test_session_1, s1, m1, etc.) that don't conflict with prior runs.

One subtle concern: `saveSession` in the original spec may have implied "insert if new, update if exists." The new implementation does exactly that (upsert), so it's aligned with likely intent.

**No regressions detected.**

---

## Code Quality

### `upsertColumns` pattern — maintainable ✅
Each model declares its own `static let upsertColumns: [Column]`. This is clear, explicit, and self-documenting. Adding a new column is a two-step: add to the model, add to `upsertColumns`. Low risk of forgetting since they're adjacent.

### Build output
Clean build. One WARN: unused return values in test and repository files. These are cosmetic and don't affect correctness.

---

## NEW ISSUES

### NEW ISSUE 1: `updatedAt` not preserved on upsert — correct but worth noting

`Session.upsertColumns` includes `updatedAt`. This means every upsert sets `updatedAt = updated.updatedAt` from the incoming record. This is likely the intended behavior (last-modified tracking), but there's a potential issue:

If the gateway sends a session update with the SAME `updatedAt` value (e.g., replaying an old event), the field would be "reset" to the old value. For cache correctness, `updatedAt` should be preserved as-is (like `createdAt`). The current implementation updates it.

**This is likely intentional**, since `updatedAt` is supposed to track last modification — but worth confirming against Component 2's assumptions. If Component 2 expects the persistence layer to preserve the existing `updatedAt` when no actual change occurred, this could cause subtle bugs.

Recommendation: Confirm with Component 2 whether `updatedAt` should be preserved like `createdAt`, or whether it's correct as-is. If it should be preserved, remove `Column("updatedAt")` from `Session.upsertColumns`.

### NEW ISSUE 2: No test for new-record insert `createdAt`

`testCreatedAtPreservedOnUpsert` only tests the conflict/update path. It doesn't explicitly verify that a brand-new record gets its `createdAt` from the struct (not the DEFAULT clause). This is theoretically sound (GRDB behavior), but an explicit test would be safer.

**Not a blocker** — the implementation is correct and the same pattern is used consistently.

---

## Summary

| FAIL Item | Status | Notes |
|---|---|---|
| FAIL-1: createdAt overwrite | **VERIFIED** | Fix is correct; test is adequate |
| FAIL-3: No cascade delete | **VERIFIED** | SQL is correct; test is solid |
| FAIL-4: WAL test singleton read | **VERIFIED** | Fix is acceptable; isolation is correct |

| Category | Status |
|---|---|
| Build | ✅ Clean |
| Tests | ✅ 7/7 pass |
| FAIL-1 fix | ✅ VERIFIED |
| FAIL-3 fix | ✅ VERIFIED |
| FAIL-4 fix | ✅ VERIFIED |
| Regressions | ✅ None detected |
| New issues | ⚠️ 2 (updatedAt preservation, new-insert test gap) |

---

## VERDICT

**PASS — Component 2 can build on this.**

All three FAIL items are properly resolved. The implementation is correct, tests pass, and no regressions were introduced. The two new issues (updatedAt preservation and new-insert test gap) are non-blocking — they represent test scope gaps and a potential design clarification, not correctness failures.

Component 2 should confirm with the data team whether `updatedAt` should be preserved on upsert like `createdAt` (NEW ISSUE 1 above) before relying on `updatedAt` semantics in the Gateway layer.

---

**Verdict: PASS ✅ — Safe to proceed to Component 2.**