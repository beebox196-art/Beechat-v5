# Session Reset Flow — BeeChat v5

## Overview

When a conversation session reaches ~50% context capacity, a visual indicator (red dot) appears. The user can tap it to trigger a session reset that preserves context through a Bee-generated status summary, then starts a fresh session with that summary injected as the first message.

## Key Design Decisions

**Session identity:** The gateway's `sessions.reset` (with `reason: "new"`) resets the **same session** — it clears conversation history but keeps the same session key (e.g., `telegram:chatId:topic:threadId`). This means:
- **No topic rebinding** — the topic-to-session mapping never changes
- **No subscription management** — same WebSocket, same session, same subscriptions
- **No new session creation** — same key, cleared context

**Summary generation:** Bee writes the summary herself (not LCM compaction), ensuring it accurately reflects recent actions, decisions, and next steps.

**No new gateway endpoints:** The flow uses `chat.send`, `sessions.reset`, and `chat.send` — all existing gateway methods.

## User Flow

1. **Red dot appears** — visual indicator that session context is at ~50% capacity
2. **User taps the red dot** — triggers the reset flow
3. **BeeChat sends a summary request** to the current session
4. **Bee responds with a status summary**
5. **BeeChat captures the response** (listening for the final event)
6. **BeeChat calls `sessions.reset`** with `reason: "new"` — same session key, cleared context
7. **BeeChat injects the summary** as the first message in the reset session
8. **Session continues** with full context awareness

## Detailed Steps

### Step 1: Health Indicator

- BeeChat calls `sessions.usage` to query the current session's context usage
- When usage percentage reaches the configured threshold (default: 50%), a **red dot** appears on the session indicator
- Polling: check on session open, then once per hour. The dot persists until the user resets
- The threshold is deliberately low (50%) — the reset is painless (~15s), so there's no need to push the limit

### Step 2: User Triggers Reset

- User taps the red dot
- No confirmation dialog needed — the red dot is already an intentional action
- Any in-flight messages are discarded

### Step 3: Request Summary

BeeChat sends the following message to the **current** session via `chat.send`:

```
[SESSION-RESET] Please write a status summary for continuing this work in a new session. Include: current task, progress made, decisions, blockers, and next steps. Be thorough — this summary is the only context carried forward.
```

The `[SESSION-RESET]` prefix allows Bee to identify this as a structured request rather than casual conversation.

### Step 4: Bee Generates Summary

- Bee processes the message and responds with a structured summary
- Expected response time: 10-15 seconds (may be longer if Bee uses tools)
- The summary should cover:
  - **Current task:** What are we working on?
  - **Progress:** What's been completed?
  - **Decisions:** Any decisions made that should persist?
  - **Blockers:** Anything stuck or waiting?
  - **Next steps:** What should happen first in the new session?
  - **Key files/refs:** Important paths, URLs, or references
- **Progress indicator:** BeeChat shows "Generating summary..." with a spinner during this step

### Step 5: Capture Summary

- BeeChat listens for the assistant response event with `state == "final"` — the gateway's existing completion signal
- BeeChat accumulates the full streamed response text (reusing existing streaming infrastructure)
- Only after the `final` event does BeeChat consider the summary captured
- If Bee's response is empty or the request times out (45 seconds), show an error and abort the reset

### Step 6: Reset Session

- BeeChat calls `sessions.reset` with params `["key": sessionKey, "reason": "new"]`
- The gateway clears conversation history but **keeps the same session key**
- No subscription changes needed — the same WebSocket connection remains valid
- If this call fails, show an error, stay in current session

### Step 7: Inject Summary

- BeeChat sends the captured summary as the **first message** in the reset session
- Uses `chat.send` with the summary text prefixed:

```
[SESSION-CONTEXT] This is a continuation from a previous session. Summary follows:

{captured summary text}
```

- The `[SESSION-CONTEXT]` prefix signals to Bee that this is inherited context, not a new request
- If sending fails, retry once. If still fails, the user has a fresh session but without the context summary

### Step 8: Continue

- Bee reads the context summary and continues naturally
- The user sees a seamless continuation with no lost information
- The UI updates to show the fresh session (red dot cleared, new message history)

## Edge Cases

| Scenario | Handling |
|----------|----------|
| Summary request times out (45s) | Show error, abort reset, stay in current session |
| Bee responds with partial/truncated message | Use whatever was captured; better partial than nothing |
| `sessions.reset` fails | Show error, stay in current session |
| Summary injection (`chat.send`) fails | Retry once; if still fails, show error — user has fresh session without context |
| User sends another message during reset | Discard — the user initiated the reset and is waiting for it |
| Multiple resets in short succession | Each reset is independent. No stacking of summaries |
| Background message arrives during summary capture | Low risk (BeeChat sessions are user-initiated). If needed, add correlation ID to request/response matching |

## What This Does NOT Do

- Does **not** use LCM compaction (Bee writes the summary herself)
- Does **not** require any new gateway endpoints
- Does **not** create a new session (same session key, cleared context)
- Does **not** change topic-to-session mapping (it stays the same)
- Does **not** require subscription management (same WebSocket, same session)
- Does **not** carry raw conversation history (only the summary)

## Implementation Notes

- Summary request (Step 3) uses `chat.send` — standard message
- Session reset (Step 6) uses `sessions.reset` RPC with `reason: "new"` — **not** the `/new` slash command
- Summary injection (Step 7) uses `chat.send` — `chat.inject` does not exist in the gateway protocol
- Completion detection (Step 5) uses `state == "final"` event — the same mechanism used for all assistant responses
- The red dot threshold uses `sessions.usage` to query real context usage from the gateway
- The `[SESSION-RESET]` and `[SESSION-CONTEXT]` prefixes are text conventions — Bee's system prompt should be updated to recognise them
- Estimated code footprint: ~50-70 lines new Swift code plus UI wiring

## Sequence Diagram

```
User          BeeChat           Gateway (Bee)
  |              |                   |
  |--tap dot---->|                   |
  |              |--chat.send-------->|
  |              |  [SESSION-RESET]   |
  |              |              Bee generates summary
  |              |<--streaming chunks |
  |              |<--event state=final|
  |              |--sessions.reset---->|
  |              |  reason:"new"      |
  |              |<--session reset----|
  |              |  (same session key, cleared context)
  |              |--chat.send-------->|
  |              |  [SESSION-CONTEXT] |
  |              |              Bee reads context, ready
  |<--fresh session, full context---|
```

## Config

```swift
/// Configuration for the session reset flow.
/// Prefix strings are protocol conventions — update Bee's system prompt to match.
static let summaryRequestPrefix = "[SESSION-RESET]"
static let contextInjectionPrefix = "[SESSION-CONTEXT]"

struct SessionResetConfig {
    /// Context usage percentage that triggers the red dot indicator.
    /// Default 50% — reset is painless, so early warning is better.
    var redDotThreshold: Double = 0.50
    
    /// Maximum wait time for Bee's summary response (seconds).
    /// 45s to account for possible tool use during summary generation.
    var summaryTimeout: TimeInterval = 45
    
    /// Whether to show a confirmation dialog before reset.
    /// Default false — the red dot is already an intentional action.
    var showConfirmation: Bool = false
}
```