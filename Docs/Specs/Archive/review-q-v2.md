# Q's v2 Implementation Review — Topic Context Persistence (BC5-SPEC-004)

**Reviewer:** Q (lead developer)  
**Date:** 2026-05-08  
**Verdict:** ✅ READY TO BUILD — all original concerns addressed, one minor lifecycle gap to close during implementation.

---

## 1. Original 6 Must-Fix Items — Status

| # | Original Concern | v2 Status | Notes |
|---|-----------------|-----------|-------|
| 1 | Use `[TOPIC-CONTEXT]` marker, not `[SESSION-CONTEXT]` | ✅ Fixed | Distinct marker used throughout. `fetchLocalHistory` filter updated. |
| 2 | Replace RPC-based `needsContextInjection()` with in-memory tracking | ✅ Fixed | `contextInjectedKeys: Set<String>` — same pattern as `resetCooldownCount`. No RPC call. |
| 3 | Fix auto-reset / context injection ordering | ✅ Fixed | Injection is after auto-reset block, only if `!didAutoReset`. Pseudocode is correct. |
| 4 | Define `TopicMetadata` struct | ✅ Fixed | Struct defined in spec with `try?` decode. `parsedMetadata` computed property specified. |
| 5 | Handle `metadataJSON` parsing errors gracefully | ✅ Fixed | `try?` returns nil on malformed JSON. Header omits activeFocus/tags. No crash path. |
| 6 | Add `[TOPIC-CONTEXT]` to `fetchLocalHistory` filter | ✅ Fixed | Added as third exclusion prefix alongside existing `[SESSION-CONTEXT]` and `[SESSION-RESET]`. |

All six addressed. Clean sweep.

---

## 2. sendMessage Integration Point — Exact Lines

Current `SyncBridge.swift` — the insertion block goes **between the auto-reset cooldown block (lines 209–239) and the ledger entry creation (line 243)**.

Specifically:

```
Line 239:  } // end of cooldown/usage-check else block
Line 241:  (blank line)
Line 243:  let idempotencyKey = UUID().uuidString   ← ledger starts here
```

The new context injection block should be inserted at line 241 (between the closing `}` of the auto-reset block and the `idempotencyKey` assignment). This is exactly where the spec says: "after the auto-reset block, before ledger creation."

**One correction to the spec's pseudocode:** The spec uses `let didAutoReset = sendingSessionKeys.contains(sessionKey) && /* auto-reset just ran */` — but this is wrong. `sendingSessionKeys` is the concurrency guard (inserted at line 203, removed at defer on line 205). It doesn't indicate whether auto-reset ran.

The correct way to track `didAutoReset`:

```swift
var didAutoReset = false

// ... inside the cooldown else block, after resetSession succeeds:
didAutoReset = true
effectiveText = formatCombinedContext(recentMessages, userMessage: text)
resetCooldownCount[sessionKey] = Self.resetCooldownMessages

// ... then after the auto-reset block:
if !didAutoReset && topic != nil && !contextInjectedKeys.contains(sessionKey) {
    if let topic = topic {
        let header = buildContextHeader(topic: topic)
        effectiveText = "\(header)\n\n\(effectiveText)"
        contextInjectedKeys.insert(sessionKey)
    }
}
```

Since `SyncBridge` is an actor, `didAutoReset` as a local var within `sendMessage` is safe and correctly scoped. No cross-call persistence needed.

---

## 3. `contextInjectedKeys` Lifecycle

**When to insert:** After context header is successfully prepended to `effectiveText` in `sendMessage`. ✅

**When to clear an entry:** The spec says "clear on session reset" — but looking at the actual code, `resetCooldownCount` is **not** cleared on `resetSession()`. It's decremented per message until it hits zero. There's no explicit `removeValue(forKey:)` call on reset.

This means: after an auto-reset fires, `contextInjectedKeys` should **not** be cleared by the reset itself. The correct lifecycle is:

| Event | `contextInjectedKeys` effect |
|-------|------------------------------|
| First send in topic | Insert `sessionKey` after injection |
| Subsequent sends | Skip (key already in set) |
| Auto-reset fires | **No change** — auto-reset already prepended `[SESSION-CONTEXT]`, topic context is correctly skipped because `didAutoReset = true` |
| App restart | Set is empty (in-memory) → context injected on first send ✅ |
| Session reset (manual) | **Clear the entry** — this is the one case the spec should be explicit about. If the user manually resets a session, the next send should get fresh topic context. |

**Gap found:** The spec says "Clear entry when session resets" but doesn't specify *where* this clearing happens. There's no central "session did reset" hook in the current code. The `resetSession()` method on `SyncBridge` is a thin wrapper around `rpcClient.sessionsReset()` — it doesn't trigger any state cleanup.

**Recommendation:** Clear `contextInjectedKeys[sessionKey]` inside `resetSession()`:

```swift
public func resetSession(sessionKey: String) async throws -> Bool {
    contextInjectedKeys.remove(sessionKey)  // <-- add this
    return try await rpcClient.sessionsReset(sessionKey: sessionKey, reason: "new")
}
```

This also covers the edge case where auto-reset calls `resetSession()` internally — but in that case `didAutoReset` prevents double injection anyway, so clearing the key during auto-reset is harmless (it'll just be re-inserted on the next non-reset send if needed... actually no, because the key gets re-inserted on the *current* send if `!didAutoReset`). Wait — let me think through this more carefully.

Actually, if we clear `contextInjectedKeys` inside `resetSession()`, and auto-reset calls `resetSession()`, then after auto-reset completes:
1. `contextInjectedKeys` no longer contains the session key
2. But `didAutoReset = true`, so topic injection is skipped ✅
3. On the *next* `sendMessage` call (cooldown message), `contextInjectedKeys` doesn't contain the key, `didAutoReset` is false (new call), topic != nil → **topic context gets injected** ✅

That's actually correct! After a session reset, the next normal send *should* get topic context because the agent is in a fresh session. Good.

But wait — does the auto-reset's `formatCombinedContext` already provide enough context? Yes, but it's session history context, not topic identity context. The agent still benefits from knowing "you're in the Revenue Generation topic." So injecting topic context on the first post-reset message is correct.

**Verdict:** Clearing in `resetSession()` is the right place. Works for both manual and auto-reset paths.

---

## 4. `topic: Topic? = nil` — Safe for Existing Callers

Two call sites exist:

1. **`MessageViewModel.sendMessage()`** (line 143): `bridge.sendMessage(sessionKey: sessionKey, text: text)` — no named args for thinking/attachments omitted. Adding `topic: Topic? = nil` as a trailing optional parameter with default nil means this call compiles unchanged. ✅

2. **`MainWindow.swift`** (line 411): `bridge.sendMessage(sessionKey: gatewayKey, text: "Start", thinking: nil)` — same. Default nil applies. ✅

Phase 1: neither caller passes `topic`. Context injection never fires (topic is nil). Correct — we need to wire the Topic through from `MessageViewModel` in the implementation, which is a separate step.

**Safe.** No breaking changes.

---

## 5. Remaining Complexity — Anything Still Overcomplicated?

The v2 spec is already lean. A few minor notes:

**a) `autoContext` field removed from `TopicMetadata`** — Good. The synthesis dropped it, the v2 spec doesn't include it. The feature flag is sufficient. ✅

**b) The `topic != nil` double-check in the pseudocode is redundant:**

```swift
if !didAutoReset && topic != nil && !contextInjectedKeys.contains(sessionKey) {
    if let topic = topic {  // <-- redundant unwrap
```

The outer `if topic != nil` already guarantees this. Just use `guard let topic = topic` or unwrap inline. Minor style nit, not a spec issue.

**c) The spec still lists `projectPath` in the `TopicMetadata` section but `projectPath` is a column on `Topic`, not in `metadataJSON`.** This is correct in the spec (the header builder reads `topic.projectPath` directly, not from metadata). Just flagging that the separation is clean. ✅

**d) `buildContextHeader` should live on `Topic` as an extension, not on `SyncBridge`.** It's a pure function that only reads Topic properties. SyncBridge shouldn't own formatting logic. Minor architectural preference — not blocking.

---

## Summary

| Area | Verdict |
|------|---------|
| All 6 original concerns addressed | ✅ |
| Integration point (lines 241–242) | ✅ Correct, with `didAutoReset` fix |
| `contextInjectedKeys` lifecycle | ✅ With `resetSession()` clearing |
| `topic: Topic? = nil` safe for callers | ✅ |
| Complexity | ✅ Appropriately minimal for Phase 1 |
| Ready to build | ✅ |

### Implementation reminders (not spec changes, just coding notes):

1. Track `didAutoReset` as a local bool in `sendMessage`, not via `sendingSessionKeys`
2. Clear `contextInjectedKeys[sessionKey]` inside `resetSession()`
3. Consider moving `buildContextHeader` to a `Topic` extension
4. The double `if let topic = topic` unwrap in the injection block is redundant — clean up in code

**Ship it.**