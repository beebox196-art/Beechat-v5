# FIX-001: Message Dedup Guard

**Priority:** High  
**Status:** Spec — revised after Kieran review (PASS conditions met)  
**Author:** Bee (Coordinator)  
**Date:** 2026-04-25

## Problem

`EventRouter.handleSessionMessage()` saves every incoming message without checking if it already exists in the database. When the gateway re-sends events (reconnect, reconciliation, or duplicate delivery), this causes duplicate messages in the UI.

Additionally, `handleChatEvent` in the `"final"` case saves the message explicitly AND then calls `processChatFinal()` which calls `fetchHistory()` — which upserts the same messages. This is a double-write path.

## Scope

**In scope:**
- Add `messageExists(id:)` method to `SyncBridge`
- Add dedup guard in `EventRouter.handleSessionMessage()`
- Remove redundant message save in `EventRouter.handleChatEvent` final case (since `processChatFinal` → `fetchHistory` already persists the message)

**Out of scope:**
- No changes to `MessageListObserver` (that's Fix #2 — CPU thrashing)
- No changes to `MessageCanvas` scroll behavior (that's Fix #3)
- No retry logic in `processChatFinal` (that's Fix #4)
- No changes to `processAgentEvent` final case (same pattern but lower priority)

## Specification

### 1. `SyncBridge.messageExists(id:)`

Add a new internal method:

```swift
/// Check if a message with the given ID already exists in the database.
internal func messageExists(id: String) throws -> Bool {
    let writer = try DatabaseManager.shared.writer
    return try writer.read { db in
        try Message.filter(Column("id") == id).fetchCount(db) > 0
    }
}
```

**Constraints:**
- Must be `throws`, not force-unwrap or `fatalError`
- Must be synchronous (GRDB reads are fast, no need for async)
- Called from `EventRouter` which is not an actor, so it must work from non-isolated context via `try await syncBridge.messageExists(id:)`

### 2. Dedup guard in `handleSessionMessage()`

Before creating and saving a new `Message`, check if it already exists:

```swift
let messageId = sessionMsg.data.id ?? UUID().uuidString

// Dedup guard — skip if already persisted (fail-open on DB error)
let exists = (try? await syncBridge.messageExists(id: messageId)) ?? false
if exists {
    return
}
```

**Note:** `messageExists` is synchronous but `SyncBridge` is an actor, so the call must be `try await` for actor isolation.

### 3. Keep explicit save in `handleChatEvent` final case (with dedup guard)

**Current code:**
```swift
case "final":
    if let text = messageText, let msg = chatEvent.message {
        let messageId = msg.id ?? UUID().uuidString
        let timestamp = msg.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
        let message = Message(
            id: messageId,
            sessionId: sessionKey,
            role: "assistant",
            content: text,
            timestamp: Date(timeIntervalSince1970: Double(timestamp / 1000))
        )
        try await syncBridge.saveGatewayMessage(message)
    }
    try await syncBridge.processChatFinal(sessionKey: sessionKey)
```

**Replace with:**
```swift
case "final":
    if let text = messageText, let msg = chatEvent.message {
        let messageId = msg.id ?? UUID().uuidString
        let timestamp = msg.timestamp ?? Int64(Date().timeIntervalSince1970 * 1000)
        let message = Message(
            id: messageId,
            sessionId: sessionKey,
            role: "assistant",
            content: text,
            timestamp: Date(timeIntervalSince1970: Double(timestamp / 1000))
        )
        // Dedup guard — skip if already persisted (fail-open on DB error)
        let exists = (try? await syncBridge.messageExists(id: messageId)) ?? false
        if !exists {
            try await syncBridge.saveGatewayMessage(message)
        }
    }
    try await syncBridge.processChatFinal(sessionKey: sessionKey)
```

**Rationale:** The explicit save acts as a safety net — if `fetchHistory` RPC fails (network error, timeout), the message is already persisted locally. Previously, it could double-save; the dedup guard now prevents that. `saveGatewayMessage` already normalizes the session key via `normalizeSessionKey()`, so there's no key mismatch concern.

## Files Changed

| File | Change |
|------|--------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Add `messageExists(id:)` method |
| `Sources/BeeChatSyncBridge/EventRouter.swift` | Add dedup guard (fail-open) in `handleSessionMessage()` AND in `handleChatEvent` final case |

## Validation Criteria

1. **Build:** `xcodebuild -scheme BeeChatApp -destination 'platform=macOS' build` passes
2. **No regressions:** App connects, shows topics, displays messages, sends messages, streams AI responses — same as baseline
3. **Dedup works:** Reconnecting or receiving duplicate `session.message` events does NOT create duplicate messages in the UI
4. **Streaming still works:** AI responses stream and finalize correctly without the explicit save in final case

## Kieran Review Notes

- **TOCTOU race (Medium):** Between `messageExists` and `saveGatewayMessage`, reconciliation could write the same message. Harmless if `saveMessage` upserts — confirmed it does via `upsertAndFetch` in the persistence store.
- **Persistence store abstraction (Low):** `messageExists` queries GRDB directly rather than going through `persistenceStore` protocol. Accepted for now; can refactor to the protocol later if needed.
- **`EventRouter` as struct holding actor reference (Low):** Fine in current code, noted for future if changed to class.

## Rollback

If this fix causes any regression, revert both files to main branch state. No other files are touched.