# Topic Archiving — Round 2 Fix Summary

**Author:** Q (implementer)
**Date:** 2026-06-30
**Subject:** Two follow-up fixes from Kieran's Round 1 review
**Source review:** `Docs/Specs/Active/topic-archiving-review-round1.md`

---

## Scope

Round 1 review identified two items that needed to land before merge:

1. **M2 (must-fix)** — `TopicRepository.fetchAllActive()` missing the COALESCE
   guard, inconsistent with `fetchAllActiveWithCounts()` and the observer filter.
2. **S2 (should-fix)** — `MainWindow.requestNewTopic()` doesn't reset the
   orphaned selection when toggling from Archived → Active.

Both have been applied. One nits/should-fix item from Round 1 (S1 observer
startup logging, S3 menu ordering, N1 weak-capture, N3 default value, N5 hide
Mark-as-Unread in archived) is intentionally out of scope for this round per
the task brief.

---

## Change 1 — M2: COALESCE guard on `fetchAllActive()`

**File:** `Sources/BeeChatPersistence/Repositories/TopicRepository.swift`
**Lines:** 151–158 (unchanged location; body modified)

### Before

```swift
public func fetchAllActive(limit: Int = 100) throws -> [Topic] {
    try dbManager.reader.read { db in
        try Topic
            .filter(Column("isArchived") == false)
            .order(Column("lastActivityAt").desc)
            .limit(limit)
            .fetchAll(db)
    }
}
```

### After

```swift
public func fetchAllActive(limit: Int = 100) throws -> [Topic] {
    try dbManager.reader.read { db in
        try Topic
            .filter(sql: "COALESCE(isArchived, 0) = 0")
            .order(Column("lastActivityAt").desc)
            .limit(limit)
            .fetchAll(db)
    }
}
```

### Why

Spec §4 mandated the COALESCE guard for the Active view because `isArchived`
is not NOT NULL (defaults to `false` but legacy pre-Migration005 rows may be
NULL). The guard was applied to:

- `fetchAllActiveWithCounts()` (line 38) — already correct.
- `startTopicObservation(archived: false)` filter (`MainWindow.swift:357`) — already correct.
- `fetchAllActive()` (line 151) — **missing**, fixed in this change.

`fetchAllActive()` is called from:

- `Sources/App/UI/MainWindow.swift:417` — `rewireForGateway()` migration loop.
  Without COALESCE, NULL rows from pre-migration data were skipped here,
  meaning the migration could miss them.
- `Sources/BeeChatSyncBridge/TopicServer.swift:132` — mobile sync. NULL rows
  are now included in iOS sync, mirroring the macOS Active view.
- `Sources/BeeChatPersistence/BeeChatPersistenceStore.swift:61` — general
  listing; same NULL-safety fix applies.

The fix is one line of code and brings the bare method into spec compliance.

---

## Change 2 — S2: Reset orphan selection in `requestNewTopic()`

**File:** `Sources/App/UI/MainWindow.swift`
**Function:** `requestNewTopic()` (lines ~515–525; the brief cited 445–451
but the implementation has shifted with surrounding growth — body shape is
identical to the review's reference snippet)

### Before

```swift
private func requestNewTopic() {
    if showArchived {
        showArchived = false
        startTopicObservation(archived: false)
    }
    showNewTopicDialog = true
}
```

### After

```swift
private func requestNewTopic() {
    if showArchived {
        showArchived = false
        startTopicObservation(archived: false)
        // Clear orphaned selection: archived topic is no longer visible in Active view
        if let selected = messageViewModel.selectedTopicId,
           !messageViewModel.topics.contains(where: { $0.id == selected }) {
            messageViewModel.selectedTopicId = nil
        }
    }
    showNewTopicDialog = true
}
```

### Why

When the user is viewing the Archived tab and selects an archived topic,
then clicks "New Topic":

1. `showArchived = false` flips the view to Active.
2. `startTopicObservation(archived: false)` swaps the observer; the
   next tick removes the archived topic from `messageViewModel.topics[]`.
3. **`selectedTopicId` still pointed at the archived topic.**

Result: the detail pane kept rendering the archived conversation under the
Active view (composer disabled, but messages still visible). This violated
the "Active view shows active topics" expectation.

The fix checks whether the currently selected topic is still in the
post-swap `topics[]` array. If not, the selection is cleared. This is
defensive and idempotent — `MessageViewModel.updateTopics(from:)` already
performs the same fallback (line 79–82) when the observer lands, but that
arrives asynchronously and there is a window between `startTopicObservation`
returning and the next DB tick where the orphan selection is still live.
Setting `selectedTopicId = nil` synchronously closes that window.

We chose direct assignment over `removeTopic(id:)` because:

- The user is *creating a new topic*, not deleting one. Removing from the
  in-memory topics list would also remove the archived row from the
  visible list, which is already handled by the observer swap.
- Setting to `nil` leaves selection empty until the new-topic flow picks
  it, which is the natural UX ("you're starting fresh").
- `removeTopic(id:)` would fall back to `topics.first?.id`, picking an
  arbitrary active topic — slightly noisier UX for a "New Topic" action.

---

## Verification

### Build

```
$ swift build --target BeeChatPersistence
Build of target: 'BeeChatPersistence' complete! (0.97s)

$ swift build --target BeeChatApp
Build of target: 'BeeChatApp' complete! (2.48s)
  [1 pre-existing warning at MainWindow.swift:590 — unrelated to this change,
   flagged by Kieran in Round 1 review]
```

Both targets compile cleanly. The only warning is pre-existing and was called
out in the Round 1 review (unused `sessionKey` binding in the local-delete
path, line 590). Not addressed here — out of scope.

### Tests

```
$ swift test
…
Test Suite 'BeeChatPersistenceTests' passed at 2026-06-30 10:37:16.248.
    Executed 20 tests, with 0 failures (0 unexpected) in 0.312 seconds
…
Test Suite 'All tests' passed at 2026-06-30 10:37:10.974.
    Executed 155 tests, with 0 failures (0 unexpected) in 1.468 seconds
```

**Result: 155 / 155 tests passing, 0 failures.**

All 5 topic-archiving tests confirmed green:

| Test | Status | Time |
|---|---|---|
| `testFetchAllActiveWithCounts_ExcludesArchived` | ✅ passed | 0.013s |
| `testFetchAllArchivedWithCounts_ReturnsOnlyArchived` | ✅ passed | 0.013s |
| `testTopicArchive_SetsIsArchivedTrue` | ✅ passed | 0.019s |
| `testTopicRestore_SetsIsArchivedFalse` | ✅ passed | 0.018s |
| `testTopicsSchemaHasIsArchivedNotNull` | ✅ passed | 0.016s |

The Round 1 review noted that **no test directly exercises the
observer-level COALESCE guard** (the gap at the bottom of §7 in the
review). This remains a follow-up recommendation; the SQL-layer test
(`testFetchAllActiveWithCounts_ExcludesArchived`) still covers the
predicate pattern, and `fetchAllActive` now uses the identical pattern.

---

## Files Touched

- `Sources/BeeChatPersistence/Repositories/TopicRepository.swift` — 1 line
  changed in `fetchAllActive()` filter clause.
- `Sources/App/UI/MainWindow.swift` — 4 lines added inside
  `requestNewTopic()`.
- `Docs/Specs/Active/topic-archiving-fix-round2.md` — this summary.

Total diff: **+5 / −1**.

---

## Hand-back Notes

Both Round 1 must-fix items (M2, S2) are now closed. The remaining Round 1
items are explicitly non-blocking and out of scope for this round:

- **S1** — observer startup logging / UI feedback (deferred)
- **S3** — context menu ordering UX gut-check (no code change recommended)
- **N1** — `[weak messageViewModel]` capture semantics (style nit)
- **N3** — unused `""` initial value on `sidebarErrorTitle` (style nit)
- **N5** — hide Mark-as-Unread in Archived view (low-priority UX)
- **Round 1 §7 missing test** — observer-level COALESCE test (follow-up)

The implementation is ready to merge from a Round 1 standpoint. The S1
follow-up is the only Round 1 item with real user-visible impact
(silent failure on observer startup), worth a ticket in the next
iteration.