# Topic Archiving Spec — Sanity Check Findings

**Date:** 2026-06-29  
**Reviewer:** Gav (subagent)  
**Spec:** topic-archiving.md

## Factual Accuracy Issues

- **Line references stale:** Spec claims `archive(topicId:)` at "line 78" — actual location is ~line 110 in TopicRepository.swift. Minor but indicates drift.
- **Spec correctly identifies existing assets:**
  - `Topic.isArchived: Bool = false` (default in struct + init) — verified.
  - `fetchAllActiveWithCounts` filters `WHERE t.isArchived = 0` — exact match.
  - `archive(topicId:)` exists and sets `isArchived = 1`.
  - `startLocalTopicObservation` already applies `isArchived == false` filter via GRDB ValueObservation.
- **Spec correctly flags non-existent items:** `restore()`, `fetchAllArchivedWithCounts()`, `showArchived` state, archived observer, and segmented toggle do not exist.

## Completeness Gaps (Existing Patterns Not Referenced)

- **Delete flow not mirrored:** Delete uses `requestDeleteTopic` → `showDeleteConfirmAlert` (FR-004 3-path confirm gate) + dedicated `deleteTopic(_:)` + `pendingDeleteTopicId`. Archive/restore reuses `showDeleteAlert`/`deleteErrorMsg` for errors — this is the only error surface mentioned. Spec understates collision risk with in-flight deletes.
- **No mention of TopicViewModel wrapper:** `SessionRow` binds `@Bindable var topic: TopicViewModel`, not raw `Topic`. Any archive UI change must consider whether `TopicViewModel` needs an `isArchived` projection or if the row simply receives a filtered list.
- **Sidebar location wrong in spec:** Spec says "BeeChatApp/Views/Sidebar/" — actual files are `Sources/App/UI/MainWindow.swift` + `Sources/App/UI/Components/SessionRow.swift`. No dedicated Sidebar/ directory.
- **Observer lifecycle:** Spec proposes `archivedTopicCancellable` but does not reference that `MainWindow` already has `localTopicCancellable` and a `stop()` pattern — easy to follow but unmentioned.

## Consistency Issues

- **Error surface reuse:** Spec reuses `deleteErrorMsg`/`showDeleteAlert` for archive failures. This matches the "reuse existing alert" intent but creates the exact `pendingDeleteTopicId` collision risk called out in R2.
- **Context menu closure pattern:** Proposed `onArchive: (() -> Void)?` / `onRestore` mirrors `onMarkUnread: ((Bool) -> Void)?` and `onReset` — consistent. Good.
- **Repository style:** Proposed `restore()` and `fetchAllArchivedWithCounts()` exactly mirror `archive()` + `fetchAllActiveWithCounts()` (same SQL shape, same `lastActivityAt DESC` ordering, same `COALESCE` messageCount subquery). Consistent.

## Missed Dependencies (Files/Views Needing Changes)

- **MessageViewModel.swift** — Spec lists it but omits that `updateTopics(from:)` and the public `topics` array must remain the single source of truth for both observers.
- **TopicViewModel.swift** (if it exists) — Not mentioned; verify whether archive state needs to flow through the view-model layer or if raw `Topic` list filtering is sufficient.
- **Tests/BeeChatPersistenceTests/BeeChatPersistenceTests.swift** — Spec lists 4 new tests; existing `isArchived` tests are at lines 159/246/256. New tests should sit alongside them.
- **No mention of potential MainWindow state bloat:** Adding `archivedTopicCancellable`, `showArchived` binding, and two new handler methods increases state surface in an already state-heavy view.

## Summary

Spec is factually sound on what exists vs. what must be added. Primary misses are:
1. Under-specified delete error handling reuse risk.
2. Incorrect sidebar folder path.
3. Omitted TopicViewModel layer consideration.
4. Stale line numbers.

No blocking contradictions; changes remain minimal and aligned with existing GRDB + closure patterns. Ready for Adam review once line numbers and sidebar path are corrected.