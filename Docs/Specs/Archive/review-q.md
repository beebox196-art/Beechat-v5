# Q's Implementation Review — Topic Context Persistence (BC5-SPEC-004)

**Reviewer:** Q (lead developer)  
**Date:** 2026-05-08  
**Verdict:** ✅ APPROVED with reservations — spec is solid, but Phase 2 needs rethinking and there's a coupling concern in Phase 1.

---

## 1. IMPLEMENTATION FEASIBILITY

### Overall: Feasible, but the spec underestimates one key complexity

**What works cleanly:**

- **Database migration (v7):** Additive `ALTER TABLE` is safe. GRDB handles this. No data loss. ✓
- **Topic model extension:** Adding `projectPath` is straightforward. `metadataJSON` already exists as a text column — we just need a `TopicMetadata` struct to parse/serialise it. ✓
- **`buildContextHeader()`:** Pure function. Trivial to implement. ✓
- **Feature flag gating:** UserDefaults-backed flags are already a pattern we can follow. ✓

**What the spec glosses over:**

**a) `sendMessage` signature change is a breaking API change**

The spec proposes:
```swift
SyncBridge.sendMessage(sessionKey, text, topic: topic)
```

But the current signature is:
```swift
public func sendMessage(sessionKey: String, text: String, thinking: String? = nil, attachments: [ChatAttachment]? = nil) async throws -> String
```

Adding a `topic: Topic?` parameter is fine, but every caller needs updating. I checked the codebase — the callers are in `ChatViewModel` and possibly `ChatView`. This is manageable but the spec doesn't call out the call-site impact.

**b) The `needsContextInjection()` detection logic has a race condition**

The spec proposes checking `chat.history` to determine if a session is fresh:
```swift
if let history = try? await syncBridge.fetchHistory(sessionKey: sessionKey, limit: 5),
   history.count <= 1 {
    return true
}
```

**Problem:** `fetchHistory` is an RPC call to the gateway. It's async, it can fail, and it adds latency to every first message. More critically, there's a TOCTOU race: between the time we check history and the time we send the message, the session state could change (e.g., another device sends a message).

**Better approach:** Track injection state in-memory per session key, similar to how `resetCooldownCount` already works. When `sendMessage` is called and no prior context has been injected for this session key, inject once and mark it. This avoids the RPC call entirely.

```swift
// In SyncBridge actor:
private var contextInjectedKeys: Set<String> = []

// In sendMessage:
if !contextInjectedKeys.contains(sessionKey) && shouldInjectContext(topic) {
    let header = buildContextHeader(topic)
    effectiveText = "\(header)\n\n\(effectiveText)"
    contextInjectedKeys.insert(sessionKey)
}
```

This resets on session reset (same as cooldown), so it's correct.

**c) `justAutoReset` tracking doesn't currently exist**

The spec references `justAutoReset.contains(sessionKey)` but there's no such tracking in the current code. The `didStartAutoReset`/`didStopAutoReset` delegate callbacks exist, but they're fired within the same `sendMessage` call — they don't persist state across calls. We need to add an in-memory set (like `resetCooldownCount`) to track this.

---

## 2. SIMPLEST PATH

### Phase 1 is already the simplest path — good call

The spec correctly identifies app-level injection (prepending to message text) as the simplest approach. No gateway changes needed. The `[SESSION-CONTEXT]` prefix pattern is already established by the auto-reset flow.

**What I'd simplify further:**

- **Drop `autoContext` from `metadataJSON` for v1.** Default to always injecting on new sessions. The feature flag is enough for rollout control. Per-topic toggles add UI complexity that isn't needed yet.

- **Skip the `chat.history` RPC check entirely.** Use the in-memory `contextInjectedKeys` set approach described above. It's simpler, faster, and avoids a network call on every first message.

- **`projectPath` should be a plain text field, not a file picker.** On macOS/iOS, a file picker adds significant complexity (sandboxing, bookmark resolution, permission prompts). A simple text field where the user pastes a path is fine for v1. Validate on save (check if directory exists).

### Phase 2: Overcomplicated — should be deferred

The spec proposes two competing approaches for Phase 2:
1. Use `chat.inject` (which doesn't exist in our RPCClient)
2. Use `chat.send` with a `[RESUME-CONTEXT]` marker

**`chat.inject` is not available.** The RPCClient protocol has no `chatInject` method. The spec says "uses the existing `chat.inject` RPC method" — it doesn't exist. This is a factual error.

The `[RESUME-CONTEXT]` approach via `chat.send` works, but it triggers a full agent run, which means:
- The user sees the agent respond immediately on topic selection
- This could be jarring (the spec acknowledges this)
- It wastes tokens on orientation responses the user might not want

**Simpler Phase 2:** Make it a button, not automatic. The button sends `[RESUME-CONTEXT]` via `chat.send`. No new RPC methods, no auto-trigger logic. The spec's own "Open Questions" section recommends this, but the implementation plan contradicts itself by proposing auto-trigger. **Pick one.** I recommend button-only for v1.

---

## 3. FUTURE PROBLEMS

### `[SESSION-CONTEXT]` prefix is already used by auto-reset — potential collision

The current auto-reset flow produces:
```
[SESSION-CONTEXT] Continuing from a previous session. Recent conversation:
User: ...
Assistant: ...
```

The spec proposes topic context injection produces:
```
[SESSION-CONTEXT]
Topic: Revenue Generation
Project: /Users/openclaw/Projects/Revenue Generation/
Active Focus: ...
```

**These are distinguishable** — the auto-reset version has "Continuing from a previous session" on the same line as `[SESSION-CONTEXT]`, while the topic context version has a newline immediately after. The agent should handle both. But this is a convention, not a contract — a future model update could confuse them.

**Mitigation:** Use distinct markers. I'd suggest:
- Auto-reset: `[SESSION-CONTEXT]` (keep as-is)
- Topic context: `[TOPIC-CONTEXT]` (new, clearly distinct)
- Resume: `[RESUME-CONTEXT]` (already proposed)

This avoids any ambiguity.

### Topic context injection pollutes the message ledger

The `DeliveryLedgerEntry` stores `effectiveText` (with context header) as `content` and the original user text as `originalContent`. This is fine for delivery tracking, but it means the local message history will contain the context header as part of the user's message. When `fetchLocalHistory` filters out `[SESSION-CONTEXT]`-prefixed messages, it won't filter `[TOPIC-CONTEXT]`-prefixed ones unless we update the filter.

**Action required:** Add `[TOPIC-CONTEXT]` to the filter in `fetchLocalHistory`:
```swift
if content.hasPrefix("[TOPIC-CONTEXT]") { return false }
```

### Multi-agent / branching conversations

The spec says "Telegram topics — Not affected." But what about future multi-agent support within BeeChat? If we ever support multiple agents per topic, the `[TOPIC-CONTEXT]` header would be sent to all agents, which is probably fine (they all need the topic context). No issue here.

### Message search

If users search their message history, they'll see the `[TOPIC-CONTEXT]` headers as part of their first message in each topic. This is slightly ugly but not functionally problematic. The headers are clearly machine-generated and won't interfere with search relevance.

---

## 4. FAILURE MODES

### My top 3 concerns (ranked):

**1. Context injection on every message (spec risk #2) — HIGH concern**

The spec proposes `needsContextInjection()` with RPC-based detection. As I noted above, this is fragile. The in-memory `contextInjectedKeys` approach is safer. Without it, a gateway timeout on the history check could cause context to be injected on the second or third message — wasting tokens and confusing the agent.

**2. Auto-reset + topic context double-injection (spec risk #4) — MEDIUM concern**

The spec correctly identifies this and proposes the right fix (skip topic context when auto-reset just fired). But the implementation needs careful ordering in `sendMessage`. The current auto-reset logic modifies `effectiveText` in-place. Topic context injection must happen **after** the auto-reset block and **only if** auto-reset didn't fire. The spec's pseudocode shows this correctly, but it's easy to get wrong in practice.

**3. `fetchLocalHistory` filtering gap — MEDIUM concern**

If we use `[TOPIC-CONTEXT]` as the marker (my recommendation), we must update the filter in `fetchLocalHistory`. If we use `[SESSION-CONTEXT]`, the existing filter will strip topic context headers from local history, which means the auto-reset context reconstruction won't include the topic context. This is actually fine — the auto-reset will re-inject topic context on the next send. But it's a subtle interaction the spec doesn't address.

### What's not covered:

**Gateway session expiry between app launches.** If the user closes BeeChat for a week and the gateway expires the session, the next time they open the topic, `sendMessage` will create a new session. The in-memory `contextInjectedKeys` set will be empty (fresh app launch), so context will be injected. This is correct behaviour. ✓

**Concurrent sends from multiple devices.** If the user has BeeChat on iPad and iPhone and sends from both simultaneously, the `sendingSessionKeys` guard prevents concurrent sends within a single process. Cross-device concurrency is a gateway-level concern, not ours. ✓

---

## 5. DATABASE

### Migration path: Safe

```swift
migrator.registerMigration("v7_add_project_path") { db in
    try db.alter(table: "topics") { t in
        t.add(column: "projectPath", .text)
    }
}
```

This is additive only. `projectPath` defaults to `NULL`. Existing topics work without changes. ✓

### TopicSessionBridge interactions: No issues

The bridge table (`topic_session_bridge`) maps `topicId` → `openclawSessionKey`. The `projectPath` column on `Topic` is independent — it doesn't affect session key resolution. `TopicRepository.resolveSessionKey()` and `resolveTopicId()` don't need changes. ✓

### `metadataJSON` parsing: Needs a dedicated struct

The spec proposes a JSON structure for `metadataJSON` but doesn't define the Swift struct. I'll need:

```swift
struct TopicMetadata: Codable {
    var activeFocus: String?
    var tags: [String]?
    var autoContext: Bool?
}
```

And computed properties on `Topic` to parse/serialise:
```swift
extension Topic {
    var parsedMetadata: TopicMetadata? {
        guard let json = metadataJSON else { return nil }
        return try? JSONDecoder().decode(TopicMetadata.self, from: Data(json.utf8))
    }
    
    mutating func setMetadata(_ metadata: TopicMetadata) {
        self.metadataJSON = try? JSONEncoder().encode(metadata).flatMap { String(data: $0, encoding: .utf8) }
    }
}
```

This is straightforward but the spec should include it.

### `upsertColumns` needs updating

The current `Topic.upsertColumns` doesn't include `projectPath`. After adding the column, we need to add it:
```swift
public static let upsertColumns: [Column] = [
    Column("name"), Column("lastMessagePreview"), Column("lastActivityAt"),
    Column("unreadCount"), Column("sessionKey"), Column("isArchived"),
    Column("updatedAt"), Column("metadataJSON"), Column("projectPath")  // NEW
]
```

The spec doesn't mention this. It's a small but necessary detail.

---

## 6. GATEWAY / SyncBridge Coupling

### Proposed change fits cleanly into existing flow

The `sendMessage` flow already has a clear insertion point for context injection — right after the auto-reset block and before the ledger entry creation. The proposed change:

```
sendMessage(sessionKey, text, topic)
  → auto-reset check (existing)
  → topic context injection (NEW) ← fits here
  → ledger entry
  → chat.send RPC
```

This is clean. No fragile coupling.

### One concern: `sendMessage` now needs a `Topic` parameter

Currently `sendMessage` is:
```swift
public func sendMessage(sessionKey: String, text: String, ...) async throws -> String
```

Adding `topic: Topic?` means every caller must pass the Topic. The callers are:
- `ChatViewModel.sendMessage()` — already has access to the topic
- Any direct `SyncBridge` calls — need to be audited

This is a moderate refactoring effort but not risky. The parameter should be optional (`Topic?`) so callers that don't have topic context can still send messages (e.g., from the main session).

### No gateway RPC changes needed

The spec correctly recommends app-level injection. No new RPC methods, no gateway changes. The `[TOPIC-CONTEXT]` header is just text in the `message` parameter of `chat.send`. ✓

---

## Summary

| Area | Verdict | Notes |
|------|---------|-------|
| Phase 1 feasibility | ✅ Good | Use in-memory tracking, not RPC-based detection |
| Phase 1 simplest path | ✅ Good | App-level injection is correct |
| Phase 2 feasibility | ⚠️ Deferred | `chat.inject` doesn't exist. Button-only approach is sufficient for v1. |
| Database | ✅ Safe | Additive migration. Don't forget `upsertColumns` update. |
| Gateway coupling | ✅ Clean | Fits into existing `sendMessage` flow |
| Future problems | ⚠️ Minor | Use `[TOPIC-CONTEXT]` not `[SESSION-CONTEXT]` to avoid collision |

### Recommended changes before implementation:

1. **Use `[TOPIC-CONTEXT]` marker** instead of reusing `[SESSION-CONTEXT]` to avoid collision with auto-reset context
2. **Use in-memory `contextInjectedKeys` set** instead of RPC-based `needsContextInjection()` — simpler, faster, no race condition
3. **Phase 2: button-only, no auto-trigger** — the spec contradicts itself; pick the simpler option
4. **Define `TopicMetadata` struct** in the spec so the JSON schema is explicit
5. **Update `upsertColumns`** in the spec's model definition
6. **Add `[TOPIC-CONTEXT]` to `fetchLocalHistory` filter** to keep local history clean

### Estimated effort (after these changes):

- **Phase 1:** 1.5–2 days (DB migration + model + SyncBridge logic + UI text field)
- **Phase 2:** 0.5–1 day (button + `[RESUME-CONTEXT]` handler — if deferred, 0 days)

**Ready to build once the above changes are incorporated.**
