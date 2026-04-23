# Topic Bloat Management Spec

**Date:** 2026-04-23
**Author:** Bee (Coordinator)
**Builder:** Q
**Reviewer:** Kieran

## Goal
Add visual health indicators to each topic in the sidebar so Adam can see at a glance which topics are getting large and may need attention. This addresses a daily pain point — topics get sluggish when they accumulate too many messages.

## Scope (3 items)

### 1. Message Count Column + Migration
**Current state:** The `topics` table has no message count. Computing it requires a JOIN query on every observation cycle.

**Required:**
- Add `messageCount: Int` column to `Topic` model (default 0)
- Add `Migration007_AddMessageCount` to DatabaseManager — `ALTER TABLE topics ADD COLUMN messageCount INTEGER DEFAULT 0`
- Backfill existing topics using a single canonical join path (sessionKey first, id as fallback with LIMIT 1 disambiguation)
- **⚠️ Do NOT add `messageCount` to `upsertColumns`.** The trigger is the sole writer of this column. Adding it to upsertColumns would reset the count to 0 on every upsert (the struct default), breaking the health indicator.

**Implementation:**
- In `Topic.swift`: add `public var messageCount: Int = 0` to the struct. **Do NOT add it to `upsertColumns`** — add a comment explaining why: `// messageCount excluded from upsertColumns — maintained by DB trigger, not Swift code`
- In `DatabaseManager.swift`: add `Migration007_AddMessageCount` after Migration006
- The backfill should use disambiguated SQL (see trigger section)

### 2. Auto-Increment Message Count on Write
**Current state:** Messages are inserted via `DatabaseManager.shared.write { db in var msg = ...; try msg.insert(db) }` in `MessageViewModel.sendMessage()` and via `SyncBridge` event handling.

**Required:**
- After every message insert, increment the topic's `messageCount`
- This avoids expensive COUNT(*) queries at read time

**Implementation:**
- Add a method to `TopicRepository`: `incrementMessageCount(topicId:)` that does `UPDATE topics SET messageCount = messageCount + 1 WHERE id = ?`
- Call it from `MessageViewModel.sendMessage()` after the message insert
- For SyncBridge messages: the `MessageObserver` or `SyncBridgeObserver` should call `incrementMessageCount` when new messages are persisted from gateway events
- Alternative (simpler): Add a GRDB trigger in the migration that auto-increments on INSERT. This is the most reliable approach — no code paths can miss it.

**Recommended approach:** Use GRDB database triggers in `Migration007`.

**⚠️ Kieran review correction:** Do NOT use OR condition directly — it can double-increment when both `sessionKey` and `id` match, or match the wrong row. Use `LIMIT 1` disambiguation:

```sql
CREATE TRIGGER trg_increment_message_count
AFTER INSERT ON messages
BEGIN
    UPDATE topics SET messageCount = messageCount + 1
    WHERE topics.id = (
        SELECT id FROM topics
        WHERE topics.sessionKey = NEW.sessionId OR topics.id = NEW.sessionId
        LIMIT 1
    );
END
```

Delete trigger:
```sql
CREATE TRIGGER trg_decrement_message_count
AFTER DELETE ON messages
BEGIN
    UPDATE topics SET messageCount = CASE WHEN messageCount > 0 THEN messageCount - 1 ELSE 0 END
    WHERE topics.id = (
        SELECT id FROM topics
        WHERE topics.sessionKey = OLD.sessionId OR topics.id = OLD.sessionId
        LIMIT 1
    );
END
```

Backfill uses same disambiguation:
```sql
UPDATE topics SET messageCount = COALESCE((
    SELECT COUNT(*) FROM messages
    WHERE messages.sessionId = topics.sessionKey OR messages.sessionId = topics.id
), 0)
```

### 3. Traffic Light Health Badge on SessionRow
**Current state:** SessionRow shows topic name and unread count. No health indicator.

**Required:**
- Show a small coloured dot next to each topic name indicating conversation health
- Thresholds:
  - 🟢 Green: `messageCount < 50` (healthy, lean)
  - 🟡 Amber: `messageCount 50–150` (getting large, may slow down)
  - 🔴 Red: `messageCount > 150` (bloated, consider reset/compaction)

**Implementation:**
- Add `messageCount` to `TopicViewModel` (from `Topic.messageCount`)
- In `SessionRow.swift`: add a small circle (8pt) before the topic name, colour based on threshold
- Use theme tokens for the colours: `.success` for green, `.warning` for amber, `.error` for red
- Add accessibility: `.accessibilityLabel("Topic health: \(healthDescription)")` and `.accessibilityValue("\(messageCount) messages")` 

**SessionRow layout change:**
```
Before: [Topic Name]              [unread]
After:  [🟢 Topic Name]           [unread]
```

The dot should be a small `Circle().frame(width: 8, height: 8)` with the appropriate colour.

## Acceptance Criteria
1. `messageCount` column exists in topics table with correct default
2. Existing topics are backfilled with correct message counts
3. Inserting a message auto-increments the topic's message count (via trigger)
4. Deleting a message auto-decrements the count
5. Each topic in the sidebar shows a green/amber/red health dot
6. VoiceOver reads the health status
7. Build succeeds clean

## Files to Modify
- `Sources/BeeChatPersistence/Models/Topic.swift` — add `messageCount` field
- `Sources/BeeChatPersistence/Database/DatabaseManager.swift` — add Migration007 with triggers
- `Sources/App/UI/ViewModels/TopicViewModel.swift` — add `messageCount` property
- `Sources/App/UI/Components/SessionRow.swift` — add health dot + accessibility

## Out of Scope
- Soft reset / memory retention (future phase)
- LCM compaction trigger from UI
- Topic detail view with exact token count
- Any changes to SyncBridge or message handling code (triggers handle it)

## Process
1. **Spec** → This document
2. **Review** → Kieran reviews for gaps, edge cases, correctness
3. **Build** → Q implements all 3 items
4. **Tech Validation** → Kieran reviews code
5. **UX Validation** → Bee launches app, verifies health dots appear
6. **Commit** → After all gates pass