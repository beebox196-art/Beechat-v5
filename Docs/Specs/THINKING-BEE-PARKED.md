# BeeChat v5 — Thinking Bee Indicator: Parked Issue

**Status:** PARKED (2026-04-25)
**Priority:** Low — cosmetic indicator issue, messages work fine
**Spec:** FIX-003-POLL-SLEEP-BEE-DIAGNOSTICS.md

## Root Cause (Confirmed via Diagnostics)

`didStopStreaming` **never fires**. The gateway delivers streaming deltas via `chat` events with `state: "delta"`, but never sends `state: "final"`. The state machine gets stuck at `.streaming` forever after the first message, blocking the thinking bee on all subsequent sends.

### Evidence from Logs

1. `didStartStreaming` fires exactly once per stream (Fix A works — first-delta guard)
2. `didStopStreaming` fires **0 times** across all test sessions
3. After first stream, `thinkingState` stays `.streaming` permanently
4. Every subsequent `onMessageSent` is blocked by `guard != .streaming`

### Why the session.message Fix Didn't Work

Added `processChatFinal` call in `handleSessionMessage` when `role == "assistant"`, but it never triggered. Possible causes:
- `isBeeChatSession` may filter the event (session key format mismatch: `agent:main:uuid` vs `UUID`)
- The dedup guard returns early before reaching `processChatFinal`
- Events may arrive through a path not yet logged

### The Fix (When Resuming)

1. **Trace actual gateway events** — Add `BeeChatLogger` calls inside `GatewayClient` (not `EventRouter`) to log every raw WebSocket event received. This will show what events the gateway actually sends for stream completion.
2. **Session key normalisation** — `didStartStreaming` receives `agent:main:uuid-lowercase` but `sendMessage` uses `UUID-uppercase`. The `currentStreamingSessionKey` comparison in `processChatFinal` may fail due to case mismatch.
3. **Remove the `.streaming` guard** as a safety net — if `thinkingState` is `.streaming` and a new message is sent, reset to `.thinking` instead of blocking.

## Other Fixes Delivered

- **Streaming poll sleep (50ms)** — Eliminates CPU spin loop. ✅ Merged
- **First-delta guard** — `didStartStreaming` only fires on first delta, not every token. ✅ Merged

## Diagnostic Logger

`BeeChatLogger.swift` writes to `~/Desktop/BeeChat-diagnostics.log`. Leave this in — it's useful for future debugging. The `print()` statements in `SyncBridge`/`EventRouter` should be removed or converted to `BeeChatLogger` when the library target can access it (requires making BeeChatLogger a shared utility).