# Topic Delete Safety — Spec

**Date:** 2026-04-27
**Author:** Bee
**Status:** DRAFT — awaiting Kieran review

---

## Problem

On 2026-04-27, the "OpenClaw/Platform" topic disappeared from BeeChat. Deep investigation found:

### What happened to the Platform topic

1. The topic row was hard-deleted from the `topics` table (no `isArchived` flag set)
2. Only 1 orphan message remains in `messages` table (sessionId `02181BD9-D9E4-411C-852F-847DA4078328`) — the initial `CONTEXT_LOADED` from April 23
3. **All user messages from April 26 are GONE** — Adam was using the Platform topic yesterday but those messages are completely absent from the DB
4. The gateway session `agent:main:02181bd9-d9e4-411c-852f-847da4078328` still exists
5. The `topic_session_bridge` table has **no entry** for this topic — meaning `deleteCascading()` would have skipped message deletion (sessionKey lookup returns nil)
6. Yet messages ARE missing — only 1 remains out of what should be dozens
7. The `isArchived` column exists in the schema but is unused

### Root cause analysis

The delete was triggered through one of THREE possible paths (all unconfirmed, no confirmation dialog):

1. **Trash icon in toolbar** — `MainWindow.swift` line 101: a trash button that calls `deleteTopic()` directly with no confirmation
2. **Keyboard Delete key** — `MainWindow.swift` line 121: `.onKeyPress(.delete)` fires `deleteTopic()` with NO confirmation
3. **Right-click context menu** — `MainWindow.swift` line 54: "Delete Topic" calls `deleteTopic()` with NO confirmation

All three paths call `deleteCascading()` which hard-deletes the topic row. However, because the bridge table had no entry for this topic, `deleteCascading()` would NOT have deleted the messages. This means either:
- The topic was deleted through a different code path, OR
- The topic never had its messages properly stored (the 1 remaining `CONTEXT_LOADED` message was the only one that got saved), OR
- A database migration or app restart affected the data

**The missing messages from April 26 are the biggest concern** — they should exist in the DB but don't.

### Related discovery: Context bloat

- **General topic**: 113 messages across 5 days, but only 22% context used (44k/202k tokens) with a fresh gateway session today
- **Beechat topic**: 32 messages, but 48% context used (97k/202k) — also a fresh session today
- The massive bootstrap context (MEMORY.md 24k chars truncated, plus AGENTS.md, SOUL.md, etc.) fills ~40-50% of context on day one of any session
- This means sessions hit 50% almost immediately, which will trigger the red-dot reset indicator constantly

---

## Scope

Two features:

1. **Delete Confirmation** — require explicit user confirmation before any topic deletion
2. **Soft Delete + Archive Recovery** — topics are archived (not destroyed), with an "Archived Topics" recovery UI

Both features are additive — no breaking changes to existing behaviour beyond the confirmation gate.

---

## Feature 1: Delete Confirmation Dialog

### Behaviour

- When user clicks "Delete Topic" in context menu, show a native SwiftUI alert:
  - Title: "Delete [topic name]?"
  - Message: "This topic has [N] messages. It will be moved to Archive where you can recover it."
  - Buttons: "Cancel" (default, `.cancel`) | "Archive" (`.destructive`)
- The existing `showDeleteAlert` state variable in `MainWindow.swift` is repurposed for this.
- **No change** to the underlying delete logic in this feature — the alert is purely a UX gate.

### Files Changed

| File | Change |
|------|--------|
| `Sources/App/UI/MainWindow.swift` | Add confirmation alert before `deleteTopic()`. Repurpose `showDeleteAlert`/`deleteErrorMsg` or add new state. Store pending-delete topic ID. |

### Acceptance Criteria

- [ ] Right-click → "Delete Topic" shows confirmation alert
- [ ] "Cancel" dismisses alert, no action taken
- [ ] "Archive" proceeds with delete (which in Feature 2 becomes archive instead)
- [ ] Topic name and message count shown in alert
- [ ] No change to delete behaviour if confirmation is confirmed (Feature 2 changes the actual delete)

---

## Feature 2: Soft Delete + Archive Recovery

### Behaviour

**Archiving (replaces hard delete):**

- `deleteCascading()` is replaced by `archiveTopic()`:
  - Sets `isArchived = true` on the topic row
  - Sets `updatedAt = now`
  - Messages, bridge entries, and delivery ledger entries are **preserved**
  - The topic disappears from the main sidebar (already filtered by `isArchived == false`)

**Recovery UI — "Archived Topics" section:**

- A new button at the bottom of the sidebar: "📁 Archived Topics" (shows count badge if > 0)
- Clicking it opens a sheet/popover listing archived topics
- Each archived topic row shows:
  - Topic name
  - Message count
  - Date archived
  - Two actions: "Restore" | "Delete Permanently"
- "Restore" sets `isArchived = false` → topic reappears in sidebar
- "Delete Permanently" shows a SECOND confirmation alert:
  - Title: "Permanently Delete [topic name]?"
  - Message: "This cannot be undone. [N] messages will be permanently deleted."
  - Buttons: "Cancel" | "Delete Forever"
  - On confirm: calls the original `deleteCascading()` — hard delete

**Session reset flow update:**

- The 50% red dot → `triggerSessionReset()` flow is **unchanged** — it resets the gateway session context, not the topic

### Files Changed

| File | Change |
|------|--------|
| `Sources/BeeChatPersistence/Repositories/TopicRepository.swift` | Add `archiveTopic(id:)`, `fetchArchived()`, `restoreTopic(id:)`. Keep `deleteCascading()` for permanent delete only. |
| `Sources/App/UI/MainWindow.swift` | Replace `deleteTopic()` call with `archiveTopic()`. Add archived topics button + sheet. Add permanent-delete flow with double confirmation. |
| `Sources/App/UI/ViewModels/MessageViewModel.swift` | Add `archivedTopics` array, `fetchArchived()`, `restoreTopic()`, `permanentlyDeleteTopic()`. Remove topic from `topics` list on archive (already handled by filter). |
| `Sources/App/UI/Components/SessionRow.swift` | No changes needed (already filters `isArchived == false` via `fetchAllActive`) |

### Acceptance Criteria

- [ ] Right-click → "Delete Topic" → Confirm → topic archived (not hard-deleted)
- [ ] Archived topics disappear from main sidebar immediately
- [ ] "Archived Topics" button appears in sidebar when archived count > 0
- [ ] Archived topics sheet lists all archived topics with name, message count, date
- [ ] "Restore" on archived topic moves it back to main sidebar
- [ ] "Delete Permanently" requires second confirmation, then hard-deletes
- [ ] Hard delete removes topic row, messages, bridge entries, delivery ledger
- [ ] Orphan data from pre-feature deletions (like `02181BD9`) is NOT affected
- [ ] Session reset (50% red dot) still works independently of archive/delete

---

## Data Recovery: Orphaned Topic 02181BD9

The deleted "OpenClaw/Platform" topic can be **partially recovered** from the database:

- 1 message remains in `messages` table (sessionId `02181BD9-D9E4-411C-852F-847DA4078328`)
- The gateway session `agent:main:02181bd9-d9e4-411c-852f-847da4078328` still exists
- The topic row and bridge entry are gone — would need manual re-insertion

Recovery SQL (run after Feature 2 is deployed):
```sql
INSERT INTO topics (id, name, sessionKey, messageCount, isArchived, createdAt, updatedAt)
VALUES ('02181BD9-D9E4-411C-852F-847DA4078328', 'OpenClaw/Platform', '02181BD9-D9E4-411C-852F-847DA4078328', 1, 1, '2026-04-23 17:51:52.953', datetime('now'));
```

This restores it as an archived topic with its 1 surviving message. The gateway session history is lost but the session itself remains active.

---

## Risks

| Risk | Mitigation |
|------|------------|
| Archive changes sidebar filtering | Already filtered by `isArchived == false` — no filter change needed |
| Permanent delete still destructive | Double confirmation gate + "cannot be undone" messaging |
| Orphan data from old deletes | Manual recovery SQL above; Feature 2 prevents future orphans |
| Migration needed? | No — `isArchived` column already exists with default `false` |
| **Keyboard Delete is an accident vector** | `.onKeyPress(.delete)` fires delete with NO confirmation — must also gate this behind the confirmation dialog |
| **Toolbar trash icon is an accident vector** | Same issue — no confirmation before firing deleteTopic() |
| **Context bloat means 50% threshold hits too early** | Separate investigation needed — bootstrap context fills ~40-50% on fresh sessions |
| **Missing April 26 messages unexplained** | Bridge table had no entry, so deleteCascading wouldn't have removed them. Possible data loss from earlier bug or incomplete sync |

---

## Implementation Order

1. **URGENT: Gate ALL delete paths behind confirmation** — `.onKeyPress(.delete)`, toolbar trash icon, AND context menu. All three must show the confirmation dialog. This prevents further accidents immediately.
2. Feature 2 (Soft Delete + Archive) — proper safety net
3. Manual recovery of 02181BD9 — after Feature 2 is in place
4. **Separate investigation: Context bloat** — why do fresh sessions start at 40-50%? Bootstrap context too large?
5. **Separate investigation: Missing April 26 messages** — why are messages from a day of usage absent from the DB?
6. **Separate investigation: BeeChat responsiveness** — why are messages in the General topic taking 15+ minutes to get a response? Subagent chains blocking the main session?