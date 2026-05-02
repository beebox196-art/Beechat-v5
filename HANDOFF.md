Updated: 2026-05-01T22:20:00Z
From/To: Kieran → Q
Task: Diagnose why `didStartStreaming` never fires after sending a message (spinning bee stuck in `.thinking`)

## Symptom

ThinkingBee indicator gets stuck in `.thinking` state after sending a message. It transitions `idle → thinking` but never reaches `.streaming`. The bee spins forever until the 90s streaming timeout rescues it.

**Evidence from diagnostics log** (two messages sent):
```
22:09:56  onMessageSent fired — idle → .thinking
22:10:52  didStartStreaming fired (50s delay!) — thinking → .streaming
22:12:22  Streaming timeout — didStopStreaming never fired → auto-reset to idle

22:14:03  onMessageSent fired — idle → .thinking  
22:14:33  didStartStreaming fired (29s delay) — thinking → .streaming
```

So `didStartStreaming` DOES eventually fire (30-50s delay), but `didStopStreaming` never fires. The 30s thinking timeout safety net hasn't been needed yet because streaming does eventually start.

## Safety Net (Already In Place — Approved)

- **SyncBridgeObserver.swift**: 30s thinking timeout that auto-resets to `.idle` if `didStartStreaming` never fires
- **MainWindow.swift**: calls `startThinkingTimeout()` in `onMessageSent` callback
- Cancels when `didStartStreaming` fires, or when `resetStreamingState()` is called

## What Q Needs to Do

Add a few `print()` statements to trace the event flow. No logging framework needed — just `print()` and Xcode console.

### Step 1: Add prints to EventRouter.route()

In `Sources/BeeChatSyncBridge/EventRouter.swift`, add to `route(event:payload:)`:
```swift
public func route(event: String, payload: [String: AnyCodable]?) async throws {
    print("[EventRouter] Received event: \(event)")
    // ... existing switch
}
```

Also add prints in `handleChatEvent`:
```swift
case "delta":
    print("[EventRouter] chat delta for sessionKey=\(sessionKey)")
case "final":
    print("[EventRouter] chat final for sessionKey=\(sessionKey)")
```

### Step 2: Add prints to SyncBridge

In `Sources/BeeChatSyncBridge/SyncBridge.swift`, in `processChatDelta` and `processChatFinal`:
```swift
print("[SyncBridge] processChatDelta sessionKey=\(sessionKey)")
print("[SyncBridge] processChatFinal sessionKey=\(sessionKey)")
```

### Step 3: Add prints to GatewayClient

In `Sources/BeeChatGateway/GatewayClient.swift`, in `handleEvent`:
```swift
print("[GW] Received event: \(frame.event)")
```

And in `eventStream()`:
```swift
print("[GW] eventStream() continuation set")
```

### Step 4: Run and observe

1. Run app from Xcode (so print() goes to console)
2. Send a message
3. Check Xcode console for:
   - Does `[GW] Received event: chat` appear?
   - Does `[EventRouter] Received event: chat` appear?
   - Does `[EventRouter] chat delta` appear?
   - Does `[EventRouter] chat final` appear?
   - Does `[SyncBridge] processChatDelta` appear?
   - Does `[SyncBridge] processChatFinal` appear?

## Likely Root Cause Areas

1. **WebSocket not delivering events** — gateway sends `chat` events but WS receive loop isn't picking them up
2. **eventStream() continuation not yielding** — GatewayClient receives events but `eventContinuation?.yield()` isn't being called or the AsyncStream consumer isn't running
3. **sessions.subscribe RPC incomplete** — gateway only sends chat events for subscribed sessions; if `rpcClient.sessionsSubscribe()` failed silently, no chat events arrive
4. **Event routing mismatch** — events arrive but session key doesn't match, or payload decode fails silently

## Files Changed (Commit-Ready)

- `Sources/App/UI/MainWindow.swift` — startThinkingTimeout() call
- `Sources/App/UI/Observers/SyncBridgeObserver.swift` — 30s thinking timeout safety net

## Build Status

- ✅ Build succeeds
- ✅ App launches and connects
- ⚠️ Root cause not yet diagnosed (needs Q's print() tracing)
