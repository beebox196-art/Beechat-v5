# Fix Spec: SyncBridge Auto-Reset Zombie PiRun Race Condition

**Date:** 2026-05-20  
**Author:** Bee (coordinator)  
**Severity:** High — messages never receive responses, UI shows infinite spinner  
**Version:** v0.5.4-scroll-fix4  
**Reviewers:** Q (builder), Kieran (adversarial reviewer)  
**Revision:** 2 (post-review — fire-and-forget approach)  

---

## 1. Problem Statement

### 1.1 User-Visible Symptoms
1. User sends a message in a BeeChat topic → bee spinner starts
2. Spinner continues indefinitely — no response from the agent
3. Sending again produces the same result (or `concurrentSendInProgress` error)

### 1.2 Reproduction
1. Use a BeeChat topic whose session has usage ≥ 80% (auto-reset threshold)
2. The session has a recently active or slow-to-abort PiRun
3. Send a message → auto-reset triggers → `sessions.reset` blocks for 15s → fails → message sent but agent never responds

### 1.3 Evidence
- Gateway logs: `sessions.reset` → UNAVAILABLE "Session ... is still active" (15s timeout) at 15:38:47 and 15:43:34
- Delivery ledger shows messages with status `sent` and runIds — `chatSend` DID succeed
- Session was responsive when messaged directly via `sessions_send`
- No `chat.send` visible in gateway logs for the BeeChat connection — likely a logging gap (RPC requests vs events), not evidence that the send never happened. If the delivery ledger has a runId, the gateway accepted it.
- The Beechat Mobile session's last exchange was about Tailscale — a long-form response that likely created a slow-to-abort PiRun

---

## 2. Root Cause Analysis

### 2.1 The Zombie PiRun Race Condition

```
1. sendMessage() called
2. sendingSessionKeys.insert(sessionKey) — guard spans ENTIRE function
3. abortGeneration() — sends chat.abort if stream is active
4. sessionsUsage() → usage ≥ 80% → auto-reset triggers
5. resetSession() → rpcClient.sessionsReset() → gateway.call("sessions.reset")
6. Gateway: ensureSessionRuntimeCleanup() → abortEmbeddedPiRun [SECOND abort]
7. Gateway: waitForEmbeddedPiRunEnd(15000ms) → TIMES OUT
8. Gateway returns UNAVAILABLE to client
9. Client catch block: prints error, continues
10. chatSend() → gateway accepts → returns runId
11. Gateway starts new PiRun for chat.send
12. BUT: old PiRun is zombie-running (abort sent but didn't complete)
13. New PiRun on session with zombie run → agent never responds
14. No stall timer is running (timer only starts on first delta, which never arrives)
15. Spinner runs forever
```

### 2.2 Why the User Sees Infinite Spinner

- `onMessageSent` sets `thinkingState = .thinking` before `sendMessage` starts
- 15+ seconds of no feedback during the reset timeout
- After `chatSend` succeeds, the gateway starts a new PiRun but it gets stuck
- The existing stall timer only starts AFTER the first delta arrives — if no delta ever arrives, no timer fires
- Result: infinite spinner with no timeout

### 2.3 Tailscale Correlation

The Beechat Mobile session was the one where the Tailscale configuration discussion happened. The long-form response pushed the session over the 80% auto-reset threshold, and the PiRun from that exchange was slow to abort. The timing correlation with Tailscale setup is real but indirect — Tailscale caused the session to hit the reset threshold, but the bug is in the reset handling, not Tailscale itself.

---

## 3. Alignment with Standard Patterns

The gateway's `sessions.reset` API is designed for best-effort cleanup. When cleanup times out, the correct client behavior is:
- Treat the reset as failed
- **Do not assume the session is in a clean state**
- Proceed with the send on the current (un-reset) session
- Let the reset take effect for the *next* interaction

The current implementation violates this by blocking the send on the reset and then sending on a potentially half-cleaned session. The fix aligns with the standard pattern: fire-and-forget reset, immediate send.

---

## 4. Fix Specification (Post-Review Revision)

### 4.1 Guiding Principles

1. **Never block the send on a reset.** The user's message should reach the gateway immediately.
2. **Fire-and-forget reset.** Send the reset as a background task. Don't wait for the result before sending the user's message.
3. **No race conditions.** By not waiting for the reset, we eliminate the window where `chat.send` arrives while the gateway is mid-cleanup.
4. **Reuse existing stall infrastructure.** The existing `streamStallInterval` (30s) already handles mid-stream stalls. Extend it to also cover "never started" stalls.
5. **Narrow the concurrent send guard.** The `sendingSessionKeys` guard should only cover `chatSend`, not the auto-reset.

### 4.2 Change 1: Make auto-reset fire-and-forget (CRITICAL FIX)

**File:** `Sources/BeeChatSyncBridge/SyncBridge.swift`  
**Risk:** Medium

**Current:** Auto-reset runs inline in `sendMessage`, blocking the send path for 15+ seconds.

**Proposed:** When auto-reset is triggered, kick it off as a background `Task`. The user's message sends immediately on the current (un-reset) session. The reset takes effect for the *next* message.

```swift
if cappedUsage >= autoThreshold {
    // Fire-and-forget: reset in background, don't block the send
    let resetKey = sessionKey
    delegate?.syncBridge(self, didStartAutoReset: sessionKey)
    Task { @Sendable in
        do {
            let recentMessages = self.fetchLocalHistory(sessionKey: resetKey, limit: 30)
            let ok = try await self.resetSession(sessionKey: resetKey)
            if ok {
                let combinedContext = self.formatCombinedContext(recentMessages, userMessage: "")
                await self.storePendingResetContext(sessionKey: resetKey, context: combinedContext)
                let cooldown = await self.sessionResetManager.config.cooldownMessages
                await self.setResetCooldown(sessionKey: resetKey, count: cooldown)
            }
        } catch {
            print("[SyncBridge] Background auto-reset failed for \(resetKey): \(error)")
        }
        await self.delegate?.syncBridge(self, didStopAutoReset: resetKey)
    }
}
```

**Why this fixes the race condition:**
- The user's message sends immediately (no waiting for reset)
- The gateway processes the reset in the background
- By the time the user sends another message, the reset has either completed or failed
- No window where `chat.send` arrives while gateway is mid-cleanup

**Trade-off:** If the session is near the context limit (≥80%), the current message sends on the un-reset session. The model may truncate or produce a lower-quality response. This is acceptable because:
1. The message still gets through (vs. current behavior: stuck forever)
2. The next message will be on the reset session with fresh context
3. The 80% threshold already has margin before the model errors out

### 4.3 Change 2: Narrow the `sendingSessionKeys` guard to only cover `chatSend`

**File:** `Sources/BeeChatSyncBridge/SyncBridge.swift`  
**Risk:** Low

**Current:** The `sendingSessionKeys` guard spans the entire `sendMessage` function, including the auto-reset. This blocks concurrent sends for 15+ seconds.

**Proposed:** Move the guard to only wrap the `chatSend` call:

```swift
public func sendMessage(sessionKey: String, text: String, ...) async throws -> String {
    // ... abortGeneration (if needed) ...
    // ... auto-reset logic (fire-and-forget, no longer guarded) ...
    // ... topic context injection ...
    
    // Guard only covers the actual send
    guard !sendingSessionKeys.contains(sessionKey) else {
        throw SyncBridgeError.concurrentSendInProgress
    }
    sendingSessionKeys.insert(sessionKey)
    defer { sendingSessionKeys.remove(sessionKey) }
    
    // ... delivery ledger ...
    let runId = try await rpcClient.chatSend(...)
    // ...
}
```

The concurrent-send window shrinks from 15+ seconds to <1 second (just the `chatSend` RPC call).

### 4.4 Change 3: Extend existing stall timer to cover "never started" sends

**File:** `Sources/BeeChatSyncBridge/SyncBridge.swift`  
**Risk:** Low

**Current:** The `streamStallInterval` (30s) only starts AFTER the first delta arrives (via `resetStallTimer` in `processChatDelta`). If no delta ever arrives, no stall timer runs.

**Proposed:** Start the existing stall timer immediately when `chatSend` returns a `runId`. The timer cancels naturally when the first delta arrives (because `resetStallTimer` is called). If no delta arrives within 30 seconds, the existing `clearStalledStream` logic fires.

```swift
// After chatSend returns:
let runId = try await rpcClient.chatSend(...)
try ledgerRepo.updateStatus(idempotencyKey: idempotencyKey, status: .sent, runId: runId)
// Start stall timer immediately — covers "never started" sends
resetStallTimer(for: sessionKey)
return runId
```

No new timer, no new delegate method. Reuses existing 30s stall infrastructure.

### 4.5 Change 4: Add per-call timeout parameter to `GatewayClient.call`

**File:** `Sources/BeeChatGateway/GatewayClient.swift`  
**Risk:** Low

**Current:** `gateway.call` hard-codes `config.requestTimeout` (30s) for all calls.

**Proposed:** Add an optional `timeout` parameter that defaults to `config.requestTimeout`:

```swift
func call(method: String, params: [String: Any], timeout: TimeInterval? = nil) async throws -> [String: Any] {
    let requestTimeout = timeout ?? config.requestTimeout
    // ... rest of existing call logic ...
}
```

The `PendingRequestMap` already supports per-request timeouts — just thread it through. This is a general-purpose improvement useful for other RPC calls that may need different timeouts.

### 4.6 Change 5: Handle `concurrentSendInProgress` in UI

**File:** `Sources/App/UI/` (Composer or ViewModel)  
**Risk:** Low

**Current:** If the user taps "send" while a previous send is still in progress, they get `SyncBridgeError.concurrentSendInProgress`. The message is silently lost.

**Proposed:** With Change 2 (narrowed guard), this error becomes much rarer. But if it does fire:
1. Show a brief toast: "Still sending..."
2. Don't clear the Composer text so the user can retry

---

## 5. Summary of Changes

| # | Change | File | Risk | Rationale |
|---|--------|------|------|-----------|
| 1 | Make auto-reset fire-and-forget (background Task) | SyncBridge.swift | Medium | **Critical fix** — eliminates the race condition entirely |
| 2 | Narrow `sendingSessionKeys` guard to only cover `chatSend` | SyncBridge.swift | Low | Reduces concurrent-send window from 15+s to <1s |
| 3 | Extend existing stall timer to start on `chatSend` return | SyncBridge.swift | Low | Covers "never started" sends; reuses existing 30s infrastructure |
| 4 | Add per-call timeout parameter to `GatewayClient.call` | GatewayClient.swift | Low | General-purpose improvement; future-proofs for other RPC calls |
| 5 | Handle `concurrentSendInProgress` in UI | Composer/ViewModel | Low | Prevents silent message loss |

---

## 6. What This Does NOT Change

- `abortGeneration` logic — already correct
- Auto-reset threshold (80%) — unchanged
- Reset cooldown — unchanged
- Delivery ledger — unchanged
- Topic context injection — unchanged
- Gateway-side cleanup timeout — out of scope (gateway behaviour)
- Tailscale configuration — unrelated to this bug
- Stream stall interval (30s) — unchanged; just started earlier (on chatSend return instead of first delta)

---

## 7. Verification Plan

### 7.1 Functional Tests
1. Send a message on a topic with usage ≥ 80% → verify message gets a response promptly (no 15s delay)
2. Verify the background reset completes and the next message uses fresh context
3. Send a message on a topic with a stuck/zombie session → verify stall timer fires after 30 seconds
4. Tap "send" while previous send is in progress → verify user gets feedback, message not lost

### 7.2 Performance Tests
1. Measure time from "send" tap to first streaming event — should be ≤ 2 seconds even with auto-reset
2. Monitor CPU/memory during background reset — should not affect foreground send

### 7.3 Regression Tests
1. Successful auto-reset still works (usage ≥ 80%, reset succeeds in background, next message uses fresh context)
2. Normal send without auto-reset works (usage < 80%)
3. Concurrent sends to different sessions still work
4. Streaming responses display correctly after auto-reset

---

## 8. Review History

### Round 1 (2026-05-20): Both Q and Kieran gave AMBER

**Key concern from both reviewers:** The original spec's 5-second timeout doesn't fix the race condition — it just reduces the wait time. The zombie PiRun problem persists because `chat.send` arrives while the gateway is still mid-cleanup. The correct fix is fire-and-forget: send the reset in the background and send the user's message immediately.

**Other concerns addressed in revision:**
- Q: `gateway.call` needs a per-call timeout parameter (added as Change 4)
- Q: `sendingSessionKeys` guard too broad (addressed in Change 2)
- Q: 60s stall timer too long, wrong mechanism (replaced with extending existing 30s timer in Change 3)
- Kieran: Gateway log gap is a red herring (acknowledged in §1.3)
- Kieran: 5s timeout creates new race with partial gateway cleanup (eliminated by fire-and-forget)
- Kieran: Two stall timers overlapping (eliminated; now one timer started earlier)

---

## 9. Final Review Checklist

- [ ] **Q (builder):** Verify fire-and-forget reset Task compiles and works
- [ ] **Q (builder):** Verify narrowed `sendingSessionKeys` guard doesn't break concurrent send protection
- [ ] **Q (builder):** Verify existing stall timer starts on `chatSend` return
- [ ] **Q (builder):** Verify `concurrentSendInProgress` UI handling
- [ ] **Kieran (reviewer):** Verify fire-and-forget doesn't introduce new race conditions
- [ ] **Kieran (reviewer):** Verify background reset context is properly stored for next message
- [ ] **Kieran (reviewer):** Verify stall timer doesn't fire prematurely on slow (but working) responses
- [ ] **Bee (verifier):** Test the Beechat Mobile topic end-to-end after fix is applied