# BeeChatSyncBridge — Component 3 Specification

**Date:** 2026-04-17  
**Phase:** Build Phase 3  
**Predecessors:** Component 1 (Persistence) ✅, Component 2 (Gateway) ✅  
**Live-validated:** Connected to real OpenClaw gateway on 2026-04-17, captured actual event shapes  
**Exit Criteria:** Sessions list syncs from gateway, messages sync per session, reconnect reconciles without duplicates, UI can observe DB changes reactively

---

## Overview

BeeChatSyncBridge is the glue between BeeChatGateway (WebSocket transport) and BeeChatPersistence (local SQLite cache). It subscribes to gateway events, routes them to database writes, fetches initial state via RPC calls, and publishes DB changes to SwiftUI via GRDB ValueObservation.

**Critical design rules:**
1. **DB is source of UI truth.** SwiftUI observes the database, not the WebSocket.
2. **Gateway owns session state.** Local DB is a cache, always rebuildable from gateway.
3. **Deltas are ephemeral.** Only `final` phase messages get persisted as durable rows.
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
│       │   ├── AgentEvent.swift          — agent event payload (validated live)
│       │   ├── HealthEvent.swift          — health event payload (validated live)
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

## Gateway Event Types (Validated Against Live Gateway)

The GatewayEvent enum has been updated in Component 2 to match the live OpenClaw protocol:

```swift
public enum GatewayEvent: String, Codable, Sendable {
    case agent                          // Primary real-time streaming event (NOT "chat")
    case health                         // Health/status events
    case sessionsChanged = "sessions.changed"  // Session list invalidation
    case sessionMessage = "session.message"     // Per-session transcript updates
    case sessionTool = "session.tool"           // Tool call/result updates
    case presence                       // User presence updates
    case tick                            // Keepalive/liveness
    case connectChallenge = "connect.challenge" // Handshake challenge
    case error                           // Error event
}
```

**Validated against live gateway on 2026-04-17.** See `Docs/History/GATEWAY-PROBE-CAPTURE.json` for captured data.

---

## Event Handling Rules

### `agent` Event — Primary Real-Time Event

**CRITICAL: The primary real-time event is `agent`, NOT `chat`.** Validated against the live OpenClaw gateway. The gateway emits `agent` events for all streaming transcript data.

The payload contains streaming data with a `stream` field and a `data` object:

```swift
struct AgentEventPayload: Codable {
    let runId: String
    let stream: String          // "item" or "text" (validated live)
    let data: AgentEventData    // Polymorphic — shape depends on stream+kind
    let sessionKey: String
    let seq: Int?               // Event sequence number
    let ts: Int64               // Unix milliseconds
}

// The data field is polymorphic. Key discriminator: stream + kind
struct AgentEventData: Codable {
    let itemId: String?         // Unique item ID (e.g. "tool:ollama_call_...")
    let phase: String?          // "delta", "update", "final"
    let kind: String?           // "tool", "text", or other
    let title: String?          // Display title for tool calls
    let status: String?         // "running", "completed", "error"
    let name: String?           // Tool name (e.g. "exec", "read")
    let text: String?           // Text content (for text stream items)
    let toolCallId: String?     // Tool call reference
}
```

**Live captured example (tool call update):**
```json
{
  "runId": "2cd1e889-81d0-4bb8-b356-d49a7b38ea3a",
  "stream": "item",
  "data": {
    "itemId": "tool:ollama_call_d26d42b4-...",
    "phase": "update",
    "kind": "tool",
    "title": "exec run node script...",
    "status": "running",
    "name": "exec",
    "toolCallId": "ollama_call_d26d42b4-..."
  },
  "sessionKey": "agent:main:telegram:group:-1003830552971:topic:1185",
  "seq": 566,
  "ts": 1776440726273
}
```

**Handling rules:**
- `stream: "item"`, `kind: "tool"` → tool call tracking (store as message metadata or skip for v1)
- `stream: "text"` → streaming text content (ephemeral delta buffer, NOT persisted)
- `stream: "item"`, `kind: "text"`, `phase: "delta"` → append to streaming buffer
- `stream: "item"`, `phase: "final"` → persist as durable message row, clear streaming buffer
- `stream: "item"`, `phase: "error"` → mark delivery as failed, clear streaming buffer
- The `data` field is polymorphic — decode based on `stream` and `kind` fields

### `health` Event

Regular health check event with channel status, agent info, and session metadata.

```swift
struct HealthEventPayload: Codable {
    let ok: Bool
    let ts: Int64
    let durationMs: Int
    let channels: [String: ChannelStatus]?
    let agents: [String: AgentStatus]?
    let sessions: [String: SessionStatus]?
}
```

**Handling:**
- Update connection health state in memory
- Extract session metadata if needed (session count, active sessions)
- Do NOT write to DB on every health event (too frequent)

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

### `session.tool` Event

Tool call/result updates for subscribed sessions.

**Handling:**
- Store as message metadata or skip for v1

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
    let model: String?       // e.g. "ollama/glm-5.1:cloud"
    let totalTokens: Int?    // Token usage
    let lastMessageAt: String? // ISO 8601 timestamp
}
```

**Note:** Validated live — the method exists in `hello-ok.features.methods`. Returns session objects with a `key` field.

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

**Note:** `chat.history` is UI-normalized — directive tags and tool XML may be stripped. Not a raw audit ledger.

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

For live streaming messages, SyncBridge maintains an in-memory buffer:

```swift
/// In-memory only — NOT persisted to DB
private var streamingBuffer: [String: String] = [:]  // runId -> accumulated content
private var streamingSessionKey: String?
```

**Rules:**
- On `agent` event with `phase: "delta"` → append content to `streamingBuffer[runId]`
- On `agent` event with `phase: "final"` → upsert final message to DB, remove from streamingBuffer
- On `agent` event with `phase: "error"` → mark delivery as failed, remove from streamingBuffer
- On new session selection → clear previous streaming state
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

## Client Mode Note

The WebSocket client must connect with `client.mode: "webchat"` (not `"operator"`). The gateway schema validates `mode` against a strict enum. Validated against live gateway on 2026-04-17.

---

## Attribution

- Event routing patterns informed by ClawChat (`ngmaloney/clawchat`, MIT) — `useSessions.ts`, `useGateway.ts`
- OpenClaw protocol v3 docs (https://docs.openclaw.ai/gateway/protocol)
- GRDB ValueObservation pattern from GRDB.swift docs
- Live gateway validation data: `Docs/History/GATEWAY-PROBE-CAPTURE.json`

---

*This spec is the contract for Component 3. The coder MUST deliver all exit criteria before Component 4 (UI) begins.*

---

## Exit Criteria (MUST ALL PASS)

1. ✅ `SyncBridge.start()` connects gateway, fetches session list, upserts to DB
2. ✅ `sessions.changed` event triggers session list refresh
3. ✅ `agent` events route correctly: delta → streaming buffer, final → DB upsert, error → failed state
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