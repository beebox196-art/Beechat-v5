# Topic Archiving Spec - Adversarial Review

**Date:** 2026-06-30  
**Reviewer:** Kieran  
**Spec:** `Docs/Specs/Active/topic-archiving.md`  
**Verdict:** Proceed only after tightening observer ownership, stale schema/test claims, and active-session edge cases.

## Findings

### H1 - The proposed observer split is internally inconsistent

The spec moves `showArchived`, `showArchivedTopics()`, `showActiveTopics()`, and `archivedTopicCancellable` into `MessageViewModel`, but the existing active topic observer lives in `MainWindow.startLocalTopicObservation()` and its cancellable is `MainWindow.localTopicCancellable`. The proposed `MessageViewModel.showActiveTopics()` calls `startLocalTopicObservation()`, but that method is not in `MessageViewModel`, so the spec as written will not compile.

Evidence:
- `MainWindow` owns `localTopicCancellable` and `startLocalTopicObservation()` (`Sources/App/UI/MainWindow.swift:14`, `Sources/App/UI/MainWindow.swift:411`).
- `MessageViewModel` currently owns message observation, not topic-list observation (`Sources/App/UI/ViewModels/MessageViewModel.swift:14`, `Sources/App/UI/ViewModels/MessageViewModel.swift:298`).

Recommendation: keep both active and archived topic observations in one owner. The smallest fix is likely to keep them in `MainWindow`: add `@State showArchived`, add `archivedTopicCancellable` or replace both with one `topicCancellable`, and route both observations through a single `startTopicObservation(isArchived:)`.

### H1 - Switching views can leave both topic observers running

The spec says both observers cancel before start, but the proposed code only cancels `archivedTopicCancellable` inside `startArchivedTopicObservation()`. It does not cancel `localTopicCancellable` because that cancellable lives in `MainWindow`. If implemented literally, switching to Archived can leave the active observer alive, and whichever observer fires last can overwrite `messageViewModel.topics`.

Impact: the sidebar can flicker back to active topics while the segmented toggle says Archived, or archived topics can reappear in the active view after a write.

Recommendation: use one cancellable for the topic list, or make the switch function cancel the previous owner explicitly before starting the new observer. Add a regression check: switch Active -> Archived -> Active and verify the list cannot be updated by the inactive observer after archiving/restoring a topic.

### H1 - Archiving the selected topic can keep the message pane attached to the archived session

The spec relies on `messageViewModel.removeTopic(id:)` for selected-topic fallback. That method changes `selectedTopicId` and starts observation for the new selected topic, but it only does so if the selected topic was removed from the in-memory list. Since `TopicRepository.archive(topicId:)` triggers `ValueObservation` asynchronously, there is a race between manual removal and the observer's own `updateTopics(from:)` path.

There is also a semantic issue: `updateTopics(from:)` always starts observation for the selected topic after rebuilding the topic list (`MessageViewModel.swift:64-86`). If the app is in Archived view, selecting/restoring archived topics will still attach the detail pane and composer to those sessions. The spec does not decide whether archived topics are read-only or sendable.

Recommendation: explicitly define archived-topic interaction:
- If archived topics are read-only, disable composer/send/reset/summary actions in Archived view.
- If they are fully active, document that Archived is only a sidebar filter and sending to an archived topic is allowed.
- On archive of the selected active topic, stop observing the old session before fallback if the archived topic should disappear from detail immediately.

### H2 - Archived topics can still receive new messages and unread state, but the UX is unspecified

`TopicRepository.syncMetadataFromSessions(_:)` updates `lastMessagePreview`, `lastActivityAt`, `unreadCount`, and `updatedAt` for a topic by bridge entry without filtering out archived topics (`TopicRepository.swift:82-102`). That means an archived topic can receive new activity and unread state while hidden from the Active view.

The spec says Archived view orders by `lastActivityAt DESC`, but it does not say what should happen when a hidden archived topic receives a new message:
- Should it automatically restore?
- Should it remain archived but show an unread badge in Archived?
- Should the Active/Archived segmented control show a count or indicator?
- Should notification/deep link selection be allowed to reveal an archived topic?

Recommendation: keep v1 simple, but write the rule down. Suggested v1 rule: archived topics stay archived on new messages, unread indicators still appear in Archived view, and selecting a notification for an archived topic either switches the sidebar to Archived or shows a clear "topic archived" affordance.

### H2 - Mobile/topic sync behavior changes, but the spec treats this as local-only UI

`TopicServer` serves only `repository.fetchAllActive(limit: 50)` to iPhone sync (`TopicServer.swift:132`). It still serializes `isArchived` in the payload (`TopicServer.swift:142`, `TopicServer.swift:214`), but archived topics will never reach the payload because they are filtered out before encoding.

Impact: once a topic is archived on Mac, it disappears from mobile sync. That may be intended, but it is not stated. Restore should bring it back on the next topic sync, but there is no test or acceptance criterion for that.

Recommendation: add this to scope: "Archived Mac topics are not served to iPhone topic sync in v1; restore makes them syncable again." If that is not desired, `TopicServer` needs an endpoint/query option for archived topics.

### H2 - Existing test references are for `sessions.isArchived`, not `topics.isArchived`

The spec says existing coverage validates `Topic.isArchived` round-tripping at `BeeChatPersistenceTests.swift:159,246,256`. Those lines actually validate the `sessions` table and `Session.isArchived` from Migration010, not the `topics` table.

Evidence:
- Line 159 asserts `sessions` columns contain `isArchived`.
- Lines 246 and 256 construct and assert a `Session(isArchived: true)`.

Recommendation: remove the claim that existing tests already cover topic archive round-tripping. Add explicit tests for:
- `topics` schema contains `isArchived`.
- `TopicRepository.archive(topicId:)` persists true.
- `restore(topicId:)` persists false.
- active and archived fetches exclude each other.

### H2 - Migration safety is mostly OK, but the spec glosses over legacy table behavior

The `topics.isArchived` column does exist in `Migration005_CreateTopics` (`DatabaseManager.swift:161-177`), and the index exists. However, the migration only creates the column when `topics` does not already exist. In the legacy-table branch, Migration005 currently only ensures `sessionKey`; it does not ensure `isArchived` or `idx_topics_isArchived` (`DatabaseManager.swift:178-184`).

Impact: if any real user database has a legacy `topics` table predating the `isArchived` field, the proposed "No schema migration" stance can fail at runtime with "no such column: isArchived". Existing app code already assumes the column, so this may be an already-resolved production invariant, but the spec should not assert migration safety without checking.

Recommendation: add a one-time migration audit/test that opens or simulates a legacy `topics` table without `isArchived`, runs migrations, and verifies the column and index exist. If that fails, add a new idempotent migration to backfill the column/index.

### H2 - `isArchived` is nullable in schema, but all filters use strict false/zero

`topics.isArchived` is defined with `.defaults(to: false)` but without `.notNull()` (`DatabaseManager.swift:171`). Existing active filters use `WHERE t.isArchived = 0` or `Column("isArchived") == false` (`TopicRepository.swift:46`, `TopicRepository.swift:117`, `MainWindow.swift:414`). Any `NULL` value will be excluded from both Active (`= 0`) and Archived (`= 1`) views.

Impact: a malformed/imported/legacy row with NULL `isArchived` can disappear from the sidebar entirely.

Recommendation: either treat NULL as active in queries with `COALESCE(isArchived, 0) = 0`, or add a migration/data repair enforcing non-null. BeeBoard's archive column is `notNull().defaults(to: false)`, but topics are not.

### H2 - `fetchAllArchivedWithCounts()` is specified but not used by the proposed archived observer

The spec asks to add `fetchAllArchivedWithCounts()`, then the proposed `startArchivedTopicObservation()` bypasses it and fetches `Topic` directly without computing `messageCount`. The active sidebar observation also fetches `Topic` directly, so this is consistent with current UI, but it contradicts the spec's claim that the new helper powers the archive view.

Impact: the archive view may show stale `messageCount` values because Migration010 replaced topic triggers with session-based triggers and `TopicRepository.fetchAllActiveWithCounts()` exists specifically to compute counts via SQL join.

Recommendation: choose one path:
- If sidebar health/message counts must be accurate, update both active and archived observers to use SQL that computes `messageCount`.
- If current stale count behavior is accepted, drop `fetchAllArchivedWithCounts()` from v1 and keep tests focused on archive/restore filtering.

### H3 - Reusing `deleteErrorMsg` is low risk but unnecessarily leaky

The spec calls the collision with `pendingDeleteTopicId` acceptable. I would not block on it, but the naming and alert title will be wrong: archive failures will show inside an alert titled "Delete Error" (`MainWindow.swift:18-23` and alert title near the same state). That makes support/debugging harder and makes a reversible archive action feel destructive.

Recommendation: add a generic sidebar operation error, e.g. `sidebarErrorTitle` / `sidebarErrorMessage`, or at least rename the alert to "Topic Error" before reuse.

### H3 - Context menu placement should account for destructive adjacency

`SessionRow.contextMenuItems` currently has Edit, Save Topic Summary, Reset Session, Mark Read/Unread, then a divider (`SessionRow.swift:124-170`). Adding Archive "after existing menu items, before Divider" puts it close to Reset and Mark Read/Unread. That is probably acceptable, but Archive should not look destructive like Delete, and Restore should not appear together with Save Summary/Reset if archived topics are meant to be read-only.

Recommendation: add Archive just above the divider with a neutral icon, and consider disabling Reset/Save Summary in Archived view unless the feature explicitly allows active operations on archived topics.

### H3 - Keyboard shortcut scope is clear for archive, but delete remains active in Archived view

The spec says no keyboard shortcut for archive/restore, which avoids accidental archive. However, existing Delete key handling deletes `messageViewModel.selectedTopicId` globally (`MainWindow.swift:234-247` for selection side effects, delete handler in the sidebar column). If the user is in Archived view and a topic is selected, Delete will still permanently delete it after the existing confirmation gate.

Recommendation: decide whether Delete should remain available in Archived view. If yes, smoke test it. If no, guard delete actions when `showArchived == true`.

### H3 - `rewireForGateway` only migrates active topics

`rewireForGateway` calls `topicRepo.fetchAllActive()` before migrating bare UUID session keys to gateway keys (`MainWindow.swift:371` in current file; method body shows active-only fetch). Archived topics with legacy bare UUID keys would be skipped forever until restored, and archived-topic message observation/sending may fail because `startObservationForSelectedTopic()` rejects bare UUID session keys (`MessageViewModel.swift:282-285`).

Recommendation: if Archived view allows opening archived topics, make the gateway-key migration fetch all topics or run by a repository method that is not archive-filtered.

### H3 - Creation while viewing Archived is unspecified

The spec places the segmented control above the list but does not define behavior for the New Topic button while Archived is selected. Existing creation selects the new topic immediately (`MainWindow.swift:462`), but if the active observer is not currently running, the new topic may not appear until the user switches back to Active.

Recommendation: new topic creation should either force the filter back to Active or leave Archived selected and avoid selecting an invisible topic. Force-to-Active is the least surprising.

## Data Integrity Assessment

Archive and restore themselves are single-row `UPDATE` operations inside GRDB writes, so crash consistency is good: SQLite/WAL gives all-or-nothing behavior for the flag update. There is no message/session deletion and no bridge deletion in the archive path, so the data-loss risk is low.

The larger integrity risks are visibility bugs, not destructive writes:
- NULL or legacy missing `isArchived` can hide topics from both filters.
- Dual observers can overwrite the sidebar with the wrong filter.
- Archived topics can keep receiving metadata updates with no user-visible indicator.
- Active-only sync/migration paths may skip archived topics.

## UX Edge Cases To Decide Before Build

- New message arrives in archived topic: stays archived or auto-restores?
- Unread archived topic: should the Archived segment show a badge/count?
- Notification/deep link targets archived topic: switch to Archived or block?
- Composer in Archived view: enabled or read-only?
- Reset Session / Save Topic Summary in Archived view: enabled or hidden?
- Delete key in Archived view: allowed permanent delete or disabled?
- New Topic while viewing Archived: switch to Active or create invisibly?
- Empty Archived view: show an empty-state row or just blank list?

## Required Spec Corrections

1. Fix observer ownership: do not put `showActiveTopics()` in `MessageViewModel` if it calls `MainWindow.startLocalTopicObservation()`.
2. Replace the "both observers cancel" claim with a single-cancellable or explicitly cancelled implementation.
3. Correct the test coverage section: current cited tests cover `sessions.isArchived`, not `topics.isArchived`.
4. Add migration safety acceptance criteria for legacy `topics` tables and nullable `isArchived`.
5. State the mobile sync consequence of using `fetchAllActive()` in `TopicServer`.
6. Decide whether Archived view is read-only or fully interactive.

## Suggested Acceptance Criteria

- Active view shows only `COALESCE(topics.isArchived, 0) = 0`.
- Archived view shows only `topics.isArchived = 1`.
- Switching Active/Archived leaves exactly one topic observation running.
- Archiving the selected active topic removes it from Active and selects a visible active fallback.
- Restoring a topic removes it from Archived and makes it visible in Active.
- Archived topic with new inbound metadata remains findable and behaves according to the documented rule.
- Legacy schema test proves `topics.isArchived` and `idx_topics_isArchived` exist after migration.
- Tests cover archive, restore, active fetch exclusion, archived fetch inclusion, and nullable/legacy behavior if supported.

## Bottom Line

The core repository operation is safe and small. The spec is not yet safe to hand to Q verbatim because it mixes topic observer ownership between `MainWindow` and `MessageViewModel`, overclaims existing topic archive test coverage, and leaves important behavior undefined for archived topics that are still live sessions. Tighten those points and this remains a modest, low-risk feature.
