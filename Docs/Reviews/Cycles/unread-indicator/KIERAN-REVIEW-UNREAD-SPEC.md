# Kieran's Review: Sidebar Unread Indicator Spec

**Reviewer:** Kieran (independent)
**Date:** 2026-04-29
**Verdict:** ⚠️ NEEDS CHANGES

---

## Summary

The spec identifies a real problem (dead `unreadCount` code, no visual indicator) and proposes a reasonable UI solution. But the data-layer approach has a critical conflict with the Migration010 session-key alignment that's already in place. If shipped as-is, the trigger would silently fail for most messages on any app that's completed the session-key migration. There are also a few smaller issues worth fixing before implementation.

---

## 1. DB Trigger — ❌ CRITICAL ISSUE

### The trigger targets the wrong table

The spec proposes:

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

This follows the **old** `trg_increment_message_count` pattern from Migration007 — but that trigger was **explicitly dropped** in Migration010 and replaced with session-based triggers:

```sql
-- Migration010 drops these:
DROP TRIGGER IF EXISTS trg_increment_message_count
DROP TRIGGER IF EXISTS trg_decrement_message_count

-- And creates these instead:
CREATE TRIGGER trg_session_increment_message_count ...
  UPDATE sessions SET messageCount = messageCount + 1 WHERE id = NEW.sessionId;
```

**Why this matters:** After the session-key alignment migration runs, messages have `sessionId` set to gateway keys like `agent:main:UUID`. The `topics.sessionKey` column may or may not be populated with this gateway key (it depends on timing and the bridge table). The `sessions` table, however, uses the gateway key as its primary key — so the session-based trigger pattern `WHERE id = NEW.sessionId` works reliably.

The proposed unread trigger uses the fragile `OR` pattern (`topics.sessionKey = NEW.sessionId OR topics.id = NEW.sessionId`) that was already identified as problematic and removed.

### Fix: Target `sessions.unreadCount` instead

```sql
CREATE TRIGGER trg_session_increment_unread_count
AFTER INSERT ON messages
WHEN NEW.role = 'assistant'
BEGIN
    UPDATE sessions SET unreadCount = unreadCount + 1
    WHERE id = NEW.sessionId;
END
```

Then you need a corresponding clear trigger or an app-level clear. And the UI needs to read `unreadCount` from the sessions table (via the session-key mapping) rather than from `topics.unreadCount`.

**Alternatively:** If you want to keep reading from `topics.unreadCount`, you need a session→topic mapping trigger or an app-level bridge that syncs the unread count from sessions back to topics. This is more complex and fragile — I'd recommend reading from `sessions` directly.

### The `WHEN NEW.role = 'assistant'` guard is correct

Only assistant messages should increment unread. This is fine.

---

## 2. markAsRead Timing — ⚠️ NEEDS ADJUSTMENT

### Current proposal: call in `selectTopic(id:)`

Looking at the current `selectTopic`:

```swift
func selectTopic(id: String) {
    guard topics.contains(where: { $0.id == id }) else { return }
    stopUsagePolling(for: topics.first(where: { $0.id == selectedTopicId })?.sessionKey)
    selectedTopicId = id
    startObservationForSelectedTopic()
    startSessionUsageObservation()
}
```

**Race condition concern is minimal.** Since GRDB observations fire on `.mainActor`, and `markAsRead` would also run on the main actor (via `DatabaseManager.shared.writer.write`), the sequence is: select topic → mark as read → observation delivers updated topic list. The user would see the unread indicator disappear, which is the desired behaviour.

**However**, there's a real issue: `markAsRead` operates on `topicId` (a local UUID), but if the trigger targets `sessions.unreadCount`, you need to clear `sessions.unreadCount` using the **session key** (gateway format), not the topic ID. The `TopicRepository.markAsRead` method as spec'd would need to resolve the topic ID to a session key first.

**Recommended approach:**

```swift
func markAsRead(sessionKey: String) throws {
    try DatabaseManager.shared.writer.write { db in
        try db.execute(sql: "UPDATE sessions SET unreadCount = 0 WHERE id = ?", arguments: [sessionKey])
    }
}
```

Call this in `selectTopic` after resolving the session key (which the method already does via `topic.sessionKey` or `resolveSessionKey`).

### The "empty message list" race is not a real concern

The message list is populated by a separate GRDB observation. Clearing `unreadCount` doesn't affect the message observation. The user selects a topic → messages load via observation → unread clears. This is fine.

---

## 3. SessionRow Visual Changes — ✅ MOSTLY SAFE, TWO CAVEATS

### Conditional `.fontWeight(.semibold)`

This works with `themeManager.font(.body)`. SwiftUI's `.fontWeight()` is a view modifier that applies on top of the resolved font. No issue.

**Row height concern:** Changing font weight from regular to semibold does **not** change the line height in SwiftUI (both use the same typographic metrics for the same point size). The text render height is identical. No layout jump. ✅

### Blue dot placement

The spec says to add the blue dot between the `Spacer` and the existing unread count text. Looking at the current code, the unread count text is already there:

```swift
if topic.unreadCount > 0 {
    Text("\(topic.unreadCount)")
        .font(.caption)
        .foregroundColor(themeManager.color(.textSecondary))
}
```

The spec adds a blue dot **and** keeps the count text. This means when unread > 0, you'd see: `[dot 8px] [count number]`. That's fine visually.

**Caveat:** The existing `if topic.unreadCount > 0` block and the new blue dot should be inside the same conditional. The spec doesn't explicitly say this but it's implied. Make sure implementation merges them.

### Second caveat: data source shift

If unread counts move from `topics` to `sessions` (per point 1), `SessionRow` currently receives a `TopicViewModel`. It would need to also receive the `unreadCount` from the session usage map or a similar source. The `MessageViewModel.sessionUsageMap` already tracks per-session data — you could extend this pattern to include `unreadCount`.

---

## 4. Migration Safety — ⚠️ MINOR ISSUE

### The guard in the spec is wrong

The spec's "Risks" section says:

> Wrap in `if !db.tableExists("trg_increment_unread_count")` guard

**`db.tableExists()` checks for TABLES, not TRIGGERS.** This guard would always evaluate to `true` (since no table with that name exists) and would never prevent double-creation. In GRDB, this doesn't actually matter because **GRDB migrations run exactly once** by design (tracked in `grdb_migrations` table). You don't need a guard at all.

However, for defensive coding and consistency with Migration010's pattern, use:

```swift
try db.execute(sql: "DROP TRIGGER IF EXISTS trg_session_increment_unread_count")
try db.execute(sql: """
    CREATE TRIGGER trg_session_increment_unread_count
    AFTER INSERT ON messages
    WHEN NEW.role = 'assistant'
    BEGIN
        UPDATE sessions SET unreadCount = unreadCount + 1 WHERE id = NEW.sessionId;
    END
    """)
```

This follows the `DROP IF EXISTS` + `CREATE` pattern used in Migration010. ✅

### No risk of double-running

GRDB's `DatabaseMigrator` tracks completed migrations by name. As long as the migration has a unique name (e.g., `Migration011_AddUnreadTrigger`), it will run exactly once. ✅

---

## 5. Other Concerns

### 5a. Backfill existing unread counts

The trigger only fires on INSERT. Existing assistant messages that the user hasn't read will not be counted. You need a migration backfill step:

```sql
UPDATE sessions SET unreadCount = (
    SELECT COUNT(*) FROM messages
    WHERE messages.sessionId = sessions.id
    AND messages.role = 'assistant'
)
```

Without this, every topic starts at 0 unread even if there are unread assistant messages.

### 5b. Decrement on user message?

When the user sends a message, should the unread count for that topic be cleared? The spec doesn't address this. Currently the trigger only increments on assistant INSERT. A reasonable UX would be: user sends message → unread resets to 0 → assistant replies → unread goes to 1. Consider adding a trigger on `INSERT ON messages WHEN NEW.role = 'user'` that resets `unreadCount` to 0 for that session.

### 5c. The `selectTopic` method doesn't exist on the view model yet

Looking at `MessageViewModel.selectTopic(id:)`, it exists. But the spec says to add a `markAsRead` call there. The current method signature is fine — just add the call. ✅

### 5d. Decrement trigger for message deletion?

If messages are deleted (e.g., session reset), `unreadCount` would become stale. The existing `messageCount` has a decrement trigger. You need one for `unreadCount` too:

```sql
CREATE TRIGGER trg_session_decrement_unread_count
AFTER DELETE ON messages
WHEN OLD.role = 'assistant'
BEGIN
    UPDATE sessions SET unreadCount = CASE WHEN unreadCount > 0 THEN unreadCount - 1 ELSE 0 END
    WHERE id = OLD.sessionId;
END
```

### 5e. No crash risk from this change

The UI changes are additive (conditional views that already have a `> 0` guard). The trigger is database-only. No changes to MacTextView, Composer, or MainWindow. The MacTextView crash risk is not applicable here. ✅

---

## Verdict: NEEDS CHANGES

| # | Issue | Severity | Required Fix |
|---|-------|----------|-------------|
| 1 | Trigger targets `topics` instead of `sessions` | 🔴 Critical | Use session-based trigger pattern matching Migration010 |
| 2 | `markAsRead` uses topicId, needs sessionKey | 🟡 Medium | Change to operate on session key |
| 3 | No backfill for existing messages | 🟡 Medium | Add migration backfill step |
| 4 | No decrement trigger for deletions | 🟡 Medium | Add matching decrement trigger |
| 5 | Spec guard uses `tableExists` for trigger | 🟢 Low | Use `DROP TRIGGER IF EXISTS` pattern instead |
| 6 | Consider resetting unread on user message | 🟢 Low | Optional UX enhancement |

**The spec is close.** Fix the trigger to target `sessions` (consistent with Migration010), add the backfill and decrement trigger, and this is ready to build.