# Builder's Assessment: Session Reset Context Injection Redesign

**Author:** Q  
**Date:** 2026-05-21  
**Ticket:** Session Reset Context Injection Redesign  
**Review Target:** `/Users/openclaw/Projects/BeeChat-v5/Docs/Reviews/q-reset-context-redesign-2026-05-21.md`

---

## 1. Executive Summary

**Verdict: FEASIBLE** — Can be implemented entirely in the BeeChat-v5 client with **zero gateway API changes**.

The core change is replacing `formatCombinedContext()` (which dumps raw messages into a user-visible payload) with a local summarisation pass that produces a concise 2–3 paragraph summary, then injecting that summary via the existing `chat.inject` RPC method **after** the reset. This eliminates the massive chat bubble / white screen problem and aligns with Adam's Telegram workflow.

**Two implementation options** are assessed below. **Option B (Local Template Summarisation)** is recommended as the MVP — it's fast, deterministic, and requires no AI call. **Option A (AI-Generated Summary)** is a future enhancement.

---

## 2. Current Broken Behaviour

### 2.1 Flow
1. User sends a message (or auto-reset fires at 80% usage).
2. `fetchLocalHistory(sessionKey:limit:)` reads last 30 messages from local SQLite.
3. `formatCombinedContext(_ recentMessages:userMessage:)` concatenates all 30 messages into a single string prefixed with `[SESSION-CONTEXT] Continuing from a previous session...`.
4. This string is stored in `pendingResetContext[sessionKey]`.
5. On the next `sendMessage()`, `pendingResetContext` is prepended to the user's message text.
6. The entire payload (context + user message) is sent via `chat.send` → appears as **one massive user chat bubble** → white screen / UI freeze.

### 2.2 Code Locations
| File | Line / Method | Role |
|------|---------------|------|
| `SyncBridge.swift` | `formatCombinedContext(_:userMessage:)` | Builds the raw dump |
| `SyncBridge.swift` | `pendingResetContext: [String: String]` | Stores context for next send |
| `SyncBridge.swift` | `sendMessage(sessionKey:text:thinking:attachments:topic:)` | Consumes `pendingResetContext` and prepends to user message |
| `SyncBridge.swift` | `manualReset(sessionKey:)` | User-triggered reset flow |
| `SyncBridge.swift` | Auto-reset block (inside `sendMessage`) | Fire-and-forget background reset |
| `RPCClient.swift` | `chatSend(sessionKey:message:idempotencyKey:thinking:attachments:)` | No context/system prefix field |

---

## 3. Gateway Capabilities

### 3.1 Existing RPC Methods

| Method | Params | Purpose |
|--------|--------|---------|
| `sessions.reset` | `key`, `reason` | Resets gateway session, wipes transcript |
| `chat.send` | `sessionKey`, `message`, `idempotencyKey`, `thinking`, `attachments` | Sends user message. **No system/context prefix param.** |
| `chat.inject` | `sessionKey`, `message`, `label?` | **Injects a synthetic assistant message into the transcript** without triggering a model run. Perfect for inserting a summary. |
| `chat.history` | `sessionKey`, `limit?` | Fetches gateway-side transcript |
| `sessions.usage` | `key` | Returns token usage stats |

### 3.2 Key Discovery: `chat.inject`

From gateway source (`chat-DE6J9HvH.js:2448`):

```js
"chat.inject": async ({ params, respond, context }) => {
    const p = params;
    const rawSessionKey = p.sessionKey;
    // ... session lookup ...
    const appended = await appendAssistantTranscriptMessage({
        message: p.message,
        label: p.label,
        sessionId,
        storePath,
        sessionFile: entry?.sessionFile,
        agentId: resolveSessionAgentId({ sessionKey, config: cfg }),
        createIfMissing: true,
        cfg
    });
    // ... broadcasts to chat stream ...
}
```

Schema (`logs-chat.d.ts`):
```typescript
ChatInjectParams: {
    sessionKey: string;
    message: string;
    label?: string;   // optional label for UI
}
```

**What it does:**
- Appends a message to the transcript as if the assistant wrote it.
- Broadcasts a `chat` event with `runId: "inject-<messageId>"` and `state: "final"`.
- **Does NOT trigger a model run.**
- **Does NOT appear as a user message.**

**Why this solves the problem:**
- The summary appears as an assistant message in the chat UI, not a user message.
- It's a normal chat bubble, not a monster concatenated payload.
- It's visible to the AI as part of transcript context on the next user message.

### 3.3 What Does NOT Work

- **`chat.send` extra params:** No `system`, `context`, or `prefix` field exists. The gateway prepends `startupContextPrelude` (daily memory files) internally, but this is not configurable per-request.
- **`sessions.compact`:** This is a gateway-native compaction feature that uses an AI to compress the transcript into a smaller session file. It is **not** what we want here — it replaces the session, doesn't inject a message, and has complex side effects.
- **Modifying gateway source:** Not required. `chat.inject` already provides exactly the mechanism we need.

---

## 4. Design Options

### Option A: AI-Generated Summary (Pre-Reset AI Call)

**Flow:**
1. Before reset, take the last 30 messages.
2. Call `chat.send` with a special prompt: *"Summarise this conversation in 2–3 paragraphs for context carry-forward."*
3. Wait for AI response (respect `SessionResetManager.Config.summaryTimeout = 45s`).
4. Reset session via `sessions.reset`.
5. Inject the AI response via `chat.inject`.
6. Send the user's actual message via `chat.send`.

**Pros:**
- Highest quality summary — captures nuance, decisions, and state.
- Fully automatic — no template maintenance.

**Cons:**
- **Requires an extra AI round-trip** before every reset (manual or auto).
- Adds 1–45 seconds latency to reset flow.
- Costs extra tokens on every reset.
- More complex error handling (what if summary generation fails?).
- For auto-reset (fire-and-forget), we'd need to block or chain the user's next send behind summary generation.

**Verdict:** Overkill for MVP. Better as a v2 enhancement.

---

### Option B: Local Template Summarisation (Recommended)

**Flow:**
1. Before reset, take the last 30 messages from local SQLite.
2. Run a local Swift summariser that extracts:
   - **Topic / goal** from the first few user messages.
   - **Key decisions or outcomes** from assistant messages.
   - **Open questions / next steps** from the tail of the conversation.
3. Format into 2–3 paragraphs (max ~500 chars).
4. Reset session via `sessions.reset`.
5. Inject the summary via `chat.inject` as an assistant message.
6. Send the user's actual message via `chat.send`.

**Summary Template:**
```
[SESSION-SUMMARY]
We're working on: <topic/goal extracted from early messages>

So far: <2-3 key points from assistant responses>

Next up: <open questions or what the user was about to do>
```

**Pros:**
- **Zero latency** — no network call, no AI round-trip.
- **Deterministic** — same input always produces same summary structure.
- **Free** — no token cost.
- **Simple** — pure Swift string processing.
- **Fits Adam's Telegram workflow** — he already writes these manually.

**Cons:**
- Less nuanced than AI summary — but for context carry-forward, "good enough" is the goal.
- Needs careful extraction heuristics (but these are local and tuneable).

**Verdict:** **Recommended for MVP.** Solves the white screen problem immediately.

---

## 5. Implementation Plan

### 5.1 Files to Change

| File | Changes |
|------|---------|
| `SyncBridge.swift` | Replace `formatCombinedContext()` with `formatSessionSummary()`. Restructure reset flow to call `chat.inject` with summary after reset. |
| `RPCClient.swift` | Add `chatInject(sessionKey:message:label:)` method to `RPCClientProtocol` and `RPCClient`. |
| `SessionResetManager.swift` | Potentially add config flag `useSummaryInjection: Bool = true` (optional). |
| `Models/GatewayRPCResponses.swift` | Add `ChatInjectResponse` decoding struct (or reuse existing if generic). |

### 5.2 Detailed Changes

#### A. `RPCClient.swift` — Add `chatInject`

```swift
public protocol RPCClientProtocol {
    // ... existing methods ...
    func chatInject(sessionKey: String, message: String, label: String?) async throws -> String
}

public func chatInject(sessionKey: String, message: String, label: String? = nil) async throws -> String {
    var params: [String: AnyCodable] = [
        "sessionKey": AnyCodable(sessionKey),
        "message": AnyCodable(message)
    ]
    if let label = label {
        params["label"] = AnyCodable(label)
    }
    let response = try await gateway.call(method: "chat.inject", params: params)
    // ... decode ChatInjectResponse ...
    return response.messageId
}
```

#### B. `SyncBridge.swift` — Replace `formatCombinedContext` with `formatSessionSummary`

```swift
func formatSessionSummary(_ recentMessages: [Message]) -> String {
    guard !recentMessages.isEmpty else { return "" }
    
    // Extract topic from first user message(s)
    let topicMessages = recentMessages.prefix(5)
    let topicHint = topicMessages
        .filter { $0.role == "user" }
        .compactMap { $0.content }
        .joined(separator: " ")
        .prefix(200)
    
    // Extract key assistant points
    let assistantPoints = recentMessages
        .filter { $0.role == "assistant" }
        .compactMap { $0.content }
        .filter { !$0.hasPrefix("[") && !$0.hasPrefix("```") }
        .suffix(3)
        .map { String($0.prefix(150)) }
    
    // Extract open questions / next steps from last user message
    let lastUserMessage = recentMessages.last(where: { $0.role == "user" })?.content ?? ""
    
    var paragraphs: [String] = []
    paragraphs.append("We're working on: \(topicHint)")
    
    if !assistantPoints.isEmpty {
        let points = assistantPoints.joined(separator: "; ")
        paragraphs.append("So far: \(points)")
    }
    
    if !lastUserMessage.isEmpty {
        paragraphs.append("Next up: \(String(lastUserMessage.prefix(200)))")
    }
    
    return paragraphs.joined(separator: "\n\n")
}
```

#### C. `SyncBridge.swift` — Restructure Reset Flow

**Current flow (auto-reset):**
```
fire Task → resetSession() → formatCombinedContext() → store in pendingResetContext
→ next sendMessage() prepends context to user message → chat.send
```

**New flow (auto-reset):**
```
fire Task → fetchLocalHistory() → formatSessionSummary()
→ resetSession() → chatInject(summary) → store flag that summary was injected
→ next sendMessage() sends user message normally (no context prepending)
```

**For manual reset:** Same sequence but synchronous (awaited).

#### D. Remove `pendingResetContext` String Prepending

The `pendingResetContext` dictionary currently stores a `String` that gets prepended to the user's message. This is the root cause of the white screen. We should repurpose it (or replace it with a flag) to track only that a reset occurred, not carry raw text.

```swift
// OLD:
private var pendingResetContext: [String: String] = [:]

// NEW:
private var pendingResetSummary: [String: String] = [:]  // still stores summary, but injected via chat.inject
private var resetSummaryInjected: [String: Bool] = [:]  // tracks if inject succeeded
```

### 5.3 Edge Cases

| Case | Handling |
|------|----------|
| Summary > 500 chars | Truncate at sentence boundary, append "..." |
| No messages in history | Skip summary injection, reset silently |
| `chat.inject` fails | Log error, proceed with reset — user just loses summary, not functionality |
| Auto-reset during streaming | Already handled: abort generation first, then reset |
| User sends message during summary injection | Gate with `sendingSessionKeys` or add `isInjectingSummary` flag |
| Multiple rapid resets | `pendingResetContext` guard already prevents double-reset |

---

## 6. Gateway API Changes Required

**None.**

The existing `chat.inject` RPC method provides everything needed. No gateway code changes, no new RPC methods, no protocol version bumps.

---

## 7. Complexity Assessment

| Dimension | Rating | Notes |
|-----------|--------|-------|
| **Code Complexity** | Low | ~100 lines changed in 2 files |
| **Testing Complexity** | Low | Unit test for `formatSessionSummary`, integration test for inject-after-reset |
| **Gateway Changes** | None | Uses existing `chat.inject` |
| **Performance Impact** | Positive | Eliminates huge message payloads |
| **Risk** | Low | If inject fails, graceful degradation |
| **User Impact** | High | Fixes white screen, improves UX dramatically |

**Estimated effort:** 2–4 hours for a Swift developer familiar with the codebase.

---

## 8. Open Questions

1. **Should the summary be visible to the user in the chat UI?**
   - `chat.inject` messages appear as assistant messages — yes, visible. This is desired (Adam's Telegram workflow).
   - If we want it hidden, we'd need gateway changes.

2. **Should we label the injected message?**
   - `chat.inject` accepts an optional `label` — could set `"session-summary"` for UI styling.

3. **Should we keep `formatCombinedContext` as a fallback?**
   - No. Once `chat.inject` is working, the old method is dead code. Remove it.

4. **Do we need to purge old `[SESSION-CONTEXT]` messages from local SQLite?**
   - Not required — `fetchLocalHistory` already filters them out. But a migration to clean them up would be nice.

---

## 9. Recommendation

**Implement Option B (Local Template Summarisation) immediately.**

1. Add `chatInject` to `RPCClient`.
2. Replace `formatCombinedContext` with `formatSessionSummary`.
3. Change reset flow to inject summary via `chat.inject` **after** reset, instead of prepending to user message.
4. Remove `pendingResetContext` string prepending from `sendMessage()`.
5. Test: verify summary appears as assistant message, user message appears normally, no white screen.

**Future enhancement (v2):** Replace template summariser with a lightweight local ML model or a gateway AI call for higher-quality summaries. But only if Adam feels the template summaries are insufficient.

---

## 10. Appendix: Relevant Code Snippets

### 10.1 Current `formatCombinedContext` (Broken)
```swift
func formatCombinedContext(_ recentMessages: [Message], userMessage: String) -> String {
    var lines = ["[SESSION-CONTEXT] Continuing from a previous session. Recent conversation:"]
    var totalChars = lines.joined(separator: "\n").count
    let maxChars = 100_000

    for msg in recentMessages {
        let role = msg.role == "user" ? "User" : "Assistant"
        let content = msg.content ?? ""
        let msgLine = "\(role): \(content)"
        totalChars += msgLine.count + 1
        if totalChars > maxChars {
            lines.append("... [history truncated — context budget exceeded]")
            break
        }
        lines.append(msgLine)
    }

    lines.append("")
    lines.append("The user's latest message follows:")
    lines.append("")
    lines.append(userMessage)
    return lines.joined(separator: "\n")
}
```

### 10.2 `chat.inject` Gateway Implementation
```js
"chat.inject": async ({ params, respond, context }) => {
    const p = params;
    const rawSessionKey = p.sessionKey;
    const { cfg, storePath, entry, canonicalKey: sessionKey } = loadSessionEntry(rawSessionKey);
    const sessionId = entry?.sessionId;
    // ... session lookup ...
    const appended = await appendAssistantTranscriptMessage({
        message: p.message,
        label: p.label,
        sessionId,
        storePath,
        sessionFile: entry?.sessionFile,
        agentId: resolveSessionAgentId({ sessionKey, config: cfg }),
        createIfMissing: true,
        cfg
    });
    // ... broadcasts to chat stream ...
    respond(true, { ok: true, messageId: appended.messageId });
}
```

### 10.3 `chat.inject` Schema
```typescript
ChatInjectParams: {
    sessionKey: string;
    message: string;
    label?: string;
}
```

---

*End of Assessment*
