# Legacy/Dead Code Cleanup Assessment

**Date:** 2026-04-23
**Scope:** All Swift source files in Sources/

## Changes Made (Confirmed Safe, Build Passes ✅)

### 1. GatewayClient.swift — Removed `lastMessageRawData`
- **What:** Private stored property `lastMessageRawData: Data?` and its assignment in `handleMessage()`
- **Why dead:** Set on every incoming message but never read anywhere. The `rawData` property on `ResponseFrame`/`EventFrame` serves the same purpose and is actively used for decoding.

### 2. GatewayClient.swift — Removed `removeStatusChangeObserver()`
- **What:** Public method with empty body (comment: "closures aren't Equatable, so clear all and re-add non-matching — in practice, we just keep appending")
- **Why dead:** The method was a no-op. Observers added via `updateConnectionStateObserver()` can never be individually removed. The comment itself admits it doesn't work.

### 3. SyncBridge.swift — Removed `_ = event.runId`
- **What:** Line that explicitly discards the `runId` field from `AgentEventPayload`
- **Why dead:** The `runId` is already available on the event struct if needed; discarding it does nothing.

### 4. SessionRepository.swift — Simplified `deleteCascading()`
- **What:** Removed the entire legacy `topicId` branch (~30 lines) that handled the pre-Migration006 schema where messages used `topicId` instead of `sessionId`
- **Why dead:** Migration006 drops and recreates the messages table with `sessionId`. Any DB that has run migrations will never have `topicId` in messages. The app is local-only, so all installations have migrated.

### 5. MessageBubble.swift — Removed unused `canvasWidth` parameter
- **What:** Convenience initializers `leading(canvasWidth:)` and `trailing(canvasWidth:)` accepted a `CGFloat` parameter but never used it
- **Why dead:** The parameter was ignored; the environment value was always used instead. Misleading API.

---

## Findings NOT Removed (Judgment Calls)

### 🔴 Triplicated `isBeeChatSession` / `normalizeSessionKey` logic
- **Location:** `SyncBridge.swift`, `Reconciler.swift`, and conceptually in `SessionKeyNormalizer` (file doesn't exist — the sub-agent report was wrong about this)
- **Assessment:** `SyncBridge.isBeeChatSession()` includes caching (`sessionKeyMap`, `beechatSessionKeys`) that `Reconciler.isBeeChatSession()` lacks. They're in different concurrency domains (actor vs struct). Deduplication would require restructuring the Reconciler to accept a SyncBridge reference or extracting to a shared utility.
- **Risk of removal:** Medium — requires careful refactoring of actor boundaries. Not a simple delete.
- **Recommendation:** Refactor in a separate PR. Extract the core logic into a `SessionKeyResolver` protocol that both can use.

### 🟡 Empty stubs: `updateLiveness()`, `handleHealthEvent()`
- **Location:** `SyncBridge.updateLiveness()` (empty body), `EventRouter.handleHealthEvent()` (empty body)
- **Assessment:** These are intentional placeholders for future features (liveness tracking, health monitoring). Removing them would break the call chain and require updates to callers.
- **Recommendation:** Keep. Add `// TODO:` markers if desired, but they serve as extension points.

### 🟡 `thinking` parameter in RPCClient / SyncBridge
- **Location:** `RPCClient.chatSend(thinking:)`, `SyncBridge.sendMessage(thinking:)`
- **Assessment:** Currently always passed as `nil`, but this is a gateway API parameter that's wired through end-to-end. The UI may use it in future. Removal would be premature.
- **Recommendation:** Keep. The parameter exists in the gateway protocol.

### 🟡 `ServerInfo` `id` fallback in ConnectParams
- **Location:** `ServerInfo.init(from:)` tries `connId` then falls back to `id`
- **Assessment:** Defensive compat shim. If the gateway now consistently sends `connId`, the `id` fallback is dead. But this is a one-liner with zero cost that provides resilience against server changes.
- **Recommendation:** Keep. Risk/cost ratio favours retention.

### 🟡 `manuallyDecodeHelloOk()` and Attempts 2-3 in `resolveHandshake()`
- **Location:** `GatewayClient.swift`
- **Assessment:** Three decoding strategies for the handshake payload. Attempt 1 (rawData) should always work. Attempts 2-3 are resilience fallbacks. The `[String: Any]` branch inside Attempt 3 is likely dead (AnyCodable always produces `[String: AnyCodable]`).
- **Recommendation:** Keep as defensive coding. The handshake is the most critical path and resilience is valuable. Could simplify Attempt 3's `[String: Any]` branch in a future cleanup.

### 🟡 Session model / SessionRepository
- **Location:** `BeeChatPersistence/Models/Session.swift`, `SessionRepository.swift`, `BeeChatPersistenceStore` session operations
- **Assessment:** The app sidebar uses `Topic` exclusively. Session is used by `SyncBridge.fetchSessions()` and `Reconciler.reconcile()` to store gateway session metadata. It's still written to but the Session model itself is largely redundant with Topic.
- **Recommendation:** Keep for now. Sessions serve as a cache of gateway-side metadata (channel, label, lastMessageAt) that isn't stored on Topic. A future refactor could merge Session into Topic.

### 🟡 Migration003_CreateAttachmentsIfMissing
- **Location:** `DatabaseManager.swift`
- **Assessment:** Defensive no-op — Migration002 already creates the attachments table. Harmless.
- **Recommendation:** Keep. GRDB migrations run once and are idempotent. Removing a migration from the chain would be dangerous.

### 🟡 ThemeManager stub methods
- **Location:** `ThemeManager.switchTheme(to:)`, `loadPersistedTheme()`
- **Assessment:** Infrastructure for multi-theme support (Phase 4B). Currently only one theme exists, making these effectively no-ops. But they're small and intentional scaffolding.
- **Recommendation:** Keep. Part of the planned Phase 4B work.

---

## Summary

| Category | Count | Action Taken |
|----------|-------|-------------|
| Removed dead code | 5 items | ✅ Cleaned up |
| Duplicated logic (deferred) | 1 | 🔴 Needs refactoring PR |
| Intentional stubs/planned features | 6 | 🟡 Keep |
| Defensive fallbacks | 3 | 🟡 Keep |

**Build status:** ✅ `swift build` passes with only pre-existing warnings (Sendable conformance, actor isolation)