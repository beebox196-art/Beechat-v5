# Topic Archiving — Adversarial Code Review (Round 1)

**Reviewer:** Kieran (Adversarial)
**Date:** 2026-06-30
**Subject:** `feature/topic-archiving` implementation
**Verdict:** ✅ **Ship with two must-fix items + several nits**

The implementation is solid, faithful to the spec, and addresses every named
review concern from the prior round (Fix 1 / Fix 2 / Fix 3). All 5 spec tests
are present and well-scoped. The impl deliberately documents its deviations
(spec test 5, fetchAllActive COALESCE-only) with rationale instead of silent
changes — that's the right discipline for v1.

Two real bugs need fixing before merge. They are narrow and surgical.

---

## Must-fix (blocker for merge)

### M1. Selected-topic fallback after `archiveTopic` is too late on the Active view

**File:** `Sources/App/UI/MainWindow.swift:411-419`

```swift
private func archiveTopic(_ id: String) {
    Task { @MainActor in
        do {
            let topicRepo = TopicRepository()
            try topicRepo.archive(topicId: id)
            if messageViewModel.selectedTopicId == id {
                messageViewModel.removeTopic(id: id)
            }
        } catch { ... }
    }
}
```

**Problem.** On the **Active view**, after `archive(topicId:)` runs, the row
disappears from `messageViewModel.topics[]` via ValueObservation on the
*next* database tick. `removeTopic(id:)` already exists for the delete
path and *does* set `selectedTopicId = topics.first?.id` (verified by
existing usage). Calling it here after the DB write is fine — the code
calls `removeTopic` correctly. ✅ **Re-classifying:** I initially flagged
this; on closer reading, the impl correctly mirrors the delete path
(R1 mitigation per spec). It is correct as written.

However, there is a **subtle race** I want called out for awareness
(non-blocking):

- `topicRepo.archive()` → DB write commits.
- ValueObservation's `onChange` fires → calls
  `messageViewModel.updateTopics(from:)` → removes the archived topic
  from the topics array.
- Either order works for selection fallback because `removeTopic(id:)`
  unconditionally sets `selectedTopicId = topics.first?.id` regardless
  of whether the topic was already removed from the array.

If the observer tick lands between `archive()` and `removeTopic()`, the
selection points at a topic that is no longer in `topics[]` for one
frame. `removeTopic` is idempotent and falls back to `topics.first?.id`,
so this resolves immediately. **No user-visible glitch.**
**Severity:** Low. No fix needed; document if revisiting later.

### M2. `TopicRepository.fetchAllActive()` is missing the COALESCE guard — inconsistent with the spec's NULL-safety fix

**File:** `Sources/BeeChatPersistence/Repositories/TopicRepository.swift:151-158`

```swift
public func fetchAllActive(limit: Int = 100) throws -> [Topic] {
    try dbManager.reader.read { db in
        try Topic
            .filter(Column("isArchived") == false)   // <-- no COALESCE
            .order(Column("lastActivityAt").desc)
            .limit(limit)
            .fetchAll(db)
    }
}
```

**Problem.** Spec §4 explicitly says "the active view needs the `COALESCE`
guard; archived view strictly matches `= 1`." The fix was applied to
`fetchAllActiveWithCounts()` (line 38) and to the new
`startTopicObservation(archived: false)` filter
(`MainWindow.swift:357`), but **NOT** to the bare `fetchAllActive()` method.

This method is called from:
- `Sources/App/UI/MainWindow.swift:417` — `rewireForGateway` migration
  loop. Used to enumerate topics whose `sessionKey` is a bare UUID, so
  the migration needs to see ALL active-or-NULL topics. NULL rows would
  currently be skipped here.
- `Sources/BeeChatSyncBridge/TopicServer.swift:132` — mobile sync.
  Spec §5 deliberately excludes archived topics from iOS sync;
  NULL rows are ambiguous (treated as "not flagged archived" should
  probably still sync, otherwise behaviour is asymmetric with macOS).
- `Sources/BeeChatPersistence/BeeChatPersistenceStore.swift:61` —
  used for general listing (verify what this is called from).

**Fix.** Update to mirror `fetchAllActiveWithCounts`:

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

**Same change applies to `Sources/App/UI/MainWindow.swift:417` if any
new caller goes through the simpler `fetchAllActive`** — though for the
migration use case, the version with COALESCE is strictly safer (NULL
means "we don't know if this is archived"; the active view is the
correct fallback per spec §4).

---

## Should-fix (not blockers but the team should agree)

### S1. `startTopicObservation` does not log start-of-observation failures loudly enough

**File:** `Sources/App/UI/MainWindow.swift:335-368`

When `try topicRepo.startTopicObservation` fails (`DatabaseManager.shared.writer`
throws — which only happens on DB corruption or first-run race), the error is
logged via `BeeChatLogger.log(...)` and the function returns. The user sees
an empty/unchanged sidebar with no UI feedback.

Compare the existing `fetchAllActiveWithCounts()` failures — they propagate
as exceptions and `archiveTopic` / `restoreTopic` set the sidebar error
state. But for *observer startup* failure, the user gets a silent empty list.

**Recommendation (pick one):**
- Treat observer-startup failure as an alertable error (set
  `sidebarErrorTitle = "Topic Sync Error"` and show the alert), OR
- Add a brief inline indicator in the empty sidebar
  ("Could not load topics. Tap to retry.").

This is **NOT a blocker** for v1 because:
- `DatabaseManager.shared.writer` only throws on truly catastrophic DB
  corruption.
- The OBVIOUS UI signal is "sidebar empty" which a user will notice
  immediately.

But this is the kind of thing that becomes a bug report. Worth a follow-up
ticket.

### S2. `requestNewTopic()` does not also reset selection when archiving/restore is open

**File:** `Sources/App/UI/MainWindow.swift:425-432`

```swift
private func requestNewTopic() {
    if showArchived {
        showArchived = false
        startTopicObservation(archived: false)
    }
    showNewTopicDialog = true
}
```

If the user is currently viewing an **archived** topic (selected, even
though composer is disabled), and clicks New Topic:
1. `showArchived = false` → observer swaps.
2. `topics[]` refreshes from DB → archived topic disappears from the list
   (because archived topics are filtered out of the Active view).
3. `selectedTopicId` still points at the archived topic id → **selection
   points at a non-existent topic.**

The detail pane (`if messageViewModel.selectedTopic != nil { ... }`) will
keep rendering the archived topic's messages until something else clears
the selection. The composer is `.disabled(true)` so the user can't send —
but they can see the conversation from the archived session as if it
were active, which contradicts the "Active view shows active topics"
expectation.

**Fix.** After toggling to Active, clear the orphaned selection:

```swift
private func requestNewTopic() {
    if showArchived {
        showArchived = false
        startTopicObservation(archived: false)
        // Force selection reset: a topic visible only in Archived view
        // is now invisible in Active view, but selectedTopicId still
        // points at it. Clearing selection avoids a brief state where
        // the detail pane shows an archived topic in the active view.
        if let selected = messageViewModel.selectedTopicId,
           !messageViewModel.topics.contains(where: { $0.id == selected }) {
            messageViewModel.selectedTopicId = nil
        }
    }
    showNewTopicDialog = true
}
```

Or call `messageViewModel.removeTopic(id: selected)` to fall back to
`topics.first?.id` automatically (consistent with the archive/delete path).

### S3. Context menu ordering in `SessionRow.swift` — Archive/Restore placement is non-ideal

**File:** `Sources/App/UI/Components/SessionRow.swift:202-216`

The current context menu order on the **active view** is:
1. Edit Topic
2. Save Topic Summary
3. Reset Session
4. Mark as Unread / Mark as Read
5. **Archive** ← appears here
6. (Divider — but Divider is below Archive, not directly between items)

On the **archived view**:
1. Edit Topic
2. (Save Topic Summary hidden ✓)
3. (Reset Session hidden ✓)
4. Mark as Unread / Mark as Read
5. **Restore**
6. (Divider — below)

**Issue.** Spec §3b code example says "after existing items, before the
Divider", and the impl matches. But the **destructive** operation
(Mark-as-Unread/Read, then Archive) sits before what feels like the
"meta-action" tier. BeeBoard's pin-archive reference puts the archive
action near the destructive bottom of the menu. This is consistent,
**not a bug** — but worth a UX gut-check from Mel.

**Recommendation.** No code change. Flagging for design parity review
post-merge.

---

## Nit-picks (style, not bugs)

### N1. `MessageViewModel` is captured via `[weak messageViewModel]` but `@State` wrappers aren't quite weak references

**File:** `Sources/App/UI/MainWindow.swift:362-365`

```swift
onChange: { [weak messageViewModel] topics in
    messageViewModel?.updateTopics(from: topics)
}
```

`@State` properties in SwiftUI are not actually `weak` — they live for
the lifetime of the view. The `[weak messageViewModel]` capture is
misleading but harmless. There's no leak (the view holds the `@State`)
but the capture list suggests something different from what's happening.

**Recommendation.** Either drop the weak capture
(`{ messageViewModel.updateTopics(from: topics) }`) or add a comment
explaining why we use weak for a `@State`-backed value. Style preference
— not blocking.

### N2. Impl notes `+220 / -25 ≈ +195` — slightly inflated by doc comments

This is fine. The ~110 estimate in the spec refers to *logic* lines; the
extra ~85 are mostly doc comments justifying the COALESCE guard,
observer-swap rationale, and sidebar-error alert separation. These
comments are load-bearing for future maintainers (especially the
"archived-view intentionally excludes NULL rows" rationale). Keep them.

### N3. `sidebarErrorTitle: String = ""` initial value is unused

**File:** `Sources/App/UI/MainWindow.swift:30`

The state is always set before the alert is shown (only `archiveTopic`
and `restoreTopic` set `showSidebarError = true`, and both set the title
immediately before). The empty-string default is defensive but
unreachable. Not worth changing — could remove `""` initial value with
`@State private var sidebarErrorTitle: String` and let it be `nil`-ish
via Optional, but consistency with the other error states wins. NIT.

### N4. `restoreTopic` does not auto-select the restored topic

**File:** `Sources/App/UI/MainWindow.swift:431-440`

Spec documents this explicitly in "Open Items / Future Work". The
behaviour is: after restoring, the sidebar refreshes (Active view shows
the restored topic), but selection stays where it was. This is **intentional**
per spec ("no auto-restore on new messages, R3"). Not a bug.

### N5. `SessionRow.isArchived` parameter controls menu visibility, but the `Mark as Unread / Read` items still appear in the archived view

**File:** `Sources/App/UI/Components/SessionRow.swift:179-191`

In archived view, you can still mark an archived topic as unread/read.
This isn't *spec'd out of scope* — the spec §3c lists composer, reset,
save summary, delete, and "no destructive actions in Archived view" as
the disabled/hidden items. Mark-as-Unread is not destructive, so this
is **allowed by spec**.

**However.** The archived view is supposed to be read-only and dormant.
Marking an archived topic as read in the archived view feels off —
unread counts on archived topics don't really mean anything because
the user doesn't see them anywhere actionable.

**Recommendation (low priority):** consider hiding Mark-as-Unread in
archived view too. NOT a blocker; spec is silent on this. Discuss with
team in next iteration.

---

## Spec compliance — full pass

| Spec item | Where | Status | Notes |
|---|---|---|---|
| 1. `restore(topicId:)` | `TopicRepository.swift:89-97` | ✅ | Exact spec match |
| 2. `fetchAllArchivedWithCounts(limit:)` | `TopicRepository.swift:60-73` | ✅ | Exact spec match |
| 3. `COALESCE` in `fetchAllActiveWithCounts` | `TopicRepository.swift:38` | ✅ | Exact spec match |
| 4. `startTopicObservation(archived:)` | `MainWindow.swift:335-368` | ✅ | Exact spec match |
| 5. Rename cancellable | `MainWindow.swift:11` | ✅ | `topicCancellable` only, no legacy |
| 6. `stop()` cancels `topicCancellable` | `MainWindow.swift:217-220` | ✅ | Replaces `localTopicCancellable` |
| 7. `@State showArchived` | `MainWindow.swift:29` | ✅ | Added |
| 8. Segmented Picker (Active/Archived) | `MainWindow.swift:81-92` | ✅ | Above `sidebarList`, themed |
| 9. `.onChange(of: showArchived)` | `MainWindow.swift:88-90` | ✅ | Calls `startTopicObservation(archived:)` |
| 10. `onArchive` / `onRestore` params | `SessionRow.swift:15-16` | ✅ | Defaults `nil`, mutually exclusive |
| 11. Archive/Restore context menu items | `SessionRow.swift:202-216` | ✅ | Exact SF symbols; ordered correctly |
| 12. `archiveTopic(_ id:)` handler | `MainWindow.swift:411-419` | ✅ | Follows delete pattern (R1) |
| 13. `restoreTopic(_ id:)` handler | `MainWindow.swift:429-440` | ✅ | Wraps errors into sidebar alert |
| 14. Sidebar error alert state | `MainWindow.swift:30-32` | ✅ | 3 separate `@State` vars |
| 15. `.alert(sidebarErrorTitle, ...)` | `MainWindow.swift:266-271` | ✅ | Separate from `showDeleteAlert` |
| 16. Composer disabled when archived | `MainWindow.swift:215-216` | ✅ | `.disabled(true)` + `.opacity(0.5)` + a11y label |
| 17. Hide Reset/Save Summary in archive | `SessionRow.swift:152,170` | ✅ | Both items wrapped in `if !isArchived` |
| 18. Delete key disabled in archive | `MainWindow.swift:185-187` | ✅ | Returns `.ignored` when archived |
| 19. New Topic forces `showArchived = false` | `MainWindow.swift:445-451` | ⚠️ | Works, but selection fallback missing — see **S2** |
| 20. `testTopicArchive_SetsIsArchivedTrue` | `BeeChatPersistenceTests.swift:276` | ✅ | Spec-compliant |
| 21. `testTopicRestore_SetsIsArchivedFalse` | `BeeChatPersistenceTests.swift:292` | ✅ | Spec-compliant |
| 22. `testFetchAllArchivedWithCounts_ReturnsOnlyArchived` | `BeeChatPersistenceTests.swift:306` | ✅ | Spec-compliant |
| 23. `testFetchAllActiveWithCounts_ExcludesArchived` | `BeeChatPersistenceTests.swift:330` | ✅ | Spec-compliant |
| 24. `testTopicsSchemaHasIsArchivedNotNull` | `BeeChatPersistenceTests.swift:360` | ✅ (adapted) | See notes below |

**Spec compliance: 24/24 (one noted, see S1)**

---

## Per-area review

### 1. Observer lifecycle — clean

`MainWindow.swift:335-368` (the `startTopicObservation(archived:)` body):

- `topicCancellable?.cancel()` first, then `topicCancellable = nil` —
  eliminates the dual-observer race.
- `onChange` uses `[weak messageViewModel]` — defensive against future
  refactors (currently no-op because `@State` owns the lifetime).
- `scheduling: .mainActor` — correct, ValueObservation callbacks need
  main-actor for SwiftUI updates.

**Rapid-toggle stress test (mental, not running).** Toggling Active ↔
Archived 10 times quickly:
1. Each toggle cancels the previous cancellable and starts a new one.
2. The previous observer's pending DB read is cancelled by GRDB.
3. The previous observer's pending main-actor dispatch is also cancelled
   (cancellables own their scheduling tokens).
4. Final state: one cancellable live, exactly the one matching the
   current `showArchived` value. ✅ No leak.

**`.onDisappear` cleanup** (line 218): correctly cancels. No leak. ✅

### 2. Archived view restrictions — solid

All four restrictions are present and correctly wired:

- **Composer disabled** (`MainWindow.swift:212-216`): `.disabled(showArchived)`
  + `.opacity(0.5)` + accessibility label flips to "Composer disabled —
  archived view is read-only". ✅
- **Delete key** (`MainWindow.swift:184-188`): early `return .ignored`. ✅
- **Delete notification** (`MainWindow.swift:189-194`): same early return. ✅
- **Save Topic Summary / Reset Session context menu** (`SessionRow.swift:152,170`):
  wrapped in `if !isArchived`. ✅
- **Trash button** (`MainWindow.swift:139-156`): hidden via
  `if ... && !showArchived`. ✅ (bonus, not strictly required by spec)

**One gap** — see S2 above: New Topic button doesn't reset selection
when toggling out of archived view.

### 3. NULL safety — partial

- ✅ `fetchAllActiveWithCounts` (line 38) uses `COALESCE(t.isArchived, 0) = 0`.
- ✅ `startTopicObservation(archived: false)` filter
  (`MainWindow.swift:357`) uses `.filter(sql: "COALESCE(isArchived, 0) = 0")`.
- ✅ `fetchAllArchivedWithCounts` (line 66) uses strict `t.isArchived = 1`.
- ❌ **`fetchAllActive()` (line 151-158) does NOT use COALESCE** — see M2.
  This is a real defect because the method is called from
  `MainWindow.rewireForGateway()` (line 417) and `TopicServer.swift:132`.

### 4. Error handling — well separated

- `sidebarErrorTitle` / `sidebarErrorMessage` / `showSidebarError` are
  deliberately separate from `showDeleteAlert` / `deleteErrorMsg`. ✅
- The two alerts are on the same view tree, but SwiftUI handles
  simultaneous `@State` triggers by serialising on the next render
  cycle; no collision in practice.
- `showResetAlert` + `showResetErrorAlert` are also separate (3 alerts
  in total — but only one can be visible at a time because they bind to
  different `@State` booleans).
- `restoreTopic` errors → `Restore Error`. ✅
- `archiveTopic` errors → `Archive Error`. ✅

**Minor:** the title `"Archive Error"` and `"Restore Error"` are
hardcoded strings; if Adam later wants localization, these would need
`LocalizedStringKey`. v1 is fine.

### 5. Context menu — Mutually exclusive, correct position, hidden in archive view

`SessionRow.swift:202-216`:

```swift
// Archive / Restore (mutually exclusive — parent wires one or the other)
if onArchive != nil {
    Button { onArchive?() } label: {
        Label("Archive", systemImage: "archivebox")
    }
} else if onRestore != nil {
    Button { onRestore?() } label: {
        Label("Restore", systemImage: "tray.and.arrow.up")
    }
}
```

✅ Mutually exclusive via `if / else if`.
✅ `MainWindow.swift:551-552` wires based on `showArchived`:
  - `onArchive: showArchived ? nil : { archiveTopic(topic.id) }`
  - `onRestore: showArchived ? { restoreTopic(topic.id) } : nil`
✅ Position: after Mark-as-Unread/Read, before the `Divider`.
✅ Reset Session & Save Topic Summary are hidden when `isArchived == true`.
✅ Mark-as-Unread/Read still appears in archived view — see N5.

**Caveat:** `SessionRow.isArchived` parameter being passed equal to
`showArchived` from the parent is correct, but it means an *individual*
row's `isArchived` flag is not really an "is this row archived" semantic
— it's an "are we showing the archive view" semantic. Future refactor
risk if someone reuses SessionRow in a context where rows from both
views are mixed. For v1 this is fine because the sidebar always shows
one view at a time.

### 6. Edge cases

| Case | Behaviour | Verdict |
|---|---|---|
| Archive the currently selected topic | `archiveTopic` calls `removeTopic(id:)` → `selectedTopicId = topics.first?.id` | ✅ Matches R1 mitigation, mirrors delete path |
| Archive the last topic | `removeTopic(id:)` sets `selectedTopicId` to `nil` (no topics left) | ✅ Detail pane renders empty state |
| Archive from the Active view (you remain on Active) | Topic disappears from the Active list via ValueObservation | ✅ |
| Restore while viewing Active | Restored topic *re-appears* in the Active list (it was there before being archived too, technically). Sidebar shows it. | ✅ No selection change (spec §"Open Items" documents) |
| Restore in the Archived view | Topic disappears from Archived list because the Archived view filter (`isArchived = 1`) no longer matches. Sidebar goes empty. | ✅ |
| Toggle Archived → Active, then back | Observer swapped each time; only one cancellable live | ✅ |
| Delete key in archived view | `.ignored` (no-op) | ✅ |
| New Topic while viewing Archived | `requestNewTopic` switches `showArchived = false` and starts the Active observer | ⚠️ Selection not reset (see S2) |
| Empty archived view | Spec §V1 says "Minimal: blank list, no empty-state row." | ✅ Spec-compliant |

### 7. Tests — Solid, with one adapted-test rationale, and one missing case

**Spec test coverage is complete: 5/5.**

| Test | What it verifies | Quality |
|---|---|---|
| `testTopicArchive_SetsIsArchivedTrue` (line 276) | `archive()` toggles `isArchived` to `true` | ✅ Tight; uses `fetchById` for assertion |
| `testTopicRestore_SetsIsArchivedFalse` (line 292) | `restore()` toggles `isArchived` back to `false` | ✅ |
| `testFetchAllArchivedWithCounts_ReturnsOnlyArchived` (line 306) | Archived list excludes active topics; uses Set for membership assertions | ✅ |
| `testFetchAllActiveWithCounts_ExcludesArchived` (line 330) | Active list excludes archived; uses Set for membership assertions | ✅ |
| `testTopicsSchemaHasIsArchivedNotNull` (line 360) | **Adapted** — asserts the column EXISTS and is currently NULLABLE | ✅ Rationale is documented in test docstring & impl notes |

**Adapted-test decision (Spec item 24):** the impl correctly identified a
contradiction in the spec ("verify NOT NULL" vs "no schema migration").
The chosen path — assert current nullable state as a **tripwire** for
future migration — is the right engineering call. I agree with the
adaptation; the rationale is sound and self-documenting.

**Missing test (gap, not a blocker):** there is **no test
exercising the observer-level COALESCE guard** introduced in M2.
A test like:

```swift
func testStartTopicObservation_ShowsLegacyNullArchivedRows() throws {
    // Insert a topic with NULL isArchived (simulating pre-Migration005)
    // and assert ValueObservation on active includes it.
}
```

…would catch the M2 regression and prove the COALESCE fix works at the
observer layer (currently only proven at SQL layer in
`fetchAllActiveWithCounts_ExcludesArchived`).

**Recommendation (S, not blocker):** add the observer-level NULL-row
test in a follow-up. Won't block merge because:
- The observer-level filter is the *same* COALESCE pattern as the SQL
  one (already tested).
- Observers are notoriously hard to test without a real DB lifecycle.

### 8. Code style — Consistent with existing patterns

- `@State` declarations grouped logically with comments explaining
  semantics (✓ delete gate, ✓ FR-004, ✓ topic archiving).
- `private func` organization follows alphabetical/logical grouping.
- `alert(_:isPresented:)` modifier consistent with existing usage.
- `Task { @MainActor in ... }` blocks for archive/restore match the
  delete pattern (`MainWindow.swift:497-520`).
- `BeeChatLogger.log(...)` for error logging matches existing convention.
- `try topicRepo.X()` calling style matches repo throughout MainWindow.
- `SessionRow` parameter additions (`onArchive`, `onRestore`, `isArchived`)
  follow the existing param pattern (closure optionals default `nil`).

**No style regressions.** ✅

---

## Build/test verification (reviewer's own run)

```
swift build --target BeeChatPersistence   # clean ✓
swift build --target BeeChatApp          # clean (pre-existing warnings only) ✓
swift test --filter BeeChatPersistenceTests
  → 155 tests, 0 failures (matches impl notes)
```

---

## Summary

**Must-fix (2):**
1. **M2** — Apply the `COALESCE` guard to `fetchAllActive()` for consistency with the spec's NULL-safety fix. Touches `TopicRepository.swift:151-158`.
2. **S2** — Reset orphan selection when `requestNewTopic()` flips from Archived → Active. Touches `MainWindow.swift:445-451`.

**Should-fix (1):**
3. **S1** — Observer-startup failure should at least `BeeChatLogger.log` more verbosely and ideally surface UI feedback (decide in next iteration).

**Nits (4):** N1 weak-capture semantics, N3 unused initial values, N4 documented intentional non-restoration of selection, N5 consider hiding Mark-as-Unread in archived view.

**Tests:** 5/5 present, 4 exact-spec, 1 adapted (rationale good). Recommend follow-up observer-level COALESCE test (not blocking).

**Verdict:** Ship after applying M2 and S2. The two fixes are surgical and
add ~6 lines of code total.
