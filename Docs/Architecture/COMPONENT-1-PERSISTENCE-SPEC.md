# BeeChatPersistence — Component 1 Specification

**Date:** 2026-04-17  
**Phase:** Build Phase 1  
**Predecessor:** Phase 0 Research (complete)  
**Exit Criteria:** Can create/open DB, migrate cleanly, insert/fetch sessions and messages, unit tests pass

---

## Overview

BeeChatPersistence is a Swift package providing the local SQLite persistence layer for BeeChat v5. It uses GRDB for database access, schema migration, and observation.

**Critical design rule:** The local DB is a **cache + UX accelerator**, NOT the authoritative source of session truth. The gateway owns session state. Local DB speeds up UI rendering, enables offline viewing, and provides search.

---

## Architecture

```
BeeChatPersistence (Swift Package)
├── Sources/
│   └── BeeChatPersistence/
│       ├── Database/
│       │   ├── DatabaseManager.swift      — DB open, WAL, migrations
│       │   └── Migrations/
│       │       ├── Migration001_CreateSessions.swift
│       │       └── Migration002_CreateMessages.swift
│       ├── Models/
│       │   ├── Session.swift              — Session record
│       │   ├── Message.swift              — Message record
│       │   ├── MessageBlock.swift         — Content blocks
│       │   └── Attachment.swift            — File attachments
│       ├── Repositories/
│       │   ├── SessionRepository.swift    — CRUD for sessions
│       │   └── MessageRepository.swift    — CRUD for messages
│       └── Protocols/
│           ├── MessageStore.swift          — Public protocol
│           └── GatewayEventConsumer.swift  — Gateway → DB sync interface
├── Tests/
│   └── BeeChatPersistenceTests/
│       ├── DatabaseManagerTests.swift
│       ├── SessionRepositoryTests.swift
│       └── MessageRepositoryTests.swift
└── Package.swift
```

---

## Database Schema (Migration 001 + 002)

### Table: `sessions`
| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PRIMARY KEY | OpenClaw session key (e.g. `agent:main:telegram:group:-1001234567890:topic:42`) |
| agentId | TEXT NOT NULL | Parsed from session key |
| channel | TEXT | Parsed from session key |
| title | TEXT | Display title from gateway |
| lastMessageAt | DATETIME | For sorting |
| unreadCount | INTEGER DEFAULT 0 | Local tracking |
| isPinned | BOOLEAN DEFAULT 0 | Local UI state |
| updatedAt | DATETIME NOT NULL | Last sync from gateway |
| createdAt | DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP |

### Table: `messages`
| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PRIMARY KEY | Gateway message ID |
| sessionId | TEXT NOT NULL | FK to sessions.id |
| role | TEXT NOT NULL | `user`, `assistant`, `system` |
| content | TEXT | Message text content |
| senderName | TEXT | Display name |
| senderId | TEXT | Sender identifier |
| timestamp | DATETIME NOT NULL | Message timestamp from gateway |
| editedAt | DATETIME | If message was edited |
| isRead | BOOLEAN DEFAULT 0 | Local tracking |
| metadata | TEXT | JSON blob for extensibility |
| createdAt | DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP |

### Table: `attachments`
| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PRIMARY KEY | |
| messageId | TEXT NOT NULL | FK to messages.id |
| type | TEXT NOT NULL | `image`, `file`, `audio`, `video` |
| url | TEXT | Remote URL |
| localPath | TEXT | Local cache path |
| mimeType | TEXT | |
| fileName | TEXT | |
| fileSize | INTEGER | |
| createdAt | DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP |

### Indexes
- `idx_messages_session_timestamp` ON messages(sessionId, timestamp)
- `idx_messages_session_id` ON messages(sessionId, id)
- `idx_sessions_updated` ON sessions(updatedAt)

---

## Protocol Definitions

### `MessageStore` (Public Interface)

```swift
public protocol MessageStore {
    // Session operations
    func saveSession(_ session: Session) throws
    func fetchSessions(limit: Int, offset: Int) throws -> [Session]
    func fetchSession(id: String) throws -> Session?
    func deleteSession(id: String) throws
    func updateUnreadCount(sessionId: String, count: Int) throws
    
    // Message operations
    func saveMessage(_ message: Message) throws
    func fetchMessages(sessionId: String, limit: Int, before: Date?) throws -> [Message]
    func fetchMessage(id: String) throws -> Message?
    func deleteMessage(id: String) throws
    func markAsRead(messageIds: [String]) throws
    
    // Attachment operations
    func saveAttachment(_ attachment: Attachment) throws
    func fetchAttachments(messageId: String) throws -> [Attachment]
    
    // Bulk operations
    func upsertSessions(_ sessions: [Session]) throws
    func upsertMessages(_ messages: [Message]) throws
    
    // Database lifecycle
    func openDatabase(at path: String) throws
    func closeDatabase()
}
```

### `GatewayEventConsumer` (Gateway → DB sync interface)

```swift
public protocol GatewayEventConsumer {
    func handleSessionList(_ sessions: [Session]) throws
    func handleNewMessage(_ message: Message) throws
    func handleMessageUpdate(_ message: Message) throws
    func handleSessionUpdate(_ session: Session) throws
}
```

---

## Key Design Decisions

1. **GRDB** — Chosen over SQLite.swift and Core Data (see research report)
2. **WAL mode** — Enable WAL journal mode for concurrent reads + writes
3. **Upsert-first** — Gateway events may arrive out of order; use INSERT OR REPLACE / ON CONFLICT
4. **No foreign key enforcement** — Gateway is source of truth; FK constraints would break during partial syncs
5. **JSON metadata column** — Extensible without migrations for minor gateway protocol additions
6. **Pagination** — All fetch methods support limit/offset for lazy loading
7. **Thread safety** — GRDB serial queue for writes; readers use snapshots

---

## Exit Criteria (MUST ALL PASS)

1. ✅ Database opens at arbitrary path with WAL mode enabled
2. ✅ Migrations run cleanly from empty state
3. ✅ Sessions: insert, fetch, fetch by ID, update unread, delete — all pass
4. ✅ Messages: insert, fetch by session (paginated), fetch by ID, mark read, delete — all pass
5. ✅ Attachments: insert, fetch by message — all pass
6. ✅ Upsert operations work correctly (no duplicates on re-insert)
7. ✅ All unit tests pass
8. ✅ Package builds with `swift build`
9. ✅ Tests run with `swift test`

---

## Build Instructions

Create a Swift Package Manager project:

```bash
mkdir -p BeeChat-v5/Sources/BeeChatPersistence
mkdir -p BeeChat-v5/Tests/BeeChatPersistenceTests
```

Package.swift should declare:
- Platform: macOS 14.0+
- Dependencies: GRDB.swift (~7.x)
- Products: one library `BeeChatPersistence`
- Targets: `BeeChatPersistence` (source), `BeeChatPersistenceTests` (test)

---

## Attribution

- GRDB.swift (`groue/GRDB.swift`) — MIT licence, SPM dependency
- Schema design informed by OpenClaw session-key patterns (see Shoulders Index)
- No ClawChat persistence code adapted (ClawChat uses electron-store, not SQLite)

---

*This spec is the contract for Component 1. The coder MUST deliver all exit criteria before Component 2 begins.*