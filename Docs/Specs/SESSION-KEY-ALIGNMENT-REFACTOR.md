# BeeChat v5 — Session Key Alignment Refactor Spec

**Status:** v5 FINAL — Ready for build  
**Date:** 2026-04-28  
**Author:** Bee  
**Reviewers:** Kieran (APPROVE), Neo (APPROVE)  
**Reference:** ClawChat (`ngmaloney/clawchat`), OpenClaw Gateway Docs

---

## Problem

BeeChat maintains its own "Topic" abstraction with local UUIDs, a bridge table, and a `sessionKeyMap` for reverse lookups. This creates:

1. **Key format mismatch bugs** — every RPC call needs translation between local UUID and gateway key
2. **Broken usage/red-dot flow** — `sessionUsageMap` is never wired to `sessionUsageCache`
3. **Duplicate sessions** — local `agent:main:<uuid>` and Telegram `agent:main:telegram:group:...:topic:1185` coexist for the same conversation
4. **Stale data** — no usage poll on topic selection or after auto-reset
5. **Unnecessary complexity** — 3 translation functions for a problem that shouldn't exist
6. **Gatekeeping overhead** — `BeeChatSessionFilter` blocks legitimate events from reaching the UI
7. **Missed opportunities** — gateway events provide real-time updates that BeeChat doesn't leverage

## Real Database Schema (verified)

| Table | Primary Key | Key columns |
|-------|-------------|-------------|
| `sessions` | `id` (TEXT) — stores gateway keys like `agent:main:...` | `agentId`, `channel`, `title`, `lastMessageAt`, `unreadCount`, `isPinned` |
| `topics` | `id` (TEXT) — stores local UUIDs | `name`, `sessionKey` (**self-referential UUID**), `lastMessagePreview`, `unreadCount`, `messageCount`, `isArchived` |
| `messages` | `id` (TEXT) | `sessionId` (stores local UUIDs from `topics.id`) |
| `delivery_ledger` | `id` (TEXT) | `sessionKey` (stores local UUIDs from `topics.id`) |
| `topic_session_bridge` | composite | `openclawSessionKey` (UUID), `topicId` (UUID) — **both self-referential** |

The only UUID→gateway key mapping exists in runtime memory (`sessionKeyMap`), rebuilt from `sessions.list` on every app launch. It is **never persisted to the database**.

---

## Proposed Session Model

Uses actual DB column names. Lean — only fields that are used today or directly enable the refactor's goals.

```swift
public struct Session: Identifiable, Codable, Sendable {
    public let id: String               // Gateway key — the primary identifier
    public var agentId: String
    public var title: String?           // From gateway (DB column: title)
    public var channel: String?
    public var totalTokens: Int?        // From gateway (replaces broken usage cache)
    public var lastMessageAt: Date?
    
    // Local metadata
    public var customName: String?      // User-assigned name (overrides title)
    public var isArchived: Bool
    public var isPinned: Bool
    public var unreadCount: Int
    public var lastMessagePreview: String?
    public var messageCount: Int        // Maintained by DB trigger
    
    public let createdAt: Date
    public var updatedAt: Date
    
    // Computed
    public var key: String { id }       // Alias for RPC clarity
    public var displayName: String {
        customName ?? title ?? Session.deriveName(from: id)
    }
    public var isSubagentSession: Bool { id.contains(":subagent:") }
    public var isCronSession: Bool { id.contains(":cron:") }
    public var isActive: Bool {
        (totalTokens ?? 0) > 0 || (lastMessageAt?.isWithin(hours: 24) ?? false)
    }
    
    private static func deriveName(from key: String) -> String {
        let parts = key.split(separator: ":")
        if let topicIdx = parts.firstIndex(of: "topic"), topicIdx + 1 < parts.count {
            return "Topic \(parts[topicIdx + 1])"
        }
        if let threadIdx = parts.firstIndex(of: "thread"), threadIdx + 1 < parts.count {
            return "Thread \(parts[threadIdx + 1])"
        }
        if parts.count >= 3 {
            switch parts[2] {
            case "main": return "Main"
            case "subagent": return parts.count > 3 ? String(parts[3]).prefix(8) + "…" : "Subagent"
            case "cron": return "Cron"
            case let name: return String(name).capitalized
            }
        }
        return key
    }
}
```

**Removed from earlier drafts (lean cuts):**
- `model` — never used in UI, add later when needed
- `isChannelSession` — not used by filter or UI, defensive code for nonexistent feature
- `label` — DB column is `title`, not `label`; using `title` directly

## Session Filtering

```swift
func sessionShouldAppearByDefault(_ session: Session) -> Bool {
    if session.isPinned { return true }
    if session.isArchived { return false }
    if session.isSubagentSession && !session.isActive { return false }
    return session.isActive  // implicitly excludes cron, stale sessions
}
```

- **Default:** Pinned + active sessions
- **Toggle:** "Show all sessions" reveals everything
- **Archived view:** Shows archived sessions separately

---

## Capabilities Unlocked

| Capability | Before | After |
|-----------|--------|------|
| Real-time session updates | `sessions.changed` filtered by gatekeeping | All events processed → sidebar auto-refreshes |
| Token-based usage indicator | Broken (`sessionUsageMap` never populated) | `totalTokens / contextWindow` → accurate % |
| Cross-session visibility | Only "BeeChat topics" (5 shown) | All active sessions visible with smart filtering |
| Session event-driven UI | Polling-based | `sessions.changed` → `fetchSessions()` with debounce |
| Simpler auto-reset | 3-step key translation in hot path | Gateway key → RPC directly |
| Clean message dedup | `isBeeChatSession` blocked events | All chat events processed |

---

## Implementation Plan

### Phase 1: Database Migration

Runs on first launch after update. The app boots normally, `SyncBridge.start()` calls `fetchSessions()` which builds `sessionKeyMap`. Then migration runs using that authoritative mapping.

**Step 1: Persist the gateway key mapping**

```swift
// sessionKeyMap already populated by fetchSessions() at normal boot
// Invert it for migration: local ID → gateway key
var topicToGatewayKey: [String: String] = [:]
for (gatewayKey, localId) in syncBridge.sessionKeyMap {
    topicToGatewayKey[localId] = gatewayKey
}

// Persist to temporary table for rollback capability
try db.create(table: "session_key_mapping") { t in
    t.column("localId", .text).primaryKey()
    t.column("gatewayKey", .text).notNull()
}
for (localId, gatewayKey) in topicToGatewayKey {
    try db.execute(sql: "INSERT INTO session_key_mapping VALUES (?, ?)",
                  arguments: [localId, gatewayKey])
}
```

**Step 2: Add new columns**

```sql
ALTER TABLE sessions ADD COLUMN customName TEXT;
ALTER TABLE sessions ADD COLUMN lastMessagePreview TEXT;
ALTER TABLE sessions ADD COLUMN messageCount INTEGER NOT NULL DEFAULT 0;
ALTER TABLE sessions ADD COLUMN totalTokens INTEGER;
ALTER TABLE sessions ADD COLUMN isArchived BOOLEAN NOT NULL DEFAULT 0;
```

**Step 3: Populate new columns from topics**

```swift
for session in allSessions {
    let localId = topicToGatewayKey.first(where: { $0.value == session.id })?.key
    guard let topicId = localId,
          let topic = topics.first(where: { $0.id == topicId }) else { continue }
    
    try db.execute(sql: """
        UPDATE sessions SET 
            customName = ?,
            lastMessagePreview = ?,
            messageCount = ?,
            isArchived = ?,
            unreadCount = ?
        WHERE id = ?
        """, arguments: [
            topic.name != session.title ? topic.name : nil,
            topic.lastMessagePreview,
            topic.messageCount,
            topic.isArchived,
            topic.unreadCount,
            session.id
        ])
}
```

**Step 4: Rewrite foreign keys + handle orphans**

```swift
// Rewrite known mappings
for (localId, gatewayKey) in topicToGatewayKey {
    try db.execute(sql: "UPDATE messages SET sessionId = ? WHERE sessionId = ?",
                  arguments: [gatewayKey, localId])
    try db.execute(sql: "UPDATE delivery_ledger SET sessionKey = ? WHERE sessionKey = ?",
                  arguments: [gatewayKey, localId])
}

// Handle orphaned messages (sessionId not in mapping, not already a gateway key)
let unmappedIds = try Set(String.fetchAll(db, sql: """
    SELECT DISTINCT sessionId FROM messages 
    WHERE sessionId NOT IN (SELECT localId FROM session_key_mapping)
    AND sessionId NOT IN (SELECT id FROM sessions)
    """))
for orphanId in unmappedIds {
    let syntheticKey = "orphan:\(orphanId)"
    // Check if there's a topic with this ID for better metadata
    let topicName = topics.first(where: { $0.id == orphanId })?.name ?? "Orphaned messages"
    try db.execute(sql: """
        INSERT OR IGNORE INTO sessions (id, agentId, title, customName, isArchived, createdAt, updatedAt)
        VALUES (?, 'main', ?, ?, 1, datetime('now'), datetime('now'))
        """, arguments: [syntheticKey, topicName, topicName])
    try db.execute(sql: "UPDATE messages SET sessionId = ? WHERE sessionId = ?",
                  arguments: [syntheticKey, orphanId])
    try db.execute(sql: "UPDATE delivery_ledger SET sessionKey = ? WHERE sessionKey = ?",
                  arguments: [syntheticKey, orphanId])
}
```

**Step 5: Replace triggers**

```sql
DROP TRIGGER IF EXISTS trg_increment_message_count;
DROP TRIGGER IF EXISTS trg_decrement_message_count;

CREATE TRIGGER trg_session_increment_message_count
AFTER INSERT ON messages
BEGIN
    UPDATE sessions SET messageCount = messageCount + 1 WHERE id = NEW.sessionId;
END;

CREATE TRIGGER trg_session_decrement_message_count
AFTER DELETE ON messages
BEGIN
    UPDATE sessions SET messageCount = messageCount - 1 WHERE id = OLD.sessionId;
END;
```

**Step 6: Keep old tables** — `topics`, `topic_session_bridge`, `session_key_mapping` preserved. Drop in Phase 5 after validation.

### Phase 2: SyncBridge Simplification

1. Remove `sessionKeyMap`, `beechatSessionKeys`, `gatewayKey(for:)`, `normalizeSessionKey()`, `stripPrefix()`
2. `fetchSessions()` — direct upsert from gateway with `sessionShouldAppearByDefault()` filtering
3. `sendMessage()`, `resetSession()`, `pollSessionUsage()`, `fetchHistory()` — use `session.id` (gateway key) directly
4. Remove `isBeeChatSession()` gatekeeping from `EventRouter` — ALL chat events processed
5. Update `BeeChatPersistenceStore` to work with new Session model

### Phase 3: Reconciler Simplification

1. Remove `sessionKeyMap` parameter from `reconcile()`
2. `delivery_ledger.sessionKey` now stores gateway keys (migrated in Step 4)
3. No key resolution needed

### Phase 4: UI Updates

1. `SessionRow` — uses `Session.id` as identifier, `Session.displayName` for label
2. Sidebar — smart filtering with "Show all" toggle
3. Usage/red-dot — `totalTokens / contextWindowSize` → usage percent
4. Real-time updates — `sessions.changed` → `fetchSessions()` with 1s debounce
5. Usage polling on session selection and after auto-reset
6. Rename `TopicViewModel` → `SessionViewModel`

### Phase 5: Validation & Cleanup

**3-day validation period** — old tables intact.

After validation:
```sql
DROP TABLE IF EXISTS topics;
DROP TABLE IF EXISTS topic_session_bridge;
DROP TABLE IF EXISTS session_key_mapping;
```

Remove dead code: `SessionKeyNormalizer`, `BeeChatSessionFilter`, `TopicRepository`, all key translation functions.

---

## Rollback Plan

| Stage | Rollback |
|-------|----------|
| After Phase 1 | Reverse `messages.sessionId` using `session_key_mapping` table |
| After Phase 2-4 | Revert code; old tables still readable |
| After Phase 5 | Restore from pre-migration SQLite backup (nuclear) |

---

## Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Gateway unreachable at migration | Medium | High | Defer migration; app runs in compatibility mode until gateway available |
| Migration loses data | Low | High | `session_key_mapping` + old tables preserved + pre-migration backup |
| Orphaned data | Low | Low | Synthetic sessions created, auto-archived |
| Sidebar shows too many sessions | Low | Low | Smart filtering; 174 → ~10 active sessions by default |

---

## Review History

| Version | Kieran | Neo | Changes |
|---------|--------|-----|---------|
| v1 | CONDITIONAL APPROVE (8 issues) | CONDITIONAL APPROVE (5 issues) | Initial spec |
| v2 | CONDITIONAL APPROVE (5 issues) | REJECT (4 critical) | Addressed v1 issues; broken migration SQL |
| v3 | APPROVE | CONDITIONAL APPROVE (3 fixes) | Swift-based migration, real column names |
| v4 | APPROVE | APPROVE | Neo's 3 fixes + lean cuts |
| **v5** | **APPROVE** | **APPROVE** | **Lean cuts applied, ready to build** |