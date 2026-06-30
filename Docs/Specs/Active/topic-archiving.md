# Topic Archiving

**Priority:** Medium  
**Status:** ✅ IMPLEMENTED — built, reviewed (Kieran round 1 + round 2 fixes), Adam smoke-tested OK  
**Author:** Q (Builder), drafted by Bee (Coordinator)  
**Date:** 2026-06-30  
**Related:** BeeBoard pin archive (`0582aac`) — UX reference; BeeChat `Topic.isArchived` (existing column, Migration005)

## Problem

The BeeChat sidebar shows every active topic. Over time it accumulates dead sessions (one-off questions, completed tasks, resolved investigations) that Adam wants out of sight without deleting — same need that drove BeeBoard's pin archive.

## Scope

**In scope:**
- Right-click → "Archive" on any active sidebar topic
- Right-click → "Restore" on any archived topic (when archive view is showing)
- A segmented toggle at the top of the sidebar: `Active` / `Archived`
- Archived topics hidden from the default `Active` view; visible (with restore affordance) in `Archived` view
- Persisted across app restart (DB-backed)

**Out of scope:**
- No keyboard shortcut for archive/restore (mouse-only this round)
- No bulk archive ("Archive all read")
- No auto-archive rules ("archive after 30 days inactive")
- No undo toast (archive is one-way; restore is one click in the archive view)
- No archive search or sort — defaults to `lastActivityAt DESC`
- No unread count badge on the Archived segment
- No auto-restore on new messages (archived stays archived)
- No creation in Archived view (Archived is view-only; New Topic forces switch to Active)

## V1 Design Decisions (Adam, 2026-06-30)

| Question | Decision | Rationale |
|---|---|---|
| New message in archived topic | Stays archived, unread badge visible in Archived view | Minimal code — metadata sync already happens; no restore logic needed |
| Composer in Archived view | Read-only (disabled) | Archived topics are dormant; no send/compose actions |
| Reset/Save Summary in Archived view | Hidden (disabled) | Same rationale — archived = dormant |
| Delete key in Archived view | Disabled | No destructive actions in Archived view |
| New Topic while viewing Archived | Forces switch to Active view, then creates | Least surprising behaviour |
| Empty Archived view | Minimal: blank list, no empty-state row | KISS for v1 |
| Notification deep-link to archived topic | Minimal: no change — topic stays archived, user sees it in Archived view | No extra routing code |
| Unread count on Archived segment | No badge in v1 | Adds complexity; can revisit |

## Review Fixes (Kieran + Gav, 2026-06-30)

Three must-fix issues from adversarial review:

### Fix 1: Observer ownership — keep both in `MainWindow`

The draft spec incorrectly placed `showActiveTopics()` in `MessageViewModel`, but the active observer (`startLocalTopicObservation`) is owned by `MainWindow`. Both observers must live in `MainWindow` to avoid cross-object call issues.

**Implementation:** Add `@State var showArchived: Bool = false` and a single `topicCancellable` to `MainWindow`. The segmented toggle swaps between two observation queries by cancelling the previous observer and starting the new one. Both observers update `messageViewModel.topics` through the same `updateTopics(from:)` path.

```swift
// MainWindow.swift
@State private var showArchived: Bool = false
private var topicCancellable: DatabaseCancellable?

private func startTopicObservation(archived: Bool) {
    topicCancellable?.cancel()
    let observation = ValueObservation.tracking { db in
        try Topic
            .filter(Column("isArchived") == archived)
            .order(Column("lastActivityAt").desc)
            .limit(100)
            .fetchAll(db)
    }
    do {
        let writer = try DatabaseManager.shared.writer
        topicCancellable = observation.start(
            in: writer,
            scheduling: .mainActor,
            onError: { error in
                BeeChatLogger.log("[MainWindow] Topic observation error: \(error)")
            },
            onChange: { [weak self] topics in
                self?.messageViewModel.updateTopics(from: topics)
            }
        )
    } catch {
        BeeChatLogger.log("[MainWindow] Failed to start topic observation: \(error)")
    }
}
```

The `showArchived` toggle calls `startTopicObservation(archived: true)` or `startTopicObservation(archived: false)`. This replaces the existing `startLocalTopicObservation()` call and its `localTopicCancellable`. A single cancellable prevents dual-observer leaks.

### Fix 2: Error alert — use generic "Topic Error" instead of "Delete Error"

Reusing `deleteErrorMsg` / `showDeleteAlert` for archive failures shows "Delete Error" as the alert title, which is misleading for a reversible operation. Instead, add a generic sidebar error state:

```swift
// MainWindow.swift
@State private var sidebarErrorTitle: String = ""
@State private var sidebarErrorMessage: String = ""
@State private var showSidebarError: Bool = false

// Alert modifier
.alert(sidebarErrorTitle, isPresented: $showSidebarError) {
    Button("OK", role: .cancel) { }
} message: {
    Text(sidebarErrorMessage)
}
```

Archive/restore failures set `sidebarErrorTitle = "Archive Error"` or `"Restore Error"` and `sidebarErrorMessage` with the localized description. Delete continues using its own `showDeleteAlert` — no collision.

### Fix 3: Correct test references and add new tests

The cited tests at `BeeChatPersistenceTests.swift:159,246,256` cover `sessions.isArchived`, not `topics.isArchived`. New dedicated tests are required:

1. `testTopicArchive_SetsIsArchivedTrue` — create topic, `archive(topicId:)`, fetch, assert `isArchived == true`
2. `testTopicRestore_SetsIsArchivedFalse` — create archived topic, `restore(topicId:)`, fetch, assert `isArchived == false`
3. `testFetchAllArchivedWithCounts_ReturnsOnlyArchived` — 3 topics, archive 2, assert archived count == 2
4. `testFetchAllActiveWithCounts_ExcludesArchived` — same setup, assert active list excludes archived topics

Additionally, add a legacy schema safety test:
5. `testTopicsSchemaHasIsArchivedNotNull` — verify `topics.isArchived` column exists with NOT NULL constraint after migration

## Design

### Principle

Reuse what's already there. The `isArchived` boolean, the schema column, the index, the `archive(topicId:)` repository method, and the GRDB `ValueObservation` filter all already exist. The new work is:

1. Add `restore(topicId:)` repository method (mirror of `archive`).
2. Add `fetchAllArchivedWithCounts()` repository method.
3. Replace `startLocalTopicObservation()` with `startTopicObservation(archived:)` in `MainWindow`.
4. Add `@State showArchived` + segmented toggle in sidebar.
5. Wire `SessionRow` context menu: `Archive` in active view, `Restore` in archive view.
6. Disable composer, Reset, Save Summary, and Delete when `showArchived == true`.
7. Add generic sidebar error alert (separate from delete error alert).

No schema migration. No model field changes. No new view model.

### 1. Repository — `TopicRepository.restore(topicId:)` + `fetchAllArchivedWithCounts()`

```swift
// Sources/BeeChatPersistence/Repositories/TopicRepository.swift

/// Restore (un-archive) a topic by ID.
public func restore(topicId: String) throws {
    try dbManager.write { db in
        try db.execute(
            sql: "UPDATE topics SET isArchived = 0, updatedAt = ? WHERE id = ?",
            arguments: [Date(), topicId]
        )
    }
}

/// Fetch archived topics with computed message counts via SQL JOIN.
public func fetchAllArchivedWithCounts(limit: Int = 100) throws -> [Topic] {
    try dbManager.reader.read { db in
        try Topic.fetchAll(db, sql: """
            SELECT t.*,
                   COALESCE((
                       SELECT COUNT(*) FROM messages m
                       JOIN topic_session_bridge b ON b.openclawSessionKey = m.sessionId
                       WHERE b.topicId = t.id
                   ), 0) as messageCount
            FROM topics t
            WHERE t.isArchived = 1
            ORDER BY COALESCE(t.lastActivityAt, t.createdAt) DESC
            LIMIT \(limit)
        """)
    }
}
```

Both use the existing `idx_topics_isArchived` index.

### 2. Observer — `MainWindow.startTopicObservation(archived:)`

Replaces the existing `startLocalTopicObservation()` and its `localTopicCancellable`. See Fix 1 above for full code. Single cancellable, single method, `archived` parameter swaps the filter.

`stop()` cancels `topicCancellable` instead of `localTopicCancellable`.

### 3. Sidebar UI — `MainWindow` toggle + context menu + archived view restrictions

**3a. Segmented picker** at the top of the sidebar VStack, above `sidebarList`:

```swift
Picker("", selection: $showArchived) {
    Text("Active").tag(false)
    Text("Archived").tag(true)
}
.pickerStyle(.segmented)
.padding(.horizontal, themeManager.spacing(.md))
.padding(.vertical, themeManager.spacing(.xs))
.onChange(of: showArchived) { _, newValue in
    startTopicObservation(archived: newValue)
}
```

**3b. SessionRow context menu** — add `onArchive` / `onRestore` closures:

```swift
// SessionRow.swift — new init parameters
var onArchive: (() -> Void)? = nil
var onRestore: (() -> Void)? = nil

// contextMenuItems — after existing items, before the Divider
if onArchive != nil {
    Button {
        onArchive?()
    } label: {
        Label("Archive", systemImage: "archivebox")
    }
} else if onRestore != nil {
    Button {
        onRestore?()
    } label: {
        Label("Restore", systemImage: "tray.and.arrow.up")
    }
}
```

In `MainWindow.sidebarList`, pass based on `showArchived`:

```swift
SessionRow(
    topic: topic,
    // ...existing params...
    onArchive: showArchived ? nil : { archiveTopic(topic.id) },
    onRestore: showArchived ? { restoreTopic(topic.id) } : nil,
    // ...existing params...
)
```

**3c. Archived view restrictions** — when `showArchived == true`:

- Disable composer (hide or grey out the input field)
- Hide Reset Session and Save Topic Summary from context menu
- Disable Delete key handling for selected archived topic
- New Topic button forces `showArchived = false` before creating

```swift
// MainWindow.swift — New Topic handler
private func requestNewTopic() {
    if showArchived {
        showArchived = false
        startTopicObservation(archived: false)
    }
    // ...existing new topic creation logic...
}
```

**3d. Archive/restore handlers** — near `requestDeleteTopic` / `deleteTopic`:

```swift
private func archiveTopic(_ id: String) {
    Task { @MainActor in
        do {
            try TopicRepository().archive(topicId: id)
            if messageViewModel.selectedTopicId == id {
                messageViewModel.removeTopic(id: id)
            }
        } catch {
            sidebarErrorTitle = "Archive Error"
            sidebarErrorMessage = "Could not archive topic: \(error.localizedDescription)"
            showSidebarError = true
        }
    }
}

private func restoreTopic(_ id: String) {
    Task { @MainActor in
        do {
            try TopicRepository().restore(topicId: id)
            // ValueObservation refreshes sidebar automatically
        } catch {
            sidebarErrorTitle = "Restore Error"
            sidebarErrorMessage = "Could not restore topic: \(error.localizedDescription)"
            showSidebarError = true
        }
    }
}
```

### 4. NULL safety for `isArchived`

The schema defines `isArchived` with `.defaults(to: false)` but without `.notNull()`. To prevent NULL rows from disappearing from both views, update the filter to use `COALESCE`:

- Active filter: `WHERE COALESCE(t.isArchived, 0) = 0`
- Archived filter: `WHERE t.isArchived = 1`

Only the active view needs the `COALESCE` guard; archived view strictly matches `= 1`.

Update `TopicRepository.fetchAllActiveWithCounts()` to use `COALESCE(t.isArchived, 0) = 0` in its WHERE clause (currently uses `t.isArchived = 0`).

The new `startTopicObservation(archived: false)` observer must also use `COALESCE(isArchived, 0) == 0` in its GRDB filter.

### 5. Mobile sync note (documentation only)

`TopicServer` serves only active topics (`fetchAllActive`). Archived topics are excluded from iPhone sync in v1. Restore makes them syncable again. No code changes needed — this is the expected behaviour.

## Why this is minimal

| Concern | Existing asset | New work |
|---|---|---|
| Schema column `isArchived` | Migration005 | None |
| Index `idx_topics_isArchived` | Migration005 | None |
| `Topic.isArchived` model field | `Topic.swift` | None |
| `archive(topicId:)` repository method | `TopicRepository.swift` | None |
| `restore(topicId:)` repository method | — | 6 lines |
| `fetchAllArchivedWithCounts()` | — | 14 lines |
| `COALESCE` fix in `fetchAllActiveWithCounts()` | — | 1 line change |
| Observer (`startTopicObservation`) | Replaces `startLocalTopicObservation` | ~25 lines (net) |
| Sidebar segmented toggle | — | ~12 lines |
| `SessionRow` context menu additions | — | ~14 lines |
| `MainWindow` archive/restore handlers | — | ~24 lines |
| Sidebar error alert | — | ~8 lines |
| Archived view restrictions (composer, reset, delete) | — | ~10 lines |

Total new Swift code: ~110 lines. Zero schema migrations. Zero new components.

## UX notes

- **No undo toast.** Archive is reversible via the Archived toggle. KISS.
- **No confirm alert.** Archive ≠ delete. Delete keeps its FR-004 3-path confirm gate.
- **Selected topic fallback.** Archiving the selected topic calls `removeTopic(id:)`, which falls back to `topics.first?.id`. Same pattern as delete.
- **Archived view is read-only.** Composer, Reset, Save Summary, and Delete are disabled when `showArchived == true`. Only Restore is available.
- **New Topic in Archived view** forces a switch to Active view first.
- **Archived view ordering.** `lastActivityAt DESC` — same as active view.
- **No visual dimming in v1.** Archived topics render through the same `SessionRow`.

## Risks

- **R1 — Selection sync after archive.** If the user archives the currently selected topic, `messageViewModel.selectedTopicId` would point at a topic no longer in `topics[]`. Mitigation: `archiveTopic` calls `removeTopic(id:)` if the archived topic was selected, which falls back to `topics.first?.id`. Already exercised by delete path.
- **R2 — Dual observer eliminated.** Single `topicCancellable` prevents the race where two observers overwrite `messageViewModel.topics`. The `onChange(of: showArchived)` handler cancels the previous observer before starting the new one.
- **R3 — Archived topic receives new metadata.** `TopicRepository.syncMetadataFromSessions` updates `lastMessagePreview`, `unreadCount`, etc. regardless of archive state. The metadata updates persist in the DB; they become visible when the user switches to Archived view. No action needed in v1.
- **R4 — `rewireForGateway` only migrates active topics.** Archived topics with legacy bare UUID session keys would not be migrated. This is acceptable for v1 because Archived view is read-only — no message sending, no new session observation. If a restored topic has a stale key, `rewireForGateway` will migrate it on next active-topic pass.

## Testing

**New tests (in `BeeChatPersistenceTests`):**

1. `testTopicArchive_SetsIsArchivedTrue` — create topic, `archive(topicId:)`, fetch, assert `isArchived == true`
2. `testTopicRestore_SetsIsArchivedFalse` — create archived topic, `restore(topicId:)`, fetch, assert `isArchived == false`
3. `testFetchAllArchivedWithCounts_ReturnsOnlyArchived` — 3 topics, archive 2, assert archived count == 2
4. `testFetchAllActiveWithCounts_ExcludesArchived` — same setup, assert active list excludes archived topics
5. `testTopicsSchemaHasIsArchivedNotNull` — verify column exists with NOT NULL after migration

No UI tests in v1 — manual smoke test per BeeBoard precedent.

## Build / merge plan

1. Add `restore()` and `fetchAllArchivedWithCounts()` to `TopicRepository`
2. Fix `fetchAllActiveWithCounts()` WHERE clause with `COALESCE`
3. Replace `startLocalTopicObservation` with `startTopicObservation(archived:)` in `MainWindow`
4. Add `@State showArchived` + segmented toggle
5. Add `SessionRow` context menu items (`onArchive` / `onRestore`)
6. Add archive/restore handlers + sidebar error alert
7. Add archived-view restrictions (composer, reset, save summary, delete disabled)
8. Add 5 tests
9. Run full test suite (must stay at 150 + 5 = 155 passing, zero failures)
10. Smoke test: build → archive topic → switch toggle → restore → restart → confirm persistence
11. Structured code review (`scripts/review/code-review.sh`)
12. Address findings, re-review clean, commit on feature branch, PR to `develop`