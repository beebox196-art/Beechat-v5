# Spec: Sidebar Unread Message Indicator

**Date:** 2026-04-29
**Status:** DRAFT — Pending team review
**Scope:** SessionRow.swift + TopicRepository + SyncBridge/Reconciler
**Risk Level:** LOW (visual-only change + one DB trigger)

---

## Problem

When Bee replies to a message in a topic the user isn't currently viewing, there is no visual indicator in the sidebar. The user has to remember which topic they sent a message to and manually check.

## Discovery

**`unreadCount` on the Topic model is never incremented.** It defaults to 0 on creation and no code or DB trigger ever increases it. The existing `if topic.unreadCount > 0` check in `SessionRow.swift` (line 64) is dead code — it will never fire.

There IS a `messageCount` trigger that auto-increments when messages are inserted. We need an equivalent for `unreadCount`.

## Proposed Solution

Two parts: (1) make `unreadCount` actually work, (2) add a visual indicator.

### Part 1: Track unread count (data layer)

**Approach:** Add a database trigger that increments `topics.unreadCount` when an **assistant** message is inserted (i.e., a reply from Bee). User messages shouldn't increment it (the user knows they typed something).

```sql
CREATE TRIGGER trg_increment_unread_count
AFTER INSERT ON messages
WHEN NEW.role = 'assistant'
BEGIN
    UPDATE topics SET unreadCount = unreadCount + 1
    WHERE topics.id = (
        SELECT id FROM topics
        WHERE topics.sessionKey = NEW.sessionId OR topics.id = NEW.sessionId
        LIMIT 1
    );
END
```

This mirrors the existing `trg_increment_message_count` trigger pattern exactly.

**Clear on read:** When the user selects a topic, reset `unreadCount` to 0. Add a `markAsRead(topicId:)` method to `TopicRepository`:

```swift
func markAsRead(topicId: String) throws {
    try DatabaseManager.shared.writer.write { db in
        try db.execute(sql: "UPDATE topics SET unreadCount = 0 WHERE id = ?", arguments: [topicId])
    }
}
```

Call this in `MessageViewModel.selectTopic(id:)` after the topic is selected.

### Part 2: Visual indicator (UI layer)

**File:** `SessionRow.swift` only. No changes to MainWindow, MessageViewModel, or Composer.

**Changes:**

1. **Title font:** When `topic.unreadCount > 0`, make the title `.semibold` instead of regular weight
2. **Blue dot:** Add a small 8px Circle in the theme's accent colour (`themeManager.color(.accentPrimary)`) between the Spacer and the existing unread count text
3. **Accessibility:** Update the accessibility label to include unread count when > 0

**Layout (when unread):**
```
[health dot] [bold title] [Spacer] [blue dot 8px] [unread count] [red usage dot] [dormant bee]
```

**Layout (when no unread):**
```
[health dot] [regular title] [Spacer] [red usage dot] [dormant bee]
```

**Colour rule:** The unread dot MUST be blue/accent — NEVER red. Red is already used for the session-usage reset dot (≥50%).

### What is NOT changing

- No changes to `MacTextView.swift` or `Composer.swift`
- No changes to `MainWindow.swift` layout structure
- No changes to `SyncBridge.swift` or `EventRouter.swift`
- No new Swift packages or dependencies
- The existing health dot, red usage dot, dormant bee, and unread count text all remain unchanged

---

## Files Changed

| File | Change | Lines |
|------|--------|-------|
| `DatabaseManager.swift` | Add `trg_increment_unread_count` trigger in migration | ~10 |
| `TopicRepository.swift` | Add `markAsRead(topicId:)` method | ~5 |
| `MessageViewModel.swift` | Call `markAsRead` in `selectTopic(id:)` | ~2 |
| `SessionRow.swift` | Bold title + blue dot when unread | ~10 |

**Total: ~27 lines of code across 4 files.**

---

## Testing Checklist

1. ✅ App launches without crash
2. ✅ Send a message to Topic A → switch to Topic B → Topic A shows blue dot + bold title
3. ✅ Click Topic A → blue dot disappears, title returns to regular weight
4. ✅ Blue dot is visually distinct from the red session-usage dot
5. ✅ Topic with no unread messages looks identical to before
6. ✅ VoiceOver announces unread count when present

---

## Risks

| Risk | Mitigation |
|------|-----------|
| DB trigger migration fails | Wrap in `if !db.tableExists("trg_increment_unread_count")` guard — standard GRDB migration pattern |
| `markAsRead` called on non-existent topic | SQL UPDATE on missing ID is a no-op — safe |
| Blue dot confused with health dot | Health dot is 8px on the LEFT; blue dot is 8px on the RIGHT before the count — spatial separation |
| `unreadCount` overflows | Int column, realistically won't exceed 1000 — not a concern |

## Rollback

Single git revert. The trigger is idempotent (can be dropped). No data loss.