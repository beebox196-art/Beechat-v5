# Q Final Review — Topic Context Persistence (v2.1)

**Reviewer:** Q (lead developer)  
**Date:** 2026-05-08  
**Verdict:** ✅ **GREEN LIGHT** — with 2 items to address before implementation

---

## Point-by-Point Review

### 1. `[TOPIC-CONTEXT]` marker — ✅ Confirmed

Distinct from `[SESSION-CONTEXT]` and `[SESSION-RESET]`. No collision risk — these markers are internal to the app's message flow and the agent already distinguishes them by prefix. The naming is consistent with the existing convention. No concerns.

### 2. `contextInjectedKeys: Set<String>` — ✅ Confirmed, minor note

The set grows only to the number of unique sessions ever messaged in a single app run. On macOS, a user might have 20–50 topics. Even with 500 sessions, a `Set<String>` of 500 entries is ~32KB. No memory concern. App restart clears it. This is fine.

**Note:** The spec says "cleared on reset" in Risk #2, but the set is only cleared on app restart, not on session reset. The spec body is correct — the risk table wording is slightly misleading. Worth clarifying but not a blocker.

### 3. Unconditional insert on first sendMessage — ✅ Confirmed

This is the right call. The logic is:

- Auto-reset fires → agent gets `[SESSION-CONTEXT]` → key inserted → next message won't get `[TOPIC-CONTEXT]` ✅
- No auto-reset → agent gets `[TOPIC-CONTEXT]` → key inserted → next message won't get it ✅
- Auto-reset fires, then later the session gets a normal send → key already in set → no header ✅

The unconditional insert is the critical correctness property. Without it, the 2nd message after auto-reset would incorrectly get a `[TOPIC-CONTEXT]` header. The spec nails this.

### 4. `topic: Topic? = nil` parameter — ⚠️ Challenge

Passing the full `Topic` model couples `SyncBridge` (a persistence-adjacent module) to the full `Topic` struct. For Phase 1, this is acceptable — `Topic` is already imported via `BeeChatPersistence` and `SyncBridge` already uses it. But it's worth flagging: if we later want to use `SyncBridge` in a context where `Topic` isn't available (e.g., iOS without the persistence module), this parameter becomes a dependency problem.

**Recommendation:** For Phase 1, keep it as-is. It's the simplest approach. Document that this is a Phase 1 convenience and consider a lighter type (e.g., `TopicContext: String?` = "name | projectPath | focus") for Phase 2.

**Not a blocker.** The coupling already exists — `SyncBridge` imports `BeeChatPersistence` and uses `Topic` through `Reconciler` and other paths.

### 5. `buildContextHeader` location — ✅ Confirmed (SyncBridge is fine for Phase 1)

Putting it on `SyncBridge` is pragmatic for Phase 1. Putting it on `Topic` as an extension would be more architecturally clean (data formatting belongs with the model), but it doesn't matter for a single consumer. Move it to `Topic` in Phase 1.5 when the UI also needs to display this info.

**Not a blocker.**

### 6. `TopicMetadata` struct — ✅ Confirmed (keep it)

It's 10 lines of code. `parsedMetadata` returns `nil` gracefully when there's no JSON. It's defensive, not speculative — the `metadataJSON` column already exists and could contain arbitrary JSON. Parsing it safely is better than string-matching. If `activeFocus`/`tags` never materialise, the struct just sits there harmlessly.

**Not a blocker.** Keep it.

### 7. Feature flag — ⚠️ Challenge

Two issues:

1. **`@AppStorage` is SwiftUI-specific.** `SyncBridge` lives in `BeeChatSyncBridge`, a separate module from the SwiftUI app layer. It cannot directly read `@AppStorage` without importing SwiftUI (which it shouldn't). The flag needs to be passed in as a configuration parameter — either through `SyncBridgeConfiguration` or as a method parameter.

2. **Is a feature flag even necessary?** The injection is: a set check, a string prepend, and a DB column. If it breaks, it's a compile-time issue (missing column) or a runtime no-op (set prevents re-injection). The risk of "it just doesn't work" is near-zero. A feature flag adds complexity for something that can't really go wrong in a destructive way.

**Recommendation:** Either (a) pass it through `SyncBridgeConfiguration` as a `Bool`, or (b) skip the flag entirely for Phase 1. If Bee wants to keep it, option (a) is the right approach.

**Not a blocker, but needs resolution before implementation.** I won't use `@AppStorage` directly in `SyncBridge`.

### 8. `fetchLocalHistory` filter — ✅ Confirmed

Adding `[TOPIC-CONTEXT]` to the exclusion list is correct. The only consumer of `fetchLocalHistory` is `formatCombinedContext` for auto-reset context reconstruction. Filtering out injected context headers prevents the agent from seeing stale topic context in the reconstructed history. No other code path uses this filter, so no information loss elsewhere.

**Not a blocker.**

### 9. Migration naming — ✅ Confirmed

Latest migration in `DatabaseManager.swift` is `Migration011_AddMessageAgentId`. `Migration012_AddProjectPath` is correct. The table is `topics` (confirmed — created in Migration005). The column addition is additive with nil default — safe.

**Not a blocker.**

### 10. Integration point — ✅ Confirmed

I traced the exact code path in `SyncBridge.sendMessage`:

```
Line ~194: guard !sendingSessionKeys.contains(sessionKey)  // concurrency guard
Line ~198: streamingSessionKeys check + abortGeneration
Line ~202: var effectiveText = text
Line ~204: cooldown check
Line ~208: usage check → auto-reset block (sets didAutoReset, modifies effectiveText)
           ← INSERT HERE
Line ~238: DeliveryLedgerEntry creation
Line ~248: rpcClient.chatSend
```

The injection block goes between line ~236 (end of cooldown/usage block) and line ~238 (ledger creation). Nothing between auto-reset and ledger creation — just the closing brace of the `do/catch`. No interference.

**Not a blocker.**

### 11. `didAutoReset` local flag — ✅ Confirmed

`SyncBridge` is declared as `public actor SyncBridge`. All methods on an actor are serialised — only one can execute at a time. A local `var didAutoReset = false` inside `sendMessage` is scoped to that single call. No concurrency concerns. It cannot leak between calls.

**Not a blocker.**

### 12. Risk #2 ("Context injected on every message") — ✅ Confirmed, but...

The "Very Low" rating is correct. The set is managed within an actor, so the contains/insert is atomic within the method. A code bug *could* bypass the check if someone removes the `!contextInjectedKeys.contains(sessionKey)` guard, but that would be caught in code review. The risk is accurately assessed.

**Not a blocker.**

### 13. Missing items — ⚠️ 3 items flagged

**A. Caller-side changes not documented.** The spec says "`topic: Topic? = nil` has a default, existing callers work unchanged" — this is true. But it doesn't say *who* needs to start passing the `topic` parameter. The UI layer (likely `ChatView` or `ChatViewModel`) needs to pass the selected topic when calling `sendMessage`. This is a Phase 1 implementation detail but should be called out so it's not forgotten.

**B. `Topic` model changes need `projectPath` property.** The spec covers the migration and `upsertColumns` update, but doesn't explicitly call out that `Topic.swift` needs:
- A `public var projectPath: String?` property
- An update to the `init` method with a default of `nil`

This is implied by "Update `Topic.upsertColumns`" but should be explicit.

**C. `TopicMetadata` and `parsedMetadata` file location not specified.** Where does the extension go? `Topic.swift` is the natural home. Should be stated explicitly.

---

## Summary

| # | Decision | Verdict |
|---|----------|---------|
| 1 | `[TOPIC-CONTEXT]` marker | ✅ Confirmed |
| 2 | `contextInjectedKeys` set | ✅ Confirmed (risk table wording minor) |
| 3 | Unconditional insert | ✅ Confirmed |
| 4 | `topic: Topic?` parameter | ⚠️ Acceptable for Phase 1, flag for Phase 2 |
| 5 | `buildContextHeader` location | ✅ Confirmed |
| 6 | `TopicMetadata` struct | ✅ Confirmed |
| 7 | Feature flag mechanism | ⚠️ **Resolve: pass via config, not @AppStorage** |
| 8 | `fetchLocalHistory` filter | ✅ Confirmed |
| 9 | Migration naming | ✅ Confirmed |
| 10 | Integration point | ✅ Confirmed |
| 11 | `didAutoReset` local flag | ✅ Confirmed |
| 12 | Risk #2 rating | ✅ Confirmed |
| 13 | Missing items | ⚠️ **Resolve: caller changes, Topic model property, file location** |

## Verdict

**🟢 GREEN LIGHT** — proceed to implementation.

Two items need resolution before build:

1. **Feature flag mechanism** — pass through `SyncBridgeConfiguration`, don't use `@AppStorage` directly in `SyncBridge`. Or skip the flag entirely for Phase 1.
2. **Caller-side documentation** — add a note that the UI layer needs to pass `topic:` to `sendMessage`, and explicitly list the `Topic` model property + init changes.

Everything else is solid. The spec is well-reasoned, the edge cases are covered, and the implementation is low-risk.
