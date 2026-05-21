# Kieran Reset Context Redesign Review

**Date:** 2026-05-21
**Reviewer:** Kieran
**Status:** Draft for Adam's review
**Subject:** Replace raw message dump with summary-based context injection on session reset

---

## 1. Current State (The Problem)

In `SyncBridge.sendMessage()`, when auto-reset fires at 80% usage:

1. `fetchLocalHistory(sessionKey:, limit: 30)` pulls 30 raw messages from SQLite
2. `formatCombinedContext()` serialises them as:
   ```
   [SESSION-CONTEXT] Continuing from a previous session. Recent conversation:
   User: ...
   Assistant: ...
   ... (30 turns, thousands of characters)
   ```
3. This blob is stored in `pendingResetContext[sessionKey]`
4. On the next `sendMessage()`, it's prepended to the user's message as `effectiveText`
5. Result: massive visible chat bubble, wiped gateway history → white screen UX

**This is the broken path Adam identified.** It works technically (the AI gets context) but is a terrible user experience and wastes tokens.

---

## 2. Gateway API Reality Check

### `chat.send` Parameters (confirmed from gateway source)

```
sessionKey, message, thinking, fastMode, deliver,
originatingChannel, originatingTo, originatingAccountId, originatingThreadId,
attachments, timeoutMs, idempotencyKey,
systemInputProvenance, systemProvenanceReceipt  // admin-only
```

**No `context`, `system`, `prefix`, or `hidden` parameter exists on `chat.send`.** The message is the only content channel. The `systemInputProvenance` field is admin-scoped and carries metadata about routing provenance, not arbitrary context text.

### `chat.inject` RPC

This endpoint **does exist** and is relevant:

```
sessionKey: NonEmptyString
message: NonEmptyString
label: Optional<String (max 100 chars)>
```

It appends an assistant-role message to the transcript with zero token cost (usage shows `input: 0, output: 0`). The `label` parameter prefixes the content with `[label]`. This is used for system-injected assistant messages (e.g., abort notices).

**Assessment:** `chat.inject` is purpose-built for exactly this use case — inserting invisible-to-user context without triggering generation. It's the cleanest injection mechanism available.

### `sessions.reset` RPC

Accepts `key` and `reason` (`"new"` or `"reset"`). Wipes the session transcript. **No pre-reset hook, no callback, no summary parameter.** It's fire-and-reset.

---

## 3. Design Analysis — Answering the Four Questions

### Q1: Who Generates the Summary?

| Option | Feasibility | Pros | Cons |
|--------|-------------|------|------|
| **Gateway RPC** | ❌ Not supported | Clean separation | No RPC endpoint exists for this. Would require a new gateway API. |
| **BeeChat app locally (template-based)** | ✅ High | Zero gateway changes, instant, deterministic, no extra API calls | Less intelligent — template extraction vs. AI understanding |
| **Dedicated agent sub-task** | ⚠️ Possible but overkill | AI-quality summaries | Expensive (costs tokens + latency), requires gateway round-trip before reset, async complexity |

**Recommendation: BeeChat app locally.**

Rationale:
- Adam's Telegram manual summaries are concise, structured, and factual — they don't need AI to generate them. A well-designed template can produce the same output: "What we were discussing, where we left off, what's pending."
- It's instant (no gateway round-trip, no AI cost).
- It doesn't add a new dependency on a gateway API that doesn't exist yet.
- The summary format is deterministic and auditable.
- This matches Adam's own workflow: he writes the summary manually, so a structured extraction from the local DB is functionally equivalent.

**Proposed template approach:**
```swift
func formatSessionSummary(_ recentMessages: [Message]) -> String {
    // Extract key facts from last 30 messages:
    // 1. Topic/subject of discussion
    // 2. Current state of work
    // 3. Any open questions or pending items
    // 4. Key decisions made
    // Format as 2-3 short paragraphs, ~100-200 chars each
}
```

The existing `formatCombinedContext()` is already doing extraction work (filtering system messages, tool calls, prior context dumps). Upgrading this to produce a structured summary instead of raw dump is a contained change.

### Q2: How Is the Summary Injected?

| Option | Feasibility | Pros | Cons |
|--------|-------------|------|------|
| **System message (invisible)** | ❌ Not directly possible | Best UX | No gateway API for hidden context on `chat.send` |
| **`chat.inject` RPC** | ✅ Supported | Invisible to user, zero token cost, purpose-built for this | Requires a separate RPC call after reset, before next send |
| **Visible user message (concise)** | ✅ Works today | Simple, no new code path | User sees the summary in the chat bubble |

**Recommendation: Use `chat.inject` to insert the summary as an assistant message immediately after reset.**

The flow would be:

1. Before reset: fetch last 30 messages, generate summary
2. Call `sessions.reset` (wipes gateway history)
3. Call `chat.inject(sessionKey:, message: summary, label: "Session Summary")` to plant the summary
4. Next user message goes through normally — no prefix needed

This is cleaner than the current `pendingResetContext` approach because:
- The summary lives in the gateway's transcript (not a local-only cache)
- It's invisible to the user (assistant-role message)
- It costs zero tokens (gateway marks injected messages with `totalTokens: 0`)
- No risk of double-injection if the user switches topics

### Q3: When Does the Summary Happen?

**Recommendation: Before reset, applied immediately after reset (atomic sequence).**

Current flow in `sendMessage()` (auto-reset path):
```
usage >= 80% → fire background Task → fetch messages → reset → store pending → next send injects
```

New flow:
```
usage >= 80% → fetch messages → generate summary → reset → inject summary via chat.inject → done
```

Key difference: the summary injection happens **as part of the reset operation**, not deferred to the next `sendMessage()`. This eliminates the `pendingResetContext` cache entirely and removes the "next message gets prefixed" coupling.

**Async consideration:** Since this is currently a fire-and-forget background Task, adding one more RPC call (`chat.inject`) is trivial — it just extends the background work by ~200ms. No user-facing latency impact.

### Q4: Is This a Breaking Change for the Gateway Protocol?

**No.** This is entirely a client-side change:

- `sessions.reset` — unchanged (same RPC, same params)
- `chat.inject` — already exists in the gateway, no changes needed
- `chat.send` — unchanged (no new params needed)
- The `pendingResetContext` cache in `SyncBridge` is internal state — removing it is an internal refactor

The only "protocol" change is that BeeChat starts calling `chat.inject` after resets, which the gateway already supports.

---

## 4. Proposed Implementation

### Step 1: Replace `formatCombinedContext()` with `formatSessionSummary()`

```swift
// New: produces a concise summary instead of raw dump
func formatSessionSummary(_ recentMessages: [Message]) -> String {
    var summary = "[SESSION-SUMMARY] Continuing conversation.\n\n"
    
    // Extract user topics (last N unique topics mentioned)
    // Extract key assistant responses (what was delivered/concluded)
    // Extract open threads (what was left unresolved)
    
    // Format as 2-3 paragraphs:
    // Paragraph 1: What we were working on
    // Paragraph 2: Where we left off
    // Paragraph 3: What's still pending / context to carry forward
    
    return summary
}
```

### Step 2: Add `chat.inject` to the RPC client

```swift
// RPCClient.swift — new method
func chatInject(sessionKey: String, message: String, label: String? = nil) async throws {
    var params: [String: AnyCodable] = [
        "sessionKey": AnyCodable(sessionKey),
        "message": AnyCodable(message)
    ]
    if let label = label {
        params["label"] = AnyCodable(label)
    }
    _ = try await gateway.call(method: "chat.inject", params: params)
}
```

### Step 3: Update the auto-reset flow in `sendMessage()`

```swift
// In the background reset Task:
let summary = formatSessionSummary(recentMessages)
let ok = try await resetSession(sessionKey: resetKey)
if ok {
    try await rpcClient.chatInject(
        sessionKey: resetKey,
        message: summary,
        label: "reset-context"
    )
    // Set cooldown, clear cache — as before
    // NO pendingResetContext needed anymore
}
```

### Step 4: Update `manualReset()` similarly

```swift
public func manualReset(sessionKey: String) async throws -> Bool {
    guard pendingResetContext[sessionKey] == nil else { return true }
    
    if streamingSessionKeys.contains(sessionKey) {
        try? await abortGeneration(sessionKey: sessionKey)
    }
    
    delegate?.syncBridge(self, didStartManualReset: sessionKey)
    
    let recentMessages = try fetchLocalHistory(sessionKey: sessionKey, limit: 30)
    let ok = try await resetSession(sessionKey: sessionKey)
    
    if ok {
        let summary = formatSessionSummary(recentMessages)
        try await rpcClient.chatInject(
            sessionKey: sessionKey,
            message: summary,
            label: "reset-context"
        )
        sessionUsageCache[sessionKey] = 0
    }
    
    delegate?.syncBridge(self, didStopManualReset: sessionKey)
    return ok
}
```

### Step 5: Remove `pendingResetContext`

- Delete `pendingResetContext` dictionary from `SyncBridge`
- Remove the injection logic at the top of `sendMessage()` that checks `pendingResetContext`
- Remove `clearPendingResetContext()` (no longer needed)
- Manual resets no longer need to wait for the next send to carry context

---

## 5. Summary Format Spec

Based on Adam's Telegram manual workflow ("here's where we are, here's what we're doing, here's what's left to do"), the summary should follow this structure:

```
[SESSION-SUMMARY] Continuing conversation from previous session.

We were discussing: <extract main topic from recent user messages>

Progress: <what was accomplished or decided>

Next: <what was left incomplete or asked about>
```

Target length: **150-300 characters total** (vs. current 3000-8000+ character raw dump).

---

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| `chat.inject` unavailable on older gateway | Low | Medium | Feature gate with gateway version check |
| Summary loses important context | Moderate | High | Keep summary to 300 chars; if messages are too complex, fall back to current behaviour |
| Double-injection if reset fires twice | Low | Low | `chat.inject` is idempotent (just adds another assistant message) |
| Manual reset shows two summaries if user sends before auto-reset fires | Low | Low | `pendingResetContext` removal eliminates this race entirely |

---

## 7. Recommendation Summary

1. **Generate summaries locally** in BeeChat (template-based extraction from last 30 messages)
2. **Inject via `chat.inject` RPC** immediately after `sessions.reset` — not as a message prefix
3. **Timing: atomic with reset** — no deferral to next send
4. **Not a breaking change** — uses existing gateway APIs only
5. **Remove `pendingResetContext`** — it's the source of the coupling that makes the current approach fragile

This matches Adam's Telegram workflow exactly: concise summary, injected once, AI brought up to speed, no visible bloat.

---

*Review complete. Open questions for Adam:*
- What level of summarisation detail works best? (3 paragraphs vs. bullet points)
- Should the summary be user-visible in the UI, or completely hidden?
- Any edge cases where raw message dump should still be used as fallback? (e.g., code review sessions with specific file references)
