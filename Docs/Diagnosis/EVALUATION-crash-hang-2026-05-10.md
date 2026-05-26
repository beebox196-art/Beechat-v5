# BeeChat Crash & Hang Evaluation Spec

**Date:** 2026-05-10  
**Author:** Bee (initial analysis) → Team Review  
**Status:** DRAFT — Pending team review before any code changes  
**Severity:** P1 (app unusable — crash + hang)

---

## 1. Executive Summary

Two distinct bugs affect BeeChat v5:

1. **Crash bug (reproduced May 3):** `CheckedContinuation` double-resume in `GatewayClient.call()` causes `EXC_BREAKPOINT` / `SIGTRAP` — instant app termination.
2. **Hang bug (active May 10):** Streaming state machine drops events when session keys don't match the active topic, causing 99% CPU spin and unresponsive UI (beachball).

Both require separate fixes. Both have non-obvious side effects that need careful consideration.

---

## 2. Evidence

### 2.1 Crash Bug

**Source:** `~/Library/Logs/DiagnosticReports/BeeChatApp-2026-05-03-024902.ips`

- **Exception type:** `EXC_BREAKPOINT` (SIGTRAP) — Swift runtime assertion
- **Faulting thread:** Thread 2 (`com.apple.root.user-initiated-qos.cooperative`)
- **Stack trace (key frames):**

```
_assertionFailure(_:_:file:line:flags:)          ← Swift assertion
CheckedContinuation.resume(throwing:)              ← Swifty async continuation
closure #1 in closure #1 in GatewayClient.call()  ← Line 148 of GatewayClient.swift
```

- **Root cause:** `CheckedContinuation.resume(returning:)` or `.resume(throwing:)` called twice on the same continuation. Swift's `withCheckedThrowingContinuation` traps on double-resume.

### 2.2 Hang Bug

**Source:** Desktop diagnostic log (`BeeChat-diagnostics.log`) — live at time of report

**Key log patterns observed:**

```
[16:36:35.919] Thinking timeout — auto-resetting to idle (didStartStreaming never fired within 60s)
[16:36:52.590] didStopStreaming — GUARD SKIPPED (incoming=agent:main:be8d141c current=agent:main:491ea8d6)
[16:38:31.013] Thinking timeout — auto-resetting to idle
```

**Pattern:** Every cron job and subagent message arrives with a different session key than the active topic. The `didStartStreaming` guard sees "mismatch" and returns early without transitioning the state. The `didStopStreaming` guard also returns early. Net result: the UI never shows the streaming response, and the thinking timeout fires repeatedly.

**CPU at time of report:** 99.6% on main process (beachball).

**Last diagnostic entry:** 16:39:05 — after this, the app stopped producing log output entirely (hung).

---

## 3. Technical Root Cause Analysis

### 3.1 Bug A: CheckedContinuation Double-Resume

**Location:** `GatewayClient.swift`, method `call(method:params:)`, lines ~120–155

**Current code flow:**

```swift
return try await withCheckedThrowingContinuation { continuation in
    Task {
        await pendingRequests.add(id: id, timeout: config.requestTimeout, resolve: { payload in
            continuation.resume(returning: payload)  // ← RESUME POINT 1
        }, reject: { error in
            continuation.resume(throwing: error)      // ← RESUME POINT 2
        })
        
        do {
            let data = try JSONEncoder().encode(frame)
            // ... send to transport ...
        } catch {
            await pendingRequests.remove(id: id, reason: error.localizedDescription)
            continuation.resume(throwing: error)      // ← RESUME POINT 3 (BUG)
        }
    }
}
```

**How the double-resume happens:**

1. `pendingRequests.add()` registers the resolve/reject callbacks AND starts a timeout timer
2. If the timeout fires *before* the transport send completes, `pendingRequests.remove()` calls the `reject` callback, which calls `continuation.resume(throwing:)` → **first resume**
3. The `catch` block then also calls `await pendingRequests.remove(id:reason:)` — but `remove` finds the entry already gone (it was removed by the timeout) and returns silently. The code then falls through to `continuation.resume(throwing:)` → **second resume** → CRASH

The same pattern exists for the UTF-8 encoding error path: if encoding succeeds but transport fails after the timeout has already rejected, both the timeout reject and the catch block try to resume.

**Key insight:** `pendingRequests.remove()` removes the entry and returns void. It does NOT signal "I already handled this continuation." The caller has no way to know whether the continuation was already resumed.

### 3.2 Bug B: Streaming State Machine — Session Key Mismatch Guard

**Location:** `SyncBridgeObserver.swift`, methods `didStartStreaming` and `didStopStreaming`

**Current logic (simplified):**

```swift
func didStartStreaming(sessionKey: String) {
    let normalizedIncoming = normalizedSessionKey(sessionKey)
    let normalizedCurrent = normalizedSessionKey(currentSelectedSessionKey)
    
    if normalizedIncoming != normalizedCurrent {
        unreadCounts[normalizedIncoming, default: 0] += 1  // count as unread
        return  // ← EARLY RETURN: never transition state
    }
    
    cancelThinkingTimeout()
    thinkingState = .streaming
    // ...
}
```

**The problem:**

- When the user is on topic X and a cron job (or subagent) streams on session Y, `didStartStreaming` correctly identifies the mismatch and returns early
- But `didStopStreaming` also returns early on mismatch — so the stream-end event is silently dropped
- Meanwhile, the thinking timeout fires (60s default), resetting to idle
- If multiple streams overlap (common with cron jobs every 5 mins), the state machine never stabilises for the *active* topic

**Additional issue:** The `onMessageSent` callback always sets `thinkingState = .thinking` and starts a thinking timeout, but if the response comes back on a different session key (e.g. the gateway assigns a new run ID), the `didStartStreaming` guard will mismatch and the thinking state will timeout instead of transitioning.

**The 99% CPU** is likely caused by the `streamingPoll` task running in a tight loop when state is stuck — `startStreamingPoll()` uses 50ms sleeps, but if `isStreaming` is stuck `true` or the task isn't properly cancelled during resets, it can accumulate.

---

## 4. Proposed Fixes

### 4.1 Fix A: GatewayClient Double-Resume Guard

**Approach:** Add a `hasResumed` flag to prevent double-resume, OR restructure so that `pendingRequests.remove()` signals whether it already resolved/rejected the continuation.

**Option A1 — Boolean guard (minimal change):**

```swift
public func call(method: String, params: [String: AnyCodable]? = nil) async throws -> [String: AnyCodable] {
    guard state == .connected else { ... }
    
    let id = "bc-\(nextRequestId)"
    nextRequestId += 1
    let frame = RequestFrame(id: id, method: method, params: params)
    
    return try await withCheckedThrowingContinuation { continuation in
        var hasResumed = false  // ← NEW: guard against double-resume
        
        Task {
            await pendingRequests.add(id: id, timeout: config.requestTimeout, resolve: { payload in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: payload)
            }, reject: { error in
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(throwing: error)
            })
            
            do {
                let data = try JSONEncoder().encode(frame)
                guard let text = String(data: data, encoding: .utf8) else {
                    let error = NSError(domain: "GatewayClient", code: -3, ...)
                    await pendingRequests.remove(id: id, reason: error.localizedDescription)
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(throwing: error)
                    return
                }
                try await transport.send(text)
            } catch {
                await pendingRequests.remove(id: id, reason: error.localizedDescription)
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(throwing: error)
            }
        }
    }
}
```

**Option A2 — Return-value signal from PendingRequestMap:**

Change `remove()` to return a `Bool` indicating whether the entry was found and its callback was invoked:

```swift
@discardableResult
public func remove(id: String, reason: String) -> Bool {
    if let req = pending.removeValue(forKey: id) {
        req.timer.cancel()
        req.reject(...)
        return true  // ← We resumed the continuation
    }
    return false  // ← Entry already removed; continuation already resumed
}
```

Then in `call()`:

```swift
} catch {
    let alreadyHandled = await pendingRequests.remove(id: id, reason: ...)
    if !alreadyHandled {
        continuation.resume(throwing: error)
    }
}
```

**Recommendation:** Option A1 is simpler and more defensive. Option A2 is cleaner but requires more care that every call site checks the return value. **A1 is preferred for safety.**

**⚠️ Side effects to evaluate:**
- If a timeout fires and the continuation is already resumed via `resolve`, the timeout's `reject` call must also be guarded. With `hasResumed`, this is handled — the reject callback will see `hasResumed == true` and return silently.
- The `disconnect()` method calls `pendingRequests.clearAll()` which rejects all pending requests. If a `call()` is in-flight during disconnect, both `clearAll` and the in-flight catch block could try to resume. The `hasResumed` guard prevents this.

### 4.2 Fix B: Streaming State Machine — Session Key Mismatch

**Approach:** Separate "which session is streaming" from "should the UI show streaming." The current code conflates two concerns: (a) tracking which sessions are active, and (b) updating the UI for the currently-selected topic.

**Option B1 — Always track streaming, conditionally update UI:**

```swift
func didStartStreaming(sessionKey: String) {
    // Always track streaming session (for agent activity, unread counts, etc.)
    agentActivityTracker.didStartStreaming(sessionKey: sessionKey)
    
    let normalizedIncoming = normalizedSessionKey(sessionKey)
    let normalizedCurrent = currentSelectedSessionKey.map(normalizedSessionKey)
    
    if normalizedIncoming != normalizedCurrent {
        // Not the active topic — count as unread, but DON'T return early
        unreadCounts[normalizedIncoming, default: 0] += 1
        // Still update isStreaming/streamingSessionKey if nothing else is streaming
        // This prevents stale state if the user later switches to this topic
        if !isStreaming {
            streamingSessionKey = sessionKey
            // Don't set thinkingState here — it's for the visible topic only
        }
        return
    }
    
    // Active topic streaming — full UI transition
    cancelThinkingTimeout()
    thinkingState = .streaming
    isStreaming = true
    streamingSessionKey = sessionKey
    startStreamingPoll()
    startStreamingTimeout()
}

func didStopStreaming(sessionKey: String) {
    agentActivityTracker.didStopStreaming(sessionKey: sessionKey)
    
    let normalizedIncoming = normalizedSessionKey(sessionKey)
    let normalizedCurrent = currentSelectedSessionKey.map(normalizedSessionKey)
    
    // Always clear streaming state if this was the streaming session
    // (even if it's not the currently-selected topic)
    if normalizedSessionKey(streamingSessionKey ?? "") == normalizedIncoming {
        resetStreamingState()
    }
}
```

**Option B2 — Track multiple concurrent streams:**

Use a dictionary `Set<String>` of active streaming session keys instead of a single `streamingSessionKey`. This is more correct but requires more UI changes (e.g., showing streaming indicators per-topic in the sidebar).

**Recommendation:** Option B1 is the minimal fix that prevents the hang while preserving current behaviour for the active topic. B2 is a better long-term architecture but is a larger change.

**⚠️ Side effects to evaluate:**
- With B1, when the user switches topics, `sidebarSelection`'s setter updates `currentSelectedSessionKey`. If a stream is active on the newly-selected topic, `didStartStreaming` should have already set `streamingContent` and the poll task should be running. **Need to verify:** does switching topics re-trigger the observation, or does it rely on `didStartStreaming` having already fired? If the stream started *before* the user switched to that topic, the poll task may not be running for that session key.
- The `startStreamingPoll()` method polls `streamingContent(for:)` using `streamingSessionKey`. If we set `streamingSessionKey` for a background topic (Option B1's "if !isStreaming" path), switching to that topic won't restart the poll because `isStreaming` is still `false`. **Fix:** When the user switches topics, check if the new topic is in the streaming set and restart the poll.
- The `thinkingTimeoutTask` is only cancelled for the active topic. Background topics don't get a thinking timeout, which is correct — but if a background stream ends without `didStopStreaming` (network drop), `isStreaming` could stay `true`. The `streamingTimeoutTask` (90s) should still fire and clean up.

### 4.3 Fix C: Streaming Poll CPU Spin (Contributing to 99% CPU)

**Current code:** `startStreamingPoll()` polls every 50ms with `Task.sleep`. If `resetStreamingState()` doesn't properly cancel the task, or if `isStreaming` gets stuck `true`, the poll runs indefinitely.

**Recommended addition:**

```swift
private func startStreamingPoll() {
    stopStreamingPoll()  // Ensure no duplicate polls
    streamingPollTask = Task { [weak self] in
        while !Task.isCancelled {
            guard let self, self.isStreaming else { return }  // ← EXIT if not streaming
            if let bridge = self.syncBridge {
                let content = await bridge.streamingContent(for: self.streamingSessionKey ?? "")
                self.streamingContent = content
            }
            do {
                try await Task.sleep(nanoseconds: 50_000_000)
            } catch {
                return
            }
        }
    }
}
```

**Key change:** The `guard self.isStreaming` check ensures the poll terminates when streaming state is reset, even if `stopStreamingPoll()` isn't called (e.g., race condition during reset).

---

## 5. Risk Assessment

| Change | Risk | Mitigation |
|--------|------|------------|
| A1: hasResumed guard | **Low** — additive safety net, no behavioural change if not double-resuming | N/A |
| A2: remove() return value | **Medium** — every call site must check; missing a check reintroduces the bug | Audit all callers |
| B1: Conditional streaming update | **Medium** — could change when streaming indicator appears; topic switching may need adjustment | Test all topic-switch scenarios with concurrent streams |
| B2: Multi-stream tracking | **High** — significant refactor; sidebar UI changes; new state management | Defer to next sprint |
| C: Poll guard | **Low** — defensive check; existing cancellation path unchanged | N/A |

---

## 6. Testing Checklist

### Crash Bug (Fix A)

- [ ] **A-CRASH-1:** App does not crash when WebSocket disconnects during an active `call()` request
- [ ] **A-CRASH-2:** App does not crash when `call()` timeout fires simultaneously with transport error
- [ ] **A-CRASH-3:** App does not crash when `disconnect()` is called while `call()` is in-flight
- [ ] **A-CRASH-4:** Normal `call()` → resolve path still works (continuation resumes with payload)
- [ ] **A-CRASH-5:** Normal `call()` → reject path still works (continuation resumes with error)
- [ ] **A-EDGE-1:** Rapid connect/disconnect cycles don't leak continuations or crash

### Hang Bug (Fix B)

- [ ] **B-HANG-1:** App remains responsive when multiple cron jobs stream simultaneously
- [ ] **B-HANG-2:** Switching to a topic that is currently streaming shows the streaming content
- [ ] **B-HANG-3:** Switching away from a streaming topic does not leave the app in a stuck state
- [ ] **B-HANG-4:** Thinking timeout (60s) correctly resets to idle when no streaming starts
- [ ] **B-HANG-5:** Streaming timeout (90s) correctly resets when `didStopStreaming` never fires
- [ ] **B-HANG-6:** CPU usage returns to baseline when no streaming is active
- [ ] **B-HANG-7:** Unread counts still increment for background topics
- [ ] **B-HANG-8:** Agent activity tracker still updates for all sessions (foreground and background)

### Poll Guard (Fix C)

- [ ] **C-POLL-1:** Streaming poll terminates within 100ms of `isStreaming = false`
- [ ] **C-POLL-2:** No duplicate poll tasks after rapid start/stop cycling
- [ ] **C-POLL-3:** Memory usage stable over 30+ minutes of active streaming

---

## 7. Recommended Implementation Order

1. **Fix A (hasResumed guard)** — Lowest risk, prevents crash, no behavioural change
2. **Fix C (poll guard)** — Low risk, prevents CPU spin
3. **Fix B1 (conditional streaming update)** — Medium risk, prevents hang, needs thorough topic-switch testing
4. **Fix B2 (multi-stream tracking)** — Defer; architectural improvement for vNext

---

## 8. Files Affected

| File | Changes |
|------|---------|
| `Sources/BeeChatGateway/GatewayClient.swift` | Fix A: `call()` method — add `hasResumed` guard |
| `Sources/App/UI/Observers/SyncBridgeObserver.swift` | Fix B: `didStartStreaming` / `didStopStreaming` — conditional update + poll guard |
| `Sources/App/UI/MainWindow.swift` | Fix B: `sidebarSelection` setter — restart poll on topic switch if streaming |

---

## 9. Out of Scope (For Reference)

- `connect()` method's `handshakeContinuationResumed` guard — already has the pattern we're adding to `call()` (good)
- `PendingRequestMap` actor — `remove()` and `resolve/reject` already use `removeValue` which is atomic per entry. No change needed.
- Main thread UI responsiveness — the diagnostic log shows all UI updates happen on `@MainActor`. The hang is a state machine issue, not a threading issue.

---

*This evaluation is for team review. No code changes should be made until all reviewers sign off.*