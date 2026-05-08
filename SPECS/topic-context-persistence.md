# BeeChat v5: Topic Context Persistence

**Spec ID:** BC5-SPEC-004  
**Date:** 2026-05-08 (v2 — revised after team review)  
**Author:** Bee (coordinator)  
**Reviewers:** Q (implementation), Mel (UX), Kieran (safety)  
**Status:** DRAFT v2 — Second Review  
**Priority:** High (core UX improvement)  

---

## Problem Statement

When a user opens BeeChat, the agent has no idea which topic they're in. Even though sessions persist, after a reset or fresh start the agent wakes up with zero topic awareness. The user has to re-state what they're working on every time.

BeeChat already has topic names in the sidebar. The agent just never sees them.

---

## Solution

**Phase 1 only.** When the user sends the first message in a topic session, BeeChat prepends a short context header so the agent knows what topic it's in. That's it.

No new UI. No new RPC methods. No gateway changes. Just a text prefix on the first message of each topic session.

---

## What Changes

### 1. Database Migration — Add `projectPath` to Topic

Additive column. Nil default. No data loss.

```swift
migrator.registerMigration("Migration012_AddProjectPath") { db in
    try db.alter(table: "topics") { t in
        t.add(column: "projectPath", .text)
    }
}
```

Update `Topic.upsertColumns` to include `Column("projectPath")`.

### 2. TopicMetadata Struct

For structured `metadataJSON` parsing. Uses `try?` decode — returns nil on malformed JSON, never crashes.

```swift
struct TopicMetadata: Codable {
    var activeFocus: String?
    var tags: [String]?
}

extension Topic {
    var parsedMetadata: TopicMetadata? {
        guard let json = metadataJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TopicMetadata.self, from: data)
    }
}
```

### 3. In-Memory Context Tracking

In `SyncBridge`, add a set to track which sessions have already been handled. Same pattern as existing `resetCooldownCount`.

```swift
private var contextInjectedKeys: Set<String> = []
```

- Insert on the first `sendMessage` call for a session (unconditionally — whether topic context or auto-reset provided the context)
- Never remove entries — once a session has been handled, it shouldn't get `[TOPIC-CONTEXT]` again until app restart
- Empty on app launch → context is always injected on first send after restart (correct behaviour)

**Why never remove?** App restart clears the set. There's no mid-session scenario where re-injecting topic context adds value — the agent already knows the topic.

### 4. Context Header Builder

Pure function. Uses `[TOPIC-CONTEXT]` marker (distinct from auto-reset's `[SESSION-CONTEXT]`).

```swift
func buildContextHeader(topic: Topic) -> String {
    var lines = ["[TOPIC-CONTEXT]"]
    lines.append("Topic: \(topic.name)")
    
    if let projectPath = topic.projectPath {
        lines.append("Project: \(projectPath)")
    }
    
    if let metadata = topic.parsedMetadata {
        if let focus = metadata.activeFocus {
            lines.append("Active Focus: \(focus)")
        }
        if let tags = metadata.tags, !tags.isEmpty {
            lines.append("Tags: \(tags.joined(separator: ", "))")
        }
    }
    
    return lines.joined(separator: "\n")
}
```

### 5. sendMessage Modification

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
    // Mark session as context-aware regardless of path taken.
    // This prevents double-injection on the next call after auto-reset.
    if topic != nil && !contextInjectedKeys.contains(sessionKey) {
        if !didAutoReset {
            let header = buildContextHeader(topic: topic!)
            effectiveText = "\(header)\n\n\(effectiveText)"
        }
        // Always insert — whether we injected topic context OR auto-reset ran.
        // Either way, the agent now has context and shouldn't receive [TOPIC-CONTEXT] again.
        contextInjectedKeys.insert(sessionKey)
    }
    
    // ... existing ledger + chat.send logic (unchanged) ...
}
```

**Key rule:** `contextInjectedKeys.insert(sessionKey)` happens unconditionally on the first `sendMessage` for that session — regardless of whether auto-reset or topic injection provided the context. This prevents the 2nd message after auto-reset incorrectly getting a `[TOPIC-CONTEXT]` header.

**What happens in each scenario:**
- First message in a new topic → `[TOPIC-CONTEXT]` header prepended, key inserted ✅
- Continuing an existing session → key already in set, no header ✅
- After auto-reset → `[SESSION-CONTEXT]` from auto-reset, key inserted (no `[TOPIC-CONTEXT]`) ✅
- 2nd message after auto-reset → key already in set, no header ✅
- After app restart → `contextInjectedKeys` is empty, context injected on first send ✅

### 6. Update fetchLocalHistory Filter

Add `[TOPIC-CONTEXT]` to the existing exclusion prefixes so auto-reset context reconstruction doesn't re-include topic context headers from old messages:

```swift
if content.hasPrefix("[SESSION-CONTEXT]") { return false }
if content.hasPrefix("[SESSION-RESET]") { return false }
if content.hasPrefix("[TOPIC-CONTEXT]") { return false }  // NEW
```

### 7. Feature Flag

```swift
@AppStorage("feature_topicContextInjection") 
static var topicContextInjection: Bool = true
```

When `false`, the entire context injection block is skipped. Default `true`.

---

## What Does NOT Change

1. **sendMessage call sites** — `topic: Topic? = nil` has a default, existing callers work unchanged
2. **Auto-reset flow** — keeps working exactly as-is, uses `[SESSION-CONTEXT]` marker
3. **Session creation/resumption** — same `chat.send` path
4. **Topic sidebar UI** — no changes in Phase 1
5. **New topic sheet** — no new fields in Phase 1
6. **Gateway** — no RPC changes, no new methods
7. **Telegram topics** — completely unaffected, own session binding

---

## What Is NOT In This Spec (Deferred)

| Feature | Why Deferred |
|---------|-------------|
| Project Folder UI (picker, sidebar icon) | Phase 1.5 — add UI chrome after backend is validated |
| Active Focus UI (topic settings) | Phase 1.5 — same reason |
| Resume Context button | Phase 2 — low value, context header is sufficient for agent orientation |
| `chat.inject` RPC method | Doesn't exist in RPCClient. Not needed for Phase 1. |
| iOS path abstraction | Phase 1 has no UI for `projectPath`. Address when iOS adaptation begins. |

---

## Risk Table

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | `[TOPIC-CONTEXT]` marker confuses agent | Low | Medium | Distinct marker from `[SESSION-CONTEXT]`. Test with multiple models before merge. |
| 2 | Context injected on every message | Very Low | Medium | `contextInjectedKeys` set prevents this. Cleared on reset. |
| 3 | Auto-reset + topic context double injection | Low | Medium | Injection only runs if auto-reset did NOT fire for this call. `contextInjectedKeys` set prevents repeat. |
| 4 | Database migration failure | Very Low | Medium | Additive migration, nil default. Add test for v6→v7 path. |
| 5 | `metadataJSON` malformed JSON | Low | Low | `try?` decode returns nil gracefully. Header omits activeFocus/tags. |
| 6 | Context header exposes filesystem path | Low | Low | Path is part of user message to gateway. Agent has file access anyway. |
| 7 | `projectPath` is macOS-only | Low (future) | Medium (future) | Phase 1 has no UI for it. Document as macOS-only. Address for iOS adaptation. |
| 8 | Feature flag left off by mistake | Very Low | Low | Default is `true`. If off, agent just doesn't get topic context — no crash, no breakage. |

---

## Implementation Steps (Q)

1. Add `projectPath` column to `Topic` model + migration + `upsertColumns` update
2. Define `TopicMetadata` struct + `parsedMetadata` computed property
3. Add `contextInjectedKeys: Set<String>` to `SyncBridge`
4. Add `buildContextHeader(topic:)` to `SyncBridge`
5. Add `topic: Topic? = nil` parameter to `sendMessage`
6. Add context injection block after auto-reset, before ledger creation
7. Add `[TOPIC-CONTEXT]` to `fetchLocalHistory` filter
8. Add feature flag check around injection block
9. Never remove entries from `contextInjectedKeys` — app restart clears it, which is sufficient
10. Write migration test (v6→v7)

**Estimated: 1–1.5 days**

## Testing (Kieran)

| Test | Expected Result |
|------|----------------|
| New topic, first message | `[TOPIC-CONTEXT]` header prepended |
| Second message in same topic | No header |
| After auto-reset | Only `[SESSION-CONTEXT]` (from auto-reset), no `[TOPIC-CONTEXT]` |
| After auto-reset, next normal send | No header — key was inserted during the auto-reset call |
| Topic with no project path | Header has `Topic: <name>` only |
| Topic with project path | Header has `Topic:` + `Project:` lines |
| Malformed `metadataJSON` | Header omits activeFocus/tags, no crash |
| App restart, send in existing topic | Header injected (`contextInjectedKeys` empty on launch) |
| 2nd message after auto-reset (during cooldown) | No header — key was inserted on the auto-reset call |
| Concurrent sends to different topics | Both get headers independently (different session keys) |
| Topic with valid JSON but wrong schema (`{"color":"blue"}`) | Header omits focus/tags, no crash |
| Feature flag toggled mid-session | No double injection — key already in set |
| Caller passes topic where `topic.sessionKey != sessionKey` | Injection fires for the wrong topic — caller must ensure match |
| `DeliveryLedgerEntry.originalContent` | Stores `text` (user input), `content` stores `effectiveText` (with header) — correct |
| DB migration from v6 | App launches, topics load, `projectPath` is nil |
| `fetchLocalHistory` filter | Messages with `[TOPIC-CONTEXT]` prefix excluded from auto-reset context |

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
  │   └─ If topic != nil && !contextInjectedKeys.contains(sessionKey):
  │       ├─ If !didAutoReset: prepend [TOPIC-CONTEXT] header
  │       └─ Always: insert sessionKey into contextInjectedKeys
  │
  ├─ Ledger entry (existing)
  │
  └─ chat.send RPC (existing)
```

---

## Agent Convention (No Code Change)

When the agent sees `[TOPIC-CONTEXT]` in a user message, it should:
1. Acknowledge the topic context briefly (don't repeat it verbatim)
2. If a `Project:` path is provided, read `STATUS.md` or `CONTEXT.md` from that path
3. Use the topic name for targeted memory/wiki search if needed

This is a prompt convention, not a code change. The agent already has the tools.

---

*Second review requested from Q, Mel, and Kieran before build.*