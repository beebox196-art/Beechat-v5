# DEBUG.md — Message Display Investigation (2026-04-22)

## Symptoms
1. User sends "hello world" → message does NOT appear in the message display area
2. AI responses flash up briefly (streaming works) then DISAPPEAR — they're not retained
3. Gateway connection is working, messages ARE being sent and responses ARE coming back

## Root Cause
**Schema mismatch between `Message` model and `messages` database table.**

The `messages` table had a legacy schema from an earlier version of the app:
- DB column `topicId` → Model expects `sessionId` (MISMATCH)
- DB `content NOT NULL` → Model has `content: String?` (NULL allowed)
- DB `senderId NOT NULL` → Model has `senderId: String?` (NULL allowed)
- DB `senderName NOT NULL` → Model has `senderName: String?` (NULL allowed)
- DB missing columns: `role`, `editedAt`, `metadata`, `createdAt`
- DB has unused columns: `messageId`, `isFromGateway`, `runId`, `state`

This meant:
1. `Message.insert(db)` failed — GRDB tried to insert into non-existent columns (`sessionId`, `role`, etc.) and didn't provide required columns (`content`, `senderId`, `senderName`, `topicId`, `state`)
2. `Message.filter(Column("sessionId") == sessionKey).fetchAll(db)` failed — `sessionId` column doesn't exist
3. Both failures were caught and printed as errors, but silently swallowed — messages never persisted, never displayed

## Evidence
- `sqlite3 beechat.sqlite ".schema messages"` showed legacy schema with `topicId` instead of `sessionId`
- `SELECT COUNT(*) FROM messages` returned 0 — no messages ever persisted
- Migration002 only created the table if it didn't exist (`!db.tableExists("messages")`) — so legacy table was never replaced

## Fixes Applied

### Fix 1: Migration006 — Recreate messages table
**File:** `Sources/BeeChatPersistence/Database/DatabaseManager.swift`

Added `Migration006_RecreateMessages` that drops the legacy `messages` table and recreates it with the correct schema matching the `Message` model. Safe because the table had 0 rows.

### Fix 2: MessageObserver ordering + scheduling
**File:** `Sources/BeeChatSyncBridge/Observation/MessageObserver.swift`

- Added `.order(Column("timestamp").asc).limit(500)` to the GRDB query (was missing ordering)
- Added `scheduling: .mainActor` to the observation (matches `startLocalMessageObservation` pattern)

## Build Verification
- `swift build --product BeeChatApp` — ✅ Build succeeds