# BeeChat v5: Topic Context Persistence

**Spec ID:** BC5-SPEC-004  
**Date:** 2026-05-08 (v3 — final, build-ready)  
**Author:** Bee (coordinator)  
**Reviewers:** Q (implementation), Mel (UX), Kieran (safety)  
**Status:** APPROVED — Ready for Build  
**Priority:** High (core UX improvement)  

---

## Problem Statement

When a user opens BeeChat, the agent has no idea which topic they're in. The topic name is right there in the sidebar, but it never reaches the agent. After a reset or fresh start, the user has to re-state what they're working on.

---

## Solution

On the first message sent in a topic session, BeeChat prepends a one-line context header so the agent knows the topic name. That's it.

No new UI. No new RPC methods. No gateway changes. No database migrations. Just a text prefix on the first message per session.

---

## What Changes

### 1. In-Memory Context Tracking

Add a set to `SyncBridge` that tracks which sessions have already received topic context. Same pattern as existing `resetCooldownCount`.

```swift
private var contextInjectedKeys: Set<String> = []
```

**Lifecycle:**
- Insert on the first `sendMessage` call for a session (unconditionally — whether auto-reset or topic injection ran)
- Remove the key when the session is reset (manual or auto)
- Clear all entries on app launch (natural — in-memory set is empty on restart)

### 2. Context Header Builder

Minimal. Phase 1 only uses the topic name.

```swift
func buildContextHeader(topic: Topic) -> String {
    return "[TOPIC-CONTEXT]\nTopic: \(topic.name)"
}
```

Uses `[TOPIC-CONTEXT]` marker — distinct from auto-reset's `[SESSION-CONTEXT]`.

### 3. sendMessage Modification

Add `topic: Topic? = nil` parameter (default nil, no call-site changes needed). Context injection happens after the auto-reset block, before ledger creation.

```swift
public func sendMessage(sessionKey: String, text: String, thinking: String? = nil, 
                         attachments: [ChatAttachment]? = nil, topic: Topic? = nil) async throws -> String {
    // ... existing concurrency guard ...
    
    var effectiveText = text
    var didAutoReset = false  // local flag for this call only
    
    // ... existing auto-reset + cooldown logic ...
    // (if auto-reset fires: didAutoReset = true, effectiveText gets [SESSION-CONTEXT])
    
    // --- NEW: Topic context injection ---
    if let topic, !contextInjectedKeys.contains(sessionKey) {
        if !didAutoReset {
            let header = buildContextHeader(topic: topic)
            effectiveText = "\(header)\n\n\(effectiveText)"
        }
        // Always insert — whether auto-reset or topic injection provided context.
        // Prevents double-injection on the next call after auto-reset.
        contextInjectedKeys.insert(sessionKey)
    }
    
    // ... existing ledger + chat.send logic (unchanged) ...
}
```

**Key rule:** `contextInjectedKeys.insert(sessionKey)` happens unconditionally on the first `sendMessage` for that session — regardless of whether auto-reset or topic injection provided the context. This prevents the 2nd message after auto-reset incorrectly getting a `[TOPIC-CONTEXT]` header.

**What happens in each scenario:**

| Scenario | Result |
|----------|--------|
| First message in a new topic | `[TOPIC-CONTEXT]` header prepended, key inserted |
| Second message in same topic | Key already in set, no header |
| Auto-reset fires on this call | `[SESSION-CONTEXT]` from auto-reset, key inserted, no `[TOPIC-CONTEXT]` |
| 2nd message after auto-reset (during cooldown) | Key already in set, no header |
| Manual session reset, then send | Key was removed by `resetSession()`, context re-injected ✅ |
| App restart, send in existing topic | Set is empty, context injected on first send ✅ |
| `topic` is nil (non-topic session) | Outer `if let` skips entire block, no header |

### 4. Session Reset Cleanup

Add key removal to `resetSession()` so context is re-injected after both manual and auto resets:

```swift
public func resetSession(sessionKey: String) async throws -> Bool {
    contextInjectedKeys.remove(sessionKey)  // re-inject on next send
    return try await rpcClient.sessionsReset(sessionKey: sessionKey, reason: "new")
}
```

### 5. Update fetchLocalHistory Filter

Add `[TOPIC-CONTEXT]` to the existing exclusion prefixes so auto-reset context reconstruction doesn't re-include topic context headers:

```swift
if content.hasPrefix("[SESSION-CONTEXT]") { return false }
if content.hasPrefix("[SESSION-RESET]") { return false }
if content.hasPrefix("[TOPIC-CONTEXT]") { return false }  // NEW
```

### 6. Feature Flag

Use `UserDefaults` directly (not `@AppStorage` — it doesn't work in an actor context):

```swift
private var isTopicContextEnabled: Bool {
    UserDefaults.standard.object(forKey: "feature_topicContextInjection") as? Bool ?? true
}
```

Wrap the injection block:

```swift
if isTopicContextEnabled, let topic, !contextInjectedKeys.contains(sessionKey) {
    // ... injection logic ...
}
```

Default is `true`. If toggled off mid-session, existing keys in `contextInjectedKeys` prevent re-injection — correct behaviour.

---

## What Does NOT Change

1. **sendMessage call sites** — `topic: Topic? = nil` default, existing callers unchanged
2. **Auto-reset flow** — works exactly as-is, uses `[SESSION-CONTEXT]` marker
3. **Topic model** — no changes in Phase 1 (no new columns, no new structs)
4. **Database** — no migrations in Phase 1
5. **Topic sidebar UI** — no changes
6. **Gateway** — no RPC changes
7. **Telegram topics** — completely unaffected

---

## Caller-Side Change

The UI layer (`ChatView` / `ChatViewModel`) must pass the current `Topic` to `sendMessage`. When the user selects a topic in the sidebar and sends a message, the selected topic is passed as the `topic:` parameter. When sending from a non-topic context (e.g., main session), `topic` remains nil.

This is the only caller-side change needed.

---

## What Is NOT In This Spec (Deferred)

| Feature | Why Deferred |
|---------|-------------|
| `projectPath` column + migration | Phase 1.5 — no UI to set it, always nil |
| `TopicMetadata` struct (`activeFocus`, `tags`) | Phase 1.5 — no UI to set them, always nil |
| Project Folder UI (picker, sidebar icon) | Phase 1.5 — add UI chrome after backend validated |
| Active Focus UI (topic settings) | Phase 1.5 — same |
| Expanded context header (Project:, Focus:, Tags:) | Phase 1.5 — depends on columns/struct above |
| Resume Context button | Phase 2 — low value, context header is sufficient |
| `chat.inject` RPC method | Doesn't exist. Not needed. |
| iOS path abstraction | Address when iOS adaptation begins |

---

## Risk Table

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | `[TOPIC-CONTEXT]` marker confuses agent | Low | Medium | Distinct marker. Test with real conversations before merge. |
| 2 | Context injected on every message | Very Low | Medium | `contextInjectedKeys` set prevents this. |
| 3 | Auto-reset + topic context double injection | Very Low | Medium | Unconditional key insert + `didAutoReset` flag. |
| 4 | `metadataJSON` malformed JSON | N/A | N/A | Not in Phase 1. `buildContextHeader` only uses `topic.name`. |
| 5 | Context header makes agent response robotic | Medium | Medium | Agent convention: use context implicitly, don't acknowledge it. Test before merge. |
| 6 | Feature flag left off by mistake | Very Low | Low | Default `true`. Toggling off is harmless. |

---

## Implementation Steps (Q)

1. Add `contextInjectedKeys: Set<String>` to `SyncBridge`
2. Add `buildContextHeader(topic:)` to `SyncBridge` — returns `[TOPIC-CONTEXT]\nTopic: {name}`
3. Add `topic: Topic? = nil` parameter to `sendMessage`
4. Add `var didAutoReset = false` local flag in `sendMessage`, set to `true` after auto-reset
5. Add context injection block after auto-reset, before ledger creation
6. Add `contextInjectedKeys.remove(sessionKey)` to `resetSession()`
7. Add `[TOPIC-CONTEXT]` to `fetchLocalHistory` filter
8. Add `isTopicContextEnabled` UserDefaults check around injection block
9. Update `ChatView` / `ChatViewModel` to pass current `Topic` to `sendMessage`
10. Write tests (see below)

**Estimated: 0.5–1 day** (reduced from 1.5 — no DB changes, no structs, no migrations)

## Testing (Kieran)

| # | Test | Expected Result |
|---|------|----------------|
| 1 | New topic, first message | `[TOPIC-CONTEXT]` header prepended |
| 2 | Second message in same topic | No header |
| 3 | Auto-reset fires on this call | Only `[SESSION-CONTEXT]`, no `[TOPIC-CONTEXT]`, key inserted |
| 4 | 2nd message after auto-reset (during cooldown) | No header — key was inserted on auto-reset call |
| 5 | Manual session reset, then send with topic | `[TOPIC-CONTEXT]` re-injected (key was removed by reset) |
| 6 | App restart, send in existing topic | Header injected (set empty on launch) |
| 7 | `topic` is nil | No header, no key inserted |
| 8 | Feature flag OFF from app launch | Entire injection block skipped, message sent as-is |
| 9 | Feature flag toggled OFF mid-session | Key already in set, no change to current behaviour |
| 10 | Feature flag toggled ON mid-session | Next send in a new topic gets context; existing topics already have keys |
| 11 | Concurrent sends to different topics | Both get headers independently (different session keys) |
| 12 | `fetchLocalHistory` filter | Messages with `[TOPIC-CONTEXT]` prefix excluded from auto-reset context |
| 13 | `DeliveryLedgerEntry` content | `originalContent` = user input, `content` = effectiveText (with header if present) |

---

## Flow Diagram

```
sendMessage(sessionKey, text, topic: topic?)
  │
  ├─ Auto-reset check (existing)
  │   ├─ If usage > threshold: reset, prepend [SESSION-CONTEXT]
  │   └─ didAutoReset = true
  │
  ├─ Topic context injection (NEW)
  │   └─ If isTopicContextEnabled && let topic && !contextInjectedKeys.contains(sessionKey):
  │       ├─ If !didAutoReset: prepend [TOPIC-CONTEXT] header
  │       └─ Always: insert sessionKey into contextInjectedKeys
  │
  ├─ Ledger entry (existing)
  │
  └─ chat.send RPC (existing)

resetSession(sessionKey)
  │
  └─ contextInjectedKeys.remove(sessionKey)  // re-inject on next send
```

---

## Agent Convention (No Code Change)

When the agent sees `[TOPIC-CONTEXT]` in a user message:

**Use the topic context to inform your response. Do not acknowledge the topic explicitly unless the user asks. Let the relevance of your response demonstrate awareness.**

Good: "The topcon evaluation is progressing — I checked the latest numbers and..."
Bad: "I see you're in the Topcon-Eval topic. How can I help?"

If a `Project:` path is provided (Phase 1.5), read `STATUS.md` or `CONTEXT.md` from that path. Use the topic name for targeted memory/wiki search if needed.

**This convention must be tested with at least 3 real topics and 2 models before merge.**

---

*Approved by Q, Mel, and Kieran on 2026-05-08. Ready for build.*