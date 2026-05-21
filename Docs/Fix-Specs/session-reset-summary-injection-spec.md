# Implementation Spec: Session Reset Context Injection Redesign

**Date:** 2026-05-21  
**Author:** Bee (coordinator)  
**Status:** v0.6 — Kieran blockers addressed, awaiting dual sign-off  
**Reviewers:** Q (builder), Kieran (adversarial reviewer)

---

## 1. Overview

### 1.1 Current Behaviour
When a session hits 80% context usage, `sendMessage()` fires a background auto-reset. The reset:
1. Wipes the session transcript via `sessions.reset`
2. Formats the **last 30 messages as raw text** into a `[SESSION-CONTEXT]` block (up to 100K chars)
3. Stores this block in `pendingResetContext[sessionKey]`
4. On the *next* `sendMessage()`, prepends the block to the user's message text

Problems:
- **Token waste** — raw message dumps consume 5–20K+ tokens of the fresh context window for low-value verbatim history
- **Hidden from user** — the context is injected into the user message, invisible in the chat UI
- **Racy consumption** — `pendingResetContext` is consumed by the next `sendMessage()`, which may be a different topic or arrive late
- **No summarisation** — the AI receives a wall of raw chat logs with no signal about what matters

### 1.2 New Design
Replace the raw dump with a **concise 1–2 paragraph summary** injected via the gateway's `chat.inject` RPC:

1. Fetch local history (SQLite, still available after gateway reset)
2. Generate a short summary: topics discussed, progress/decisions, what's next
3. Call `sessions.reset` (wipes transcript)
4. Call `chat.inject` to insert the summary as an assistant-role message (zero token cost, visible in UI)
5. Update usage cache

No `pendingResetContext` dictionary. No raw dump. No injection into the user message.

---

## 2. API Reference

### 2.1 `chat.inject` (gateway RPC — already exists)

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `sessionKey` | NonEmptyString | ✅ | Target session |
| `message` | NonEmptyString | ✅ | Content to inject |
| `label` | String (max 100 chars) | ❌ | Prefixes content with `[label]` |

Behaviour:
- Appends an **assistant-role** message to the session transcript
- Marked with `totalTokens: 0` — **zero token cost**
- Does **not** trigger an agent run
- The `label` parameter prefixes content: `[label] message text`

### 2.2 `sessions.reset` (gateway RPC — already exists)

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `key` | NonEmptyString | ✅ | Session key to reset |
| `reason` | "new" \| "reset" | ✅ | Reason for reset |

Behaviour:
- Wipes the session transcript
- Returns `{ ok: true }`

---

## 3. Detailed Changes

### 3.1 New Method: `formatSessionSummary()`

**File:** `SyncBridge.swift`  
**Location:** Replace `formatCombinedContext()` entirely

**Signature:**
```swift
func formatSessionSummary(_ recentMessages: [Message]) -> String
```

**Logic:**

1. **Filter** the message list:
   - Exclude messages with `role == "tool"`
   - Exclude messages whose `content` starts with `[SESSION-CONTEXT]`, `[SESSION-RESET]`, `[TOPIC-CONTEXT]`, or `[SESSION-SUMMARY]`
   - Exclude assistant messages containing `[tool_use:`
   - Take the **last 30** messages after filtering (most recent last)

2. **Extract signal:**
   - From **user messages**: extract the primary topic/intent of each message (first sentence or key noun phrase)
   - From **assistant messages**: extract conclusions, decisions, or outcomes (last sentence or definitive statement)
   - Discard messages that are purely procedural ("ok", "done", acknowledgements)

3. **Compose 1–2 short paragraphs** (target 200–400 characters total):
   - **Paragraph 1 — Topics + Progress:** "We were discussing X and Y. Decided on A, completed B, C is still pending." (what the conversation covered + outcomes)
   - **Paragraph 2 — Next steps** (if applicable): "Next: D needs review, E was just started." (what's left)
   - If only one paragraph is needed, that's fine — don't pad.

4. **Hard limits:**
   - Max 400 characters total
   - If < 3 messages or < 50 chars of meaningful content after filtering, return: `"Previous session reset. Brief conversation history available if needed."`
   - **Quality gate:** If the composed summary reads as incoherent fragments (concatenated code blocks, one-word replies, mixed languages), fall back to the minimal string above. A poor summary is worse than no summary.
   - Never include raw message content — only extracted/composed text

5. **Label:** Do NOT prefix the message string with `[SESSION-SUMMARY]`. Use the `label` parameter on `chatInject` instead. The gateway will add `[SESSION-SUMMARY]` automatically. This avoids duplication (`[SESSION-SUMMARY] [SESSION-SUMMARY] text`).

**Example output:**
```
We were discussing the SolarDashboard battery forecast feature and Topcon-Eval strategy. Decided to use Octopus API for real-time pricing; forecast model still needs validation against PVGIS data. Next: Adam to review pricing API results and confirm model accuracy threshold.
```

**Delete:** `formatCombinedContext()` — entirely removed, no fallback.

### 3.2 New RPC Method: `chatInject()`

**File:** `RPCClient.swift`  
**Protocol:** `RPCClientProtocol`  
**Implementation:** `RPCClient`

**Add to protocol:**
```swift
func chatInject(sessionKey: String, message: String, label: String?) async throws -> Bool
```

**Add to `RPCClient` struct:**
```swift
public func chatInject(sessionKey: String, message: String, label: String? = nil) async throws -> Bool {
    var params: [String: AnyCodable] = [
        "sessionKey": AnyCodable(sessionKey),
        "message": AnyCodable(message)
    ]
    if let label {
        params["label"] = AnyCodable(label)
    }
    let response = try await gateway.call(method: "chat.inject", params: params)
    return response["ok"]?.value as? Bool ?? false
}
```

**Error handling:** Throw on gateway transport failure. Return `false` on malformed response (consistent with `sessionsReset` pattern).

**Test targets:** Any `RPCClientProtocol` mock implementations in test targets must also add a `chatInject` stub.

### 3.3 Updated Auto-Reset Flow in `sendMessage()`

**File:** `SyncBridge.swift`  
**Method:** `sendMessage(sessionKey:text:thinking:attachments:topic:)`

**Current flow (to replace):**
```
usage >= 80% → background Task {
    recentMessages = fetchLocalHistory()
    resetSession()
    pendingResetContext[key] = formatCombinedContext(recentMessages)
    update usage cache
}
// Next sendMessage() prepends pendingResetContext to user message
```

**New flow:**
```
usage >= 80% → background Task {
    await streamCompletion(sessionKey)   // Wait for current response to finish (Adam's preference)
    recentMessages = fetchLocalHistory(limit: 30)
    summary = formatSessionSummary(recentMessages)
    resetSession(sessionKey)
    chatInject(sessionKey, summary, label: "SESSION-SUMMARY")
    update usage cache
}
```

**Design decision (Adam's preference):** Wait for any in-flight streaming response to complete before resetting, rather than aborting it. BeeChat is not time-critical — a few seconds wait is preferable to cutting off a response mid-stream.

**Concrete changes in `sendMessage()`:**

1. **Remove** the `pendingResetContext` injection block at the top of `sendMessage()`:
   ```swift
   // DELETE THIS BLOCK:
   if let pendingContext = pendingResetContext.removeValue(forKey: sessionKey) {
       if effectiveText.isEmpty {
           effectiveText = pendingContext
       } else {
           effectiveText = "\(pendingContext)\n\n\(effectiveText)"
       }
       didAutoReset = true  // Reuse flag to skip topic context injection below
   }
   ```

2. **Replace the auto-reset background Task** with the new flow (waits for stream completion + retry logic):
   ```swift
   let resetKey = sessionKey
   delegate?.syncBridge(self, didStartAutoReset: sessionKey)
   Task {
       do {
           // Wait for any in-flight streaming response to finish before resetting
           // (Adam's preference: don't abort, wait for completion)
           if streamingSessionKeys.contains(resetKey) {
               await waitForStreamCompletion(sessionKey: resetKey, timeout: 30)
           }
           
           let recentMessages = try fetchLocalHistory(sessionKey: resetKey, limit: 30)
           let summary = formatSessionSummary(recentMessages)
           let ok = try await resetSession(sessionKey: resetKey)
           
           if ok {
               // Try to inject summary — retry once on failure
               var injectOk = false
               do {
                   injectOk = try await rpcClient.chatInject(
                       sessionKey: resetKey,
                       message: summary,
                       label: "SESSION-SUMMARY"
                   )
               } catch {
                   print("[SyncBridge] chat.inject failed on first attempt: \(error)")
                   try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                   do {
                       injectOk = try await rpcClient.chatInject(
                           sessionKey: resetKey,
                           message: summary,
                           label: "SESSION-SUMMARY"
                       )
                   } catch {
                       print("[SyncBridge] chat.inject failed on retry: \(error)")
                   }
               }
               
               if !injectOk {
                   // KIERAN BLOCKER FIX: Don't silently fail — inject honest recovery message
                   // Also notify UI that context was NOT carried forward
                   let recoveryMessage = "Previous session was reset but context summary could not be restored. Ask the user if they need a recap."
                   try await rpcClient.chatInject(
                       sessionKey: resetKey,
                       message: recoveryMessage,
                       label: "SESSION-SUMMARY"
                   )
                   delegate?.syncBridge(self, didFailSummaryInjection: resetKey)
               }
               
               let cooldown = await sessionResetManager.config.cooldownMessages
               resetCooldownCount[resetKey] = cooldown
               sessionUsageCache[resetKey] = 0
           }
       } catch {
           print("[SyncBridge] Auto-reset with summary injection failed for \(resetKey): \(error)")
       }
       delegate?.syncBridge(self, didStopAutoReset: resetKey)
   }
   ```

3. **Remove the `didAutoReset` flag logic.** Topic context injection should always proceed (no special case for auto-reset). The summary is already in the transcript via `chat.inject`, so there's no conflict.

### 3.4 Updated Manual-Reset Flow

**File:** `SyncBridge.swift`  
**Method:** `manualReset(sessionKey:)`

**Current flow (to replace):**
```
fetchLocalHistory()
resetSession()
pendingResetContext[key] = formatCombinedContext(recentMessages)
update usage cache
```

**New flow:**
```swift
public func manualReset(sessionKey: String) async throws -> Bool {
    // Double-tap guard (replaces pendingResetContext guard)
    guard !manualResetKeys.contains(sessionKey) else {
        print("[SyncBridge] manualReset: already resetting \(sessionKey), skipping")
        return true
    }
    manualResetKeys.insert(sessionKey)
    defer { manualResetKeys.remove(sessionKey) }

    // Wait for any in-flight generation to finish (user explicitly chose to reset, so abort is acceptable)
    if streamingSessionKeys.contains(sessionKey) {
        try? await abortGeneration(sessionKey: sessionKey)
    }

    delegate?.syncBridge(self, didStartManualReset: sessionKey)

    do {
        let recentMessages = try fetchLocalHistory(sessionKey: sessionKey, limit: 30)
        let summary = formatSessionSummary(recentMessages)
        let ok = try await resetSession(sessionKey: sessionKey)

        if ok {
            // Try to inject summary — retry once on failure (same pattern as auto-reset)
            var injectOk = false
            do {
                injectOk = try await rpcClient.chatInject(
                    sessionKey: sessionKey,
                    message: summary,
                    label: "SESSION-SUMMARY"
                )
            } catch {
                print("[SyncBridge] chat.inject failed on first attempt: \(error)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                do {
                    injectOk = try await rpcClient.chatInject(
                        sessionKey: sessionKey,
                        message: summary,
                        label: "SESSION-SUMMARY"
                    )
                } catch {
                    print("[SyncBridge] chat.inject failed on retry: \(error)")
                }
            }
            
            if !injectOk {
                let recoveryMessage = "Previous session was reset but context summary could not be restored. Ask the user if they need a recap."
                try await rpcClient.chatInject(
                    sessionKey: sessionKey,
                    message: recoveryMessage,
                    label: "SESSION-SUMMARY"
                )
                delegate?.syncBridge(self, didFailSummaryInjection: sessionKey)
            }
            
            sessionUsageCache[sessionKey] = 0
        }

        delegate?.syncBridge(self, didStopManualReset: sessionKey)
        return ok
    } catch {
        delegate?.syncBridge(self, didStopManualReset: sessionKey)
        throw error
    }
}
```

### 3.5 Remove `pendingResetContext` Entirely

**File:** `SyncBridge.swift`

**Delete:**
1. Property declaration: `private var pendingResetContext: [String: String] = [:]`
2. Method: `clearPendingResetContext(except:)` — the entire method
3. The `onChange(of: messageViewModel.selectedTopicId)` handler in `MainWindow.swift` that calls `clearPendingResetContext` — remove the entire `.onChange` modifier that references it
4. All references to `pendingResetContext` throughout the codebase

**Add:**
- `private var manualResetKeys: Set<String> = []` — double-tap guard for manual resets (replaces the `pendingResetContext[sessionKey] == nil` guard)

**Add to delegate protocol** (`SyncBridgeDelegate.swift`):
```swift
func syncBridge(_ syncBridge: SyncBridge, didFailSummaryInjection sessionKey: String)
```

**Search command to verify complete removal:**
```bash
grep -rn "pendingResetContext" Sources/
```
Expected result: zero matches.

### 3.6 UI Updates

#### 3.6.1 Reset Indicator Toast (`MainWindow.swift`)

**Current:**
```swift
} else if syncBridgeObserver.showAutoResetToast {
    Text("Session refreshed")
```

**New (success):**
```swift
} else if syncBridgeObserver.showAutoResetToast {
    HStack(spacing: 4) {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.caption2)
        Text("Context carried forward")
            .font(.caption)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial)
    .cornerRadius(8)
    .transition(.opacity)
```

**New (inject failure — KIERAN BLOCKER FIX):**
```swift
} else if syncBridgeObserver.showSummaryInjectionFailedToast {
    HStack(spacing: 4) {
        Image(systemName: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundColor(.orange)
        Text("Session reset — context not restored")
            .font(.caption)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial)
    .cornerRadius(8)
    .transition(.opacity)
```

The icon + "Context carried forward" communicates what actually happened. On failure, "Session reset — context not restored" is honest about what happened.

#### 3.6.2 Manual Reset Alert Text (`ResetSessionAlertModifier`)

**Current message:**
> "The last 30 messages will be carried forward as context for the next reply."

**New message:**
> "A summary of recent conversation will be kept as a reminder. The full history is available in the AI's memory files."

This is honest: we keep a summary, not the raw messages. The AI can still read files if it needs detail.

#### 3.6.3 Auto-Reset Progress Indicator

The existing `"Refreshing context..."` text for `autoResetting` state is still appropriate. Consider changing to:
```
"Summarising context..."
```

This is more accurate — the system is generating a summary, not just refreshing.

#### 3.6.4 SyncBridgeObserver — New State

Add `@Published var showSummaryInjectionFailedToast = false` to `SyncBridgeObserver`.

In the `didFailSummaryInjection` delegate handler:
```swift
func syncBridge(_ syncBridge: SyncBridge, didFailSummaryInjection sessionKey: String) {
    DispatchQueue.main.async {
        self.showSummaryInjectionFailedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            self.showSummaryInjectionFailedToast = false
        }
    }
}
```

---

## 4. Error Handling

### 4.1 `chat.inject` Fails After `sessions.reset` Succeeds

This is the critical failure case: the session transcript is wiped, but the summary never gets injected. The user is left with a blank session and no context.

**Strategy: Retry once, then honest recovery message, then UI notification**

1. **First attempt:** `chatInject()` — if it fails, log and wait 1 second
2. **Retry:** `chatInject()` again — if it fails, log
3. **Recovery:** Inject a minimal honest message: `"Previous session was reset but context summary could not be restored. Ask the user if they need a recap."`
4. **UI notification:** Fire `didFailSummaryInjection` delegate → show "Session reset — context not restored" toast

This ensures the user always knows what happened. No silent failures. No misleading "Context carried forward" when nothing was carried.

**Why we don't fall back to `pendingResetContext`:** That's the system we're removing. It's the source of the white screen and visible dump bugs. No regression.

### 4.2 `sessions.reset` Fails

If reset fails, we don't call `chat.inject` at all. The session continues as-is. This is the same behaviour as today — no change needed.

### 4.3 `fetchLocalHistory` Returns Empty

If there are no messages to summarise, `formatSessionSummary()` returns the minimal fallback:
```
Previous session reset. Brief conversation history available if needed.
```

This is short, honest, and doesn't waste tokens.

### 4.4 Double-Tap Protection for Manual Reset

Replace the `pendingResetContext[sessionKey] == nil` guard with a `manualResetKeys: Set<String>` guard. This prevents overlapping manual resets without relying on the removed dictionary.

### 4.5 Stream Completion Guard in Auto-Reset (KIERAN BLOCKER FIX — revised per Adam)

Manual reset uses `abortGeneration` before resetting. For auto-reset, Kieran flagged that firing `chat.inject` during an active stream could corrupt the transcript.

**Fix (Adam's preference):** Instead of aborting the stream, **wait for it to complete** before resetting. This preserves the user's in-flight response. Add a `waitForStreamCompletion(sessionKey:timeout:)` method that polls `streamingSessionKeys` until the session is no longer streaming, with a 30-second timeout (fallback to abort if timeout expires).

```swift
func waitForStreamCompletion(sessionKey: String, timeout: TimeInterval = 30) async {
    let deadline = Date().addingTimeInterval(timeout)
    while streamingSessionKeys.contains(sessionKey) && Date() < deadline {
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 second
    }
    // Safety net: if still streaming after timeout, abort
    if streamingSessionKeys.contains(sessionKey) {
        try? await abortGeneration(sessionKey: sessionKey)
    }
}
```

This means: normal case — wait a few seconds for the response to finish naturally. Edge case (stream stuck) — abort after 30 seconds as a safety net.

---

## 5. Deleted Code

| Item | File | Lines (approx) | Notes |
|------|------|----------|-------|
| `pendingResetContext` property | `SyncBridge.swift` | ~1 line | Dictionary declaration |
| `formatCombinedContext()` method | `SyncBridge.swift` | ~20 lines | Entire method body |
| `clearPendingResetContext(except:)` method | `SyncBridge.swift` | ~7 lines | Entire method |
| Pending context injection block | `SyncBridge.swift` | ~6 lines | Top of `sendMessage()` |
| `pendingResetContext` write in auto-reset Task | `SyncBridge.swift` | ~1 line | Inside background Task |
| `pendingResetContext` write in `manualReset()` | `SyncBridge.swift` | ~2 lines | Context storage + guard |
| `.onChange(of: selectedTopicId)` clearing context | `MainWindow.swift` | ~5 lines | Topic-switch handler |
| `didAutoReset` flag logic | `SyncBridge.swift` | ~3 lines | Skip topic context on auto-reset |

**Net change:** Removes ~45 lines, adds ~35 lines (summary method, inject call, retry logic, delegate). Plus `chatInject()` RPC method (~12 lines). Plus `manualResetKeys` property (~1 line). Plus `didFailSummaryInjection` delegate (~3 lines). Net reduction of ~5 lines of code, but significantly simpler architecture.

---

## 6. New Code Summary

| Item | File | Type | Notes |
|------|------|------|-------|
| `formatSessionSummary(_:)` | `SyncBridge.swift` | Method | Replaces `formatCombinedContext()` |
| `chatInject(sessionKey:message:label:)` | `RPCClient.swift` | Method | New RPC call |
| `chatInject(sessionKey:message:label:)` | `RPCClientProtocol` | Protocol requirement | New requirement |
| `chatInject(sessionKey:message:label:)` | Test mocks | Stub | Must add to mock implementations |
| `waitForStreamCompletion(sessionKey:timeout:)` | `SyncBridge.swift` | Method | Waits for stream to finish before auto-reset (fallback abort at 30s timeout) |
| `didFailSummaryInjection` | `SyncBridgeDelegate` | Delegate method | UI notification on inject failure |
| `showSummaryInjectionFailedToast` | `SyncBridgeObserver` | Published property | Toast state for failure notification |
| Retry + recovery logic | `SyncBridge.swift` | Inline | Retry `chat.inject` once, then recovery message |

---

## 7. Testing Checklist

### 7.1 Manual Reset (User Triggered)

- [ ] Tap amber dot / context menu → "Reset Session" → confirmation dialog appears with new text
- [ ] Confirm → progress indicator shows "Summarising context..."
- [ ] On success: toast shows "Context carried forward" with icon
- [ ] On inject failure: toast shows "Session reset — context not restored"
- [ ] Session transcript is cleared (fresh conversation)
- [ ] A `[SESSION-SUMMARY]` message appears as the first assistant message in the new session
- [ ] Summary is 200–400 chars, contains topics/decisions/next-steps (not raw logs)
- [ ] User's next message sends normally (no prepended context block)
- [ ] AI acknowledges the summary and continues conversation appropriately
- [ ] Double-tap protection: rapidly tap reset twice → no double injection

### 7.2 Auto-Reset (80% Threshold)

- [ ] Use a session until usage exceeds 80%
- [ ] Send a message → auto-reset triggers in background
- [ ] Message sends immediately (not blocked by reset)
- [ ] Progress indicator shows "Summarising context..."
- [ ] On success: toast shows "Context carried forward"
- [ ] On inject failure: toast shows "Session reset — context not restored"
- [ ] A `[SESSION-SUMMARY]` message appears in the new session
- [ ] AI's response to the sent message references the summary appropriately
- [ ] No `pendingResetContext` is prepended to any message
- [ ] Usage indicator resets to 0 after auto-reset completes
- [ ] Auto-reset waits for any in-flight stream to complete before resetting (up to 30s timeout)
- [ ] If stream doesn't complete within 30s, it's aborted as a safety net

### 7.3 Error Cases

- [ ] **`chat.inject` fails, retry succeeds:** Summary appears after retry
- [ ] **`chat.inject` fails twice, recovery inject succeeds:** Recovery message appears, failure toast shown
- [ ] **`chat.inject` fails twice AND recovery inject fails:** Failure toast shown, session starts fresh with no context — no crash, no misleading success toast
- [ ] **`sessions.reset` fails:** No reset occurs, no injection, session continues normally
- [ ] **`fetchLocalHistory` returns empty:** Minimal fallback summary is injected
- [ ] **Network disconnected during reset:** Error logged, delegate notified, UI returns to normal state

### 7.4 Regression Tests

- [ ] Normal messaging still works (no reset, no injection)
- [ ] Topic context injection still works (new topics get `[TOPIC-CONTEXT]` header)
- [ ] Streaming still works (abortGeneration guard doesn't interfere with normal sends)
- [ ] Message delivery ledger still works (idempotency, retry)
- [ ] Cooldown still works (auto-reset doesn't fire again for N messages after)
- [ ] Multiple rapid sends don't cause duplicate injection
- [ ] Switching topics during auto-reset doesn't corrupt state (no `pendingResetContext` to leak)

### 7.5 Code Hygiene

- [ ] `grep -rn "pendingResetContext" Sources/` returns zero matches
- [ ] `grep -rn "formatCombinedContext" Sources/` returns zero matches
- [ ] `grep -rn "SESSION-CONTEXT" Sources/` returns zero matches (replaced by `SESSION-SUMMARY`)
- [ ] `chatInject` stub exists in any `RPCClientProtocol` mock implementations in test targets
- [ ] No compiler warnings in `SyncBridge.swift`, `RPCClient.swift`, `MainWindow.swift`, `SyncBridgeObserver.swift`, `SyncBridgeDelegate.swift`

---

## 8. Open Questions — RESOLVED

### 8.1 `SessionResetManager.Config.summaryTimeout`

Currently 45 seconds, intended for a planned LLM-based summarisation step. Since `formatSessionSummary()` is local (no LLM call), this timeout is unused.

**Decision:** Remove for now. Add it back when/if LLM summarisation is implemented.

### 8.2 Summary Quality

The current `formatSessionSummary()` is a rule-based extractor (no LLM). This is deliberate:
- **Fast** — no network call, no latency
- **Deterministic** — same input always produces same output
- **Zero cost** — no tokens consumed
- **Quality gate** — if summary is incoherent, fall back to minimal string

If summaries feel too terse or miss important context, we can upgrade to LLM-based summarisation later. The spec is designed so that `formatSessionSummary()` is the only method that changes — the rest of the flow (fetch → summarise → reset → inject) stays identical.

### 8.3 `label` Parameter — DECIDED

Use `label: "SESSION-SUMMARY"` on the `chatInject` call and **do NOT** prefix the message string with `[SESSION-SUMMARY]`. The gateway will prefix it as `[SESSION-SUMMARY] message text` automatically.

This avoids the duplication issue (`[SESSION-SUMMARY] [SESSION-SUMMARY] text`) that would occur if both the label param and the message string contained the prefix.

### 8.4 Topic Context Interaction — DECIDED

After this change, the `didAutoReset` flag logic is removed. Topic context injection (`[TOPIC-CONTEXT]`) will always fire for new topics, regardless of whether a reset happened. This is correct: the summary covers past context, and the topic context tells the AI which topic the user is in. They're complementary, not exclusive.

---

## 9. Implementation Order

1. **Add `chatInject()` to `RPCClientProtocol` and `RPCClient`** — no dependencies, can be tested independently
2. **Add `chatInject` stubs to test target mock implementations**
3. **Add `manualResetKeys` property to `SyncBridge`** — simple, no dependencies
4. **Add `waitForStreamCompletion()` to `SyncBridge`** — polling method with 30s timeout fallback
4. **Add `didFailSummaryInjection` to delegate protocol and observer** — simple, no dependencies
5. **Implement `formatSessionSummary()`** — can be unit-tested with mock message arrays
6. **Update `manualReset()`** — uses new summary + inject flow with retry
7. **Update auto-reset Task in `sendMessage()`** — uses new summary + inject flow with retry + stream completion wait
8. **Delete `pendingResetContext`, `formatCombinedContext()`, `clearPendingResetContext()`** — and all references
9. **Delete `didAutoReset` flag logic** — topic context always proceeds
10. **Update UI text** — toast, alert message, progress indicator, failure toast
11. **Remove `.onChange(of: selectedTopicId)` handler** in `MainWindow.swift` that clears pending context
12. **Remove `summaryTimeout` from `SessionResetManager.Config`** (unused)
13. **Test** — follow checklist in Section 7

---

## 10. Rollback Plan

If the `chat.inject` RPC has issues in production:

1. **Immediate:** Comment out the `chatInject()` call in both auto-reset and manual-reset flows. The reset will still work — just without the summary injection. Sessions will start fresh with no context carry-forward, which is the same as today's behaviour when the raw dump is empty.

2. **Revert:** The entire change can be reverted by restoring `pendingResetContext`, `formatCombinedContext()`, and the injection-at-send logic. The `chatInject()` method in `RPCClient` is harmless to leave in place (unused code).

3. **Partial revert:** Keep the `chat.inject` method but fall back to prepending raw context on inject failure. This is NOT recommended — it reintroduces the hidden-context problem. Prefer option 1.

---

## 11. Kieran Blocker Resolution Log

| Blocker | Resolution | Spec Section |
|---------|-----------|--------------|
| No `abortGeneration` in auto-reset flow | Added stream completion wait before reset in auto-reset Task (Adam prefers waiting over aborting) | 3.3, 4.5 |
| Silent failure on inject error — `try?` swallows all errors | Replaced with retry-once + recovery message + `didFailSummaryInjection` delegate + "Session reset — context not restored" toast | 3.3, 3.4, 3.6.1, 4.1 |
| 150-300 chars too tight for 3 paragraphs | Changed to 200-400 chars, reduced to 1-2 paragraphs | 3.1 |
| Rule-based extraction may produce incoherent summaries | Added quality gate: if summary is incoherent, fall back to minimal string | 3.1 |
| Label duplication (`[SESSION-SUMMARY]` twice) | Decided: use `label` param only, do NOT prefix message string | 3.1, 8.3 |
| Missing test target protocol stub | Added to implementation order and testing checklist | 3.2, 7.5 |