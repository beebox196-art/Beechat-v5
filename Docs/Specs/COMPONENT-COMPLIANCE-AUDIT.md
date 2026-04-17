# BeeChat v5 — Component Compliance Audit

**Date:** 2026-04-17
**Purpose:** Audit Components 1-3 against the channel plugin architecture to identify what stays, what adapts, and what gets replaced.

---

## Component 1: BeeChatPersistence ✅ COMPLIANT (minor adaptations)

**Files:** `Sources/BeeChatPersistence/`

### Fully Compliant (no changes needed)
- `Models/Message.swift` — Domain model, maps from any source. Stays as-is.
- `Models/Session.swift` — Domain model. Stays as-is.
- `Models/Attachment.swift` — Domain model. Stays as-is.
- `Models/MessageBlock.swift` — Domain model. Stays as-is.
- `Database/DatabaseManager.swift` — GRDB SQLite setup. Stays as-is.
- `Repositories/MessageRepository.swift` — CRUD for messages. Stays as-is.
- `Repositories/SessionRepository.swift` — CRUD for sessions. Stays as-is.
- `Repositories/AttachmentRepository.swift` — CRUD for attachments. Stays as-is.
- `Protocols/MessageStore.swift` — Protocol abstraction. Stays as-is.

### Adaptations Needed
| File | Change | Reason |
|------|--------|--------|
| `BeeChatPersistenceStore.swift` | May need new upsert methods for bulk sync from plugin API | Plugin returns JSON arrays, not single WebSocket events |

**Verdict:** Component 1 is clean. It's a persistence layer — it doesn't care where data comes from. Zero architectural conflict.

---

## Component 2: BeeChatGateway ⚠️ PARTIALLY OBSOLETE (major replacement)

**Files:** `Sources/BeeChatGateway/`

### Obsolete — Replace with PluginAPI (Swift HTTP client)

| File | Why Obsolete | Replacement |
|------|-------------|-------------|
| `GatewayClient.swift` | WebSocket connection to gateway. Plugin is in-process — no WebSocket needed | `PluginAPIClient.swift` (HTTP client to `localhost:18789/beechat/api/*`) |
| `Transport/WebSocketTransport.swift` | WebSocket transport layer | Not needed — use `URLSession` |
| `Protocol/ConnectParams.swift` | Gateway handshake params (client mode, scopes, role) | Not needed — no handshake |
| `Auth/DeviceIdentity.swift` | Ed25519 device identity for external WebSocket auth | Not needed — plugin auth is in-process |
| `Auth/DeviceCrypto.swift` | Ed25519 crypto operations | Not needed |
| `Auth/TokenStore.swift` | Device token persistence | Not needed |

### Keep (with adaptation)

| File | Change | Reason |
|------|--------|--------|
| `Protocol/Frame.swift` | Rewrite as plugin API response models | The frame/event concept still useful, but maps to HTTP JSON responses |
| `Protocol/GatewayEvent.swift` | Rewrite as plugin event stream models | Events come from plugin WebSocket (`/beechat/ws`), not gateway WebSocket |
| `ConnectionState.swift` | Keep but simplify | Still need connection state, just HTTP+WS instead of gateway WS |
| `Internal/PendingRequestMap.swift` | Replace with HTTP request tracking | Same concept, different transport |
| `Internal/BackoffCalculator.swift` | Keep as-is | Still need retry backoff for HTTP calls |
| `AnyCodable.swift` | Keep as-is | Utility, transport-agnostic |

**Verdict:** Component 2 is the most affected. The core purpose (communicate with gateway) shifts from WebSocket to HTTP. The domain models and utilities survive, but the transport and auth layers are entirely replaced.

---

## Component 3: BeeChatSyncBridge ⚠️ NEEDS REFACTORING (significant adaptation)

**Files:** `Sources/BeeChatSyncBridge/`

### Compliant (keep as-is or minor changes)

| File | Change | Reason |
|------|--------|--------|
| `Models/SessionInfo.swift` | Keep | Domain model, maps from any source |
| `Models/ChatMessage.swift` | Keep | Domain model |
| `Models/AgentEvent.swift` | Adapt field names to match plugin event format | Plugin events may differ from gateway WebSocket events |
| `Models/HealthEvent.swift` | Keep | Domain model |
| `Models/DeliveryLedgerEntry.swift` | Keep | Outbox pattern still valid |
| `Persistence/DeliveryLedgerRepository.swift` | Keep | Local tracking |
| `Persistence/Migration003_DeliveryLedger.swift` | Keep | DB migration |
| `Protocols/SyncBridgeConfiguration.swift` | Rewrite — remove `gatewayClient` requirement | Config now points to plugin HTTP URL, not gateway WebSocket |
| `Protocols/SyncBridgeDelegate.swift` | Keep | Delegate pattern still valid |
| `Reconciler.swift` | Adapt — pull from plugin API instead of gateway RPC | Same concept, different source |
| `Observation/SessionObserver.swift` | Keep | GRDB observation, transport-agnostic |
| `Observation/MessageObserver.swift` | Keep | GRDB observation, transport-agnostic |

### Needs Refactoring

| File | Change | Reason |
|------|--------|--------|
| `SyncBridge.swift` | **Major refactor** — replace `gatewayClient.connect()` with plugin API init, replace `eventStream` with plugin WS or SSE, replace `rpcClient` calls with plugin HTTP calls | This is the orchestration layer — it must talk to plugin, not gateway |
| `RPCClient.swift` | **Replace** with `PluginAPIClient` (HTTP calls to `/beechat/api/*`) | Same RPC concept, different transport. Methods stay the same (`sessionsList`, `chatHistory`, `chatSend`, `chatAbort`) |
| `EventRouter.swift` | Adapt event names to match plugin event format | Plugin events may use different keys than gateway WebSocket |

### The RPCClient Protocol — The Bridge

The `RPCClientProtocol` is actually **the perfect abstraction layer**. It already defines the exact operations we need:

```swift
public protocol RPCClientProtocol {
    func sessionsList() async throws -> [SessionInfo]
    func sessionsSubscribe() async throws
    func chatHistory(sessionKey: String, limit: Int?) async throws -> [ChatMessagePayload]
    func chatSend(sessionKey: String, message: String, idempotencyKey: String, thinking: String?, attachments: [[String: Any]]?) async throws -> String
    func chatAbort(sessionKey: String) async throws -> Bool
}
```

We keep this protocol, but implement it with an HTTP client instead of a WebSocket RPC client:

```swift
struct PluginAPIClient: RPCClientProtocol {
    let baseURL: URL  // http://localhost:18789/beechat/api
    
    func sessionsList() async throws -> [SessionInfo] {
        let data = try await httpGet("/sessions")
        // Parse JSON response from plugin
    }
    
    func chatSend(sessionKey: String, message: String, ...) async throws -> String {
        let data = try await httpPost("/send", body: [...])
        // Parse JSON response from plugin
    }
    // ...
}
```

**Verdict:** Component 3's architecture is sound — the protocol abstraction means we swap the implementation, not the interface. SyncBridge needs refactoring to remove the gateway WebSocket dependency, but the orchestration logic (reconciler, observers, delivery ledger) is all reusable.

---

## Summary

| Component | Status | Effort | Key Insight |
|-----------|--------|--------|-------------|
| **1: Persistence** | ✅ Compliant | Minimal | Pure data layer — doesn't care about transport |
| **2: Gateway** | ⚠️ Replaced | Medium | Transport & auth go; models & utilities stay |
| **3: SyncBridge** | ⚠️ Refactored | Medium | `RPCClientProtocol` is the keystone — keep protocol, swap implementation |

**The critical refactoring path:**

```
Current:  Swift App → GatewayClient (WS) → Gateway WebSocket → Gateway RPC
New:      Swift App → PluginAPIClient (HTTP) → Plugin HTTP Routes → PluginRuntime (in-process)
```

The `RPCClientProtocol` is the seam. Swap `RPCClient` (WebSocket-backed) with `PluginAPIClient` (HTTP-backed). SyncBridge talks to the protocol, doesn't know the difference.

---

## Action Items

1. **Create `PluginAPIClient.swift`** implementing `RPCClientProtocol` via HTTP
2. **Refactor `SyncBridge.swift`** to remove `gatewayClient` dependency, use `RPCClientProtocol` only
3. **Update `SyncBridgeConfiguration.swift`** to accept plugin HTTP URL instead of gateway WebSocket URL
4. **Adapt `EventRouter.swift`** to handle plugin event format (may be identical, needs testing)
5. **Keep Component 1 untouched** — it's already compliant
6. **Archive Component 2's transport/auth code** — it's useful reference but no longer the active path
7. **Add plugin event stream** — WebSocket from `/beechat/ws` or SSE fallback for real-time events