# BeeChatSyncBridge — Component 3 Specification

**Date:** 2026-04-17  
**Phase:** Build Phase 3  
**Predecessors:** Component 1 (Persistence) ✅, Component 2 (Gateway) ✅  
**Exit Criteria:** Sessions list syncs from gateway, messages sync per session, reconnect reconciles without duplicates, UI can observe DB changes reactively

---

## Overview

BeeChatSyncBridge is the glue between BeeChatGateway (WebSocket transport) and BeeChatPersistence (local SQLite cache). It subscribes to gateway events, routes them to database writes, fetches initial state via RPC calls, and publishes DB changes to SwiftUI via GRDB ValueObservation.

**Critical design rules:**
1. **DB is source of UI truth.** SwiftUI observes the database, not the WebSocket.
2. **Gateway owns session state.** Local DB is a cache, always rebuildable from gateway.
3. **Deltas are ephemeral.** Only `final` state messages get persisted as durable rows.
4. **Upsert always.** Never blind-insert. Use stable remote IDs for deduplication.
5. **Reconnect = reconcile.** On reconnect, fetch recent history and upsert idempotently.

---

## Architecture

```
BeeChatSyncBridge (Swift Package)
├── Sources/
│   └── BeeChatSyncBridge/
│       ├── SyncBridge.swift              — Main actor: coordinates all sync logic
│       ├── EventRouter.swift             — Routes gateway events to handlers
│       ├── RPCClient.swift               — Typed wrapper around GatewayClient.call()
│       ├── Reconciler.swift              — Reconnect reconciliation logic
│       ├── Models/
│       │   ├── ChatEvent.swift           — chat event payload types (delta/final/error)
│       │   ├── SessionsChanged.swift     — sessions.changed event payload
│       │   ├── SessionInfo.swift         — Session info from sessions.list
│       │   ├── ChatMessage.swift         — Message from chat.history
│       │   └── DeliveryLedgerEntry.swift — Outbound message tracking
│       ├── Persistence/
│       │   ├── Migration003_DeliveryLedger.swift — New migration for delivery ledger
│       │   └── DeliveryLedgerRepository.swift     — CRUD for outbound tracking
│       ├── Observation/
│       │   ├── SessionObserver.swift      — GRDB ValueObservation for session list
│       │   └── MessageObserver.swift      — GRDB ValueObservation for messages
│       └── Protocols/
│           ├── SyncBridgeDelegate.swift   — Protocol for UI notification hooks
│           └── SyncBridgeConfiguration.swift — Config struct
├── Tests/
│   └── BeeChatSyncBridgeTests/
│       ├── SyncBridgeTests.swift
│       ├── EventRouterTests.swift
│       ├── ReconcilerTests.swift
│       ├── DeliveryLedgerTests.swift
│       └── ObservationTests.swift
└── Package.swift
```

---

## Gateway Event Types (Updated from Research)

The GatewayEvent enum in Component 2 needs updating to match the current OpenClaw protocol:

```swift
public enum GatewayEvent: String, Codable, Sendable {
    case chat                           // Real-time transcript streaming
    case sessionsChanged = "sessions.changed"  // Session list invalidation
    case sessionMessage = "session.message"     // Per-session transcript updates
    case sessionTool = "session.tool"           // Tool call/result updates
    case presence                       // User presence updates
    case tick                            // Keepalive/liveness
    case connectChallenge = "connect.challenge" // Handshake challenge
    case error                           // Error event
    
    // NOTE: state.snapshot and session.update do NOT exist in current protocol.
    // Initial state comes from hello-ok.snapshot.
    // Session invalidation comes from sessions.changed.
}
```

**This is a Component 2 change — update GatewayEvent.swift before building Component 3.**

---

## Event Handling Rules

### `chat` Event
The primary real-time transcript event. Payload contains a `state` field:

```swift
enum ChatEventState: String, Codable {
    case delta   // Streaming chunk — ephemeral, do NOT persist as message row
    case final   // Completed message — persist as durable row
    case error   // Generation failed — update delivery state
}

struct ChatEventPayload: Codable {
    let runId: String
    let sessionKey: String
    let seq: Int?
    let state: ChatEventState
    let message: ChatMessage?
    let errorMessage: String?
}
```

**Handling:**
- `delta`: Update in-memory streaming buffer only (NOT to DB). Emit to UI via delegate.
- `final`: Upsert message to DB. Clear streaming buffer for that runId.
- `error`: Mark delivery ledger entry as failed. Clear streaming buffer.

### `sessions.changed` Event
Invalidates the session list cache.

**Handling:**
- Call `sessions.list` RPC to refresh session list
- Upsert all returned sessions to DB
- Delete local sessions that no longer appear in the response

### `tick` Event
Keepalive. No DB write needed.

**Handling:**
- Update last-seen tick timestamp in memory
- If ticks stop arriving beyond `2 * tickIntervalMs`, trigger reconnect

### `session.message` Event
Per-session transcript update (for subscribed sessions).

**Handling:**
- Upsert message to DB by message ID
- This is an alternative to `chat` for subscribed session streams

### `session.tool` Event
Tool call/result updates for subscribed sessions.

**Handling:**
- Store as message metadata or skip for v1 (not required for minimal messenger)

---

## RPC Methods

### `sessions.list`
```swift
struct SessionsListParams: Codable {
    // No required params — returns all sessions for the authenticated operator
}

struct SessionsListResponse: Codable {
    let sessions: [SessionInfo]
}

struct SessionInfo: Codable {
    let key: String           // e.g. "agent:main:telegram:group:-1001234567890:topic:42"
    let label: String?       // Display name
    let channel: String?     // e.g. "telegram"
    let model: String?      // e.g. "ollama/glm-5.1:cloud"
    let totalTokens: Int?    // Token usage
    let lastMessageAt: String? // ISO 8601 timestamp
}
```

### `chat.history`
```swift
struct ChatHistoryParams: Codable {
    let sessionKey: String
    let limit: Int?          // Default 200
}

struct ChatHistoryResponse: Codable {
    let sessionKey: String
    let sessionId: String
    let messages: [ChatMessage]
}
```

### `chat.send`
```swift
struct ChatSendParams: Codable {
    let sessionKey: String
    let message: String
    let idempotencyKey: String  // REQUIRED for side-effecting methods
    let thinking: String?
    let attachments: [ChatAttachment]?
}

struct ChatSendAck: Codable {
    let runId: String
    let status: String
}
```

### `chat.abort`
```swift
struct ChatAbortParams: Codable {
    let sessionKey: String
}

struct ChatAbortResponse: Codable {
    let ok: Bool
    let aborted: Bool
    let runIds: [String]?
}
```

---

## SyncBridge Public API

```swift
public actor SyncBridge {
    // Configuration
    public struct Configuration: Sendable {
        public let gatewayClient: GatewayClient
        public let persistenceStore: BeeChatPersistenceStore
        public let historyFetchLimit: Int          // Default: 200
        public let reconnectDebounceSeconds: Double // Default: 1.0
        public let staleTickMultiplier: Double      // Default: 2.0
    }
    
    // Lifecycle
    public init(config: Configuration)
    public func start() async throws        // Connect + initial sync
    public func stop() async                 // Disconnect gracefully
    
    // Active operations
    public func fetchSessions() async throws -> [Session]
    public func fetchHistory(sessionKey: String, limit: Int?) async throws -> [Message]
    public func sendMessage(sessionKey: String, text: String) async throws -> String // returns runId
    public func abortGeneration(sessionKey: String) async throws
    
    // Observation — returns AsyncStreams for SwiftUI consumption
    public func sessionListStream() -> AsyncStream<[Session]>
    public func messageStream(sessionKey: String) -> AsyncStream<[Message]>
    public func connectionStateStream() -> AsyncStream<ConnectionState>
    
    // Streaming state for current generation
    public var currentStreamingContent: String { get }  // Ephemeral delta buffer
    public var currentStreamingSessionKey: String? { get }
}
```

---

## Reconnect Strategy

On reconnect, SyncBridge must:

1. Complete handshake (GatewayClient handles this)
2. Persist any new `deviceToken` from `hello-ok`
3. Refresh sessions via `sessions.list` → upsert all to DB
4. For active session, fetch `chat.history(limit: 200)` → upsert all messages
5. Reconcile pending outbound messages:
   - For each `pending` delivery ledger entry, check if message appears in history
   - If found: mark as `delivered`
   - If not found after timeout: mark as `failed`
6. Resume live event processing

### Seq tracking
- Keep `lastSeenEventSeq: Int?` in memory
- If incoming `seq <= lastSeenEventSeq`: ignore (duplicate/stale)
- If incoming `seq > lastSeenEventSeq + 1`: gap detected → trigger reconciliation for that session

---

## Delivery Ledger (New Migration)

### Migration003 — Add delivery_ledger table

| Column | Type | Notes |
|--------|------|-------|
| id | TEXT PRIMARY KEY | Local UUID |
| sessionKey | TEXT NOT NULL | Target session |
| idempotencyKey | TEXT NOT NULL UNIQUE | For chat.send dedup |
| content | TEXT NOT NULL | Message text |
| status | TEXT NOT NULL | `pending`, `sent`, `delivered`, `failed` |
| runId | TEXT | Populated after ack |
| createdAt | DATETIME NOT NULL | |
| updatedAt | DATETIME NOT NULL | |
| retryCount | INTEGER DEFAULT 0 | |

**Indexes:**
- `idx_delivery_ledger_status` ON delivery_ledger(status)
- `idx_delivery_ledger_session` ON delivery_ledger(sessionKey)

---

## ValueObservation Pattern

### SessionObserver
```swift
public struct SessionObserver {
    private let dbManager: DatabaseManager
    
    /// Returns an AsyncStream that emits the full session list whenever the sessions table changes
    public func observeSessions() -> AsyncStream<[Session]> {
        // Uses GRDB ValueObservation.tracking(Session.fetchAll)
        // Maps to AsyncStream for SwiftUI consumption
    }
}
```

### MessageObserver
```swift
public struct MessageObserver {
    private let dbManager: DatabaseManager
    
    /// Returns an AsyncStream that emits messages for a specific session whenever the messages table changes
    public func observeMessages(sessionKey: String) -> AsyncStream<[Message]> {
        // Uses GRDB ValueObservation.tracking(Message.filter(sessionKey).fetchAll)
        // Maps to AsyncStream for SwiftUI consumption
    }
}
```

---

## Package Dependencies

```swift
dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
],
targets: [
    .target(name: "BeeChatSyncBridge",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .target(name: "BeeChatPersistence"),
                .target(name: "BeeChatGateway"),
            ]),
    .testTarget(name: "BeeChatSyncBridgeTests",
                dependencies: ["BeeChatSyncBridge", "BeeChatPersistence", "BeeChatGateway"]),
]
```

**Important:** BeeChatSyncBridge imports BOTH BeeChatPersistence and BeeChatGateway. It is the integration point.

---

## Streaming Delta Buffer

For live streaming messages (delta state), SyncBridge maintains an in-memory buffer:

```swift
/// In-memory only — NOT persisted to DB
private var streamingBuffer: [String: String] = [:]  // runId -> accumulated content
private var streamingSessionKey: String?
```

**Rules:**
- On `chat` delta: append content to `streamingBuffer[runId]`
- On `chat` final: upsert final message to DB, remove from streamingBuffer
- On `chat` error: mark delivery as failed, remove from streamingBuffer
- On new session selection: clear previous streaming state
- UI reads `currentStreamingContent` for live display

---

## Error Handling

| Scenario | Action |
|----------|--------|
| `call()` fails due to disconnect | Reject promise, mark delivery as `failed` if outbound |
| `call()` fails with error response | Log error, update UI state, don't retry automatically |
| Reconnect after disconnect | Run reconciliation sequence (see above) |
| Duplicate event (seq check) | Ignore silently |
| Gap detected (seq skip) | Fetch `chat.history` for affected session |
| `sessions.list` returns empty | Clear local cache only if intentional |
| DB write fails | Log and continue — DB errors should not crash the sync loop |

---

## Attribution

- Event routing patterns informed by ClawChat (`ngmaloney/clawchat`, MIT) — `useSessions.ts`, `useGateway.ts`
- OpenClaw protocol v3 docs (https://docs.openclaw.ai/gateway/protocol)
- GRDB ValueObservation pattern from GRDB.swift docs

---

*This spec is the contract for Component 3. The coder MUST deliver all exit criteria before Component 4 (UI) begins.*

---

## Exit Criteria (MUST ALL PASS)

1. ✅ `SyncBridge.start()` connects gateway, fetches session list, upserts to DB
2. ✅ `sessions.changed` event triggers session list refresh
3. ✅ `chat` events route correctly: delta → streaming buffer, final → DB upsert, error → failed state
4. ✅ `chat.history` fetches and upserts messages for a session
5. ✅ `sendMessage()` creates delivery ledger entry, sends via gateway, updates status on ack
6. ✅ `sendMessage()` uses idempotency key for dedup
7. ✅ Reconnect reconciliation: fetch sessions + active session history, no duplicates
8. ✅ Seq tracking: duplicates ignored, gaps trigger reconciliation
9. ✅ Delivery ledger: pending → sent → delivered → failed lifecycle
10. ✅ ValueObservation: session list and message list emit updates on DB changes
11. ✅ Streaming buffer: delta content accessible, cleared on final/error
12. ✅ Migration003 (delivery_ledger) runs cleanly
13. ✅ All unit tests pass
14. ✅ `swift build` succeeds
15. ✅ `swift test` succeeds