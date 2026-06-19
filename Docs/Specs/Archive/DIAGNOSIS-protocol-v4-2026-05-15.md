# DIAGNOSIS: BeeChat Protocol Mismatch with OpenClaw 5.12

**Date:** 2026-05-15
**Symptom:** BeeChat shows "offline — handshake failed: protocol mismatch"
**Root Cause:** OpenClaw 5.12 requires gateway protocol v4 (minimum). BeeChat declares `minProtocol: 3, maxProtocol: 3`.

## Problem Statement

OpenClaw 5.12 upgraded the gateway protocol to v4. The handshake now enforces:
```
const supportsCurrentProtocol = maxProtocol >= 4 && minProtocol <= 4;
```
If the client's protocol range doesn't include v4, the gateway closes the WebSocket with code 1002 and error "protocol mismatch".

BeeChat's `ConnectParams.swift` hardcodes:
```swift
public let minProtocol: Int = 3
public let maxProtocol: Int = 3
```

This means `maxProtocol(3) < 4` → handshake rejected immediately.

## What Changed in v4

### 1. Protocol version bump (breaking)
- `PROTOCOL_VERSION` = 4, `MIN_CLIENT_PROTOCOL_VERSION` = 4
- Clients MUST declare `minProtocol <= 4` and `maxProtocol >= 4`
- The gateway rejects any client not offering v4

### 2. Chat delta events: `deltaText` replaces `message.content` for streaming
In v3, the `chat` event with `state: "delta"` carried the full cumulative text in `message.content`. In v4, the `chat` delta event uses explicit fields:

```json
{
  "type": "event",
  "event": "chat",
  "payload": {
    "runId": "...",
    "sessionKey": "...",
    "seq": 123,
    "state": "delta",
    "deltaText": "new text increment",
    "replace": false,
    "message": { ... }
  }
}
```

Key differences:
- **`deltaText`** (required, string): The incremental text since the last delta. If `replace` is true, `deltaText` is the full replacement text.
- **`replace`** (optional, boolean): When true, the client should replace all prior text with `deltaText` instead of appending.
- **`message`** (optional): Cumulative snapshot. Still present for compatibility but clients should prefer `deltaText` for streaming assembly.
- **`runId`** (new, string): Unique run ID for the agent turn. Required for correlating delta/final/abort/error events.
- **`spawnedBy`** (optional, string): Present for subagent sessions.
- **`seq`** (integer): Monotonically increasing per-connection sequence number.

### 3. Chat final event
```json
{
  "state": "final",
  "runId": "...",
  "sessionKey": "...",
  "seq": 456,
  "message": { "role": "assistant", "content": "..." },
  "usage": { ... },
  "stopReason": "end_turn"
}
```

### 4. Chat aborted event (new)
```json
{
  "state": "aborted",
  "runId": "...",
  "sessionKey": "...",
  "seq": 789,
  "message": { ... },
  "stopReason": "cancelled"
}
```

### 5. Chat error event
```json
{
  "state": "error",
  "runId": "...",
  "sessionKey": "...",
  "seq": 100,
  "errorMessage": "...",
  "errorKind": "timeout" | "rate_limit" | "context_length" | "refusal" | "unknown"
}
```

## Files That Need Changes

### 1. `Sources/BeeChatGateway/Protocol/ConnectParams.swift`
- Change `minProtocol: Int = 3` → `minProtocol: Int = 4`
- Change `maxProtocol: Int = 3` → `maxProtocol: Int = 4`

### 2. `Sources/BeeChatGateway/GatewayClient.swift`
- Update `manuallyDecodeHelloOk()` to handle `protocol: 4` (already handled by `?? 3` fallback — change default to `?? 4`)
- Verify handshake response parsing works with v4 `hello-ok`

### 3. `Sources/BeeChatSyncBridge/Models/GatewayEventPayloads.swift`
- Add `runId`, `seq`, `spawnedBy`, `errorKind`, `stopReason` fields to `ChatEventPayload`
- Add `deltaText` (String) and `replace` (Bool?) fields
- Add `aborted` state handling

### 4. `Sources/BeeChatSyncBridge/EventRouter.swift`
- Update `handleChatEvent` to use `deltaText` for streaming instead of `message.content`
- When `replace: true`, replace accumulated text with `deltaText`
- When `replace: false` (or absent), append `deltaText`
- Handle `state: "aborted"` as a new case
- Fallback: if `deltaText` is nil/empty but `message.content` exists, use `message.content` (v3 compat)

### 5. `Sources/BeeChatSyncBridge/SyncBridge.swift`
- Update `processChatDelta` to accept delta text + replace flag instead of cumulative text
- If `replace: true`, reset streaming buffer to `deltaText`
- If `replace: false`, append `deltaText` to existing buffer
- This changes the streaming model from "gateway sends full text each time" to "gateway sends increments"

## Testing Checklist
- [ ] BeeChat connects to gateway without "protocol mismatch" error
- [ ] Streaming responses display correctly (delta text appended incrementally)
- [ ] `replace: true` deltas correctly replace previous text (e.g., model corrections)
- [ ] Final messages persist correctly
- [ ] Aborted responses show appropriate UI state
- [ ] Error events display error messages
- [ ] Session messages (`session.message` event) still work (unchanged)
- [ ] Tick events still work
- [ ] Agent events still work
- [ ] Backward compatibility: if gateway sends v3-style delta (message.content only), still renders

## Minimal Hotfix (Protocol Version Only)
If we want BeeChat working immediately while the full deltaText changes are built:
1. Change `minProtocol: 4, maxProtocol: 4` in ConnectParams.swift
2. In `EventRouter.handleChatEvent`, for `state: "delta"`:
   - Try `deltaText` first
   - Fall back to `message.content` if `deltaText` is nil
   - This works because v4 still sends `message` as a cumulative snapshot

The streaming behavior will degrade (full text snapshots instead of increments) but BeeChat will be **online and functional**.

## Risk Assessment
- **Confidence:** HIGH — this is the exact error from the changelog entry: "Gateway protocol: require v4 clients and stream explicit chat deltaText/replace frames"
- **Breaking change:** Yes, protocol v4 is mandatory in 5.12
- **Scope:** Protocol handshake + chat event parsing. No UI changes needed for the hotfix.