# Kieran Review v2 — BC5-SPEC-004 (Topic Context Persistence)

**Reviewer:** Kieran (independent review)  
**Date:** 2026-05-08  
**Spec:** v2 (revised after team review)  
**Verdict:** **Approve with 2 must-fix issues**

---

## 1. Are Must-Fix Items from v1 Addressed?

| # | Must-Fix (v1) | Addressed? | Notes |
|---|---------------|-----------|-------|
| 1 | Use `[TOPIC-CONTEXT]` marker | ✅ | Distinct from `[SESSION-CONTEXT]` |
| 2 | Replace RPC-based `needsContextInjection()` with in-memory tracking | ✅ | `contextInjectedKeys: Set<String>` — same pattern as `resetCooldownCount` |
| 3 | Fix auto-reset / context injection ordering | ⚠️ | See **Bug A** below |
| 4 | Define `TopicMetadata` struct + update `upsertColumns` | ✅ | Struct defined, `upsertColumns` updated |
| 5 | Handle `metadataJSON` parsing errors gracefully | ✅ | `try?` decode, returns nil |
| 6 | Show full `sendMessage` signature change | ✅ | `topic: Topic? = nil` with default — no call-site changes |

**4.5/6 addressed cleanly.** Items 1, 2, 4, 5, 6 are solid. Item 3 has a logic gap.

---

## 2. Must-Fix Issues in v2

### Bug A: `contextInjectedKeys` not set after auto-reset → double injection on next send

The spec's expected behavior table says:

> *After auto-reset, next normal send → No header (`contextInjectedKeys` already set) ✅*

But the injection logic only inserts into `contextInjectedKeys` **when topic context is actually injected** (inside the `if let topic = topic` block). When auto-reset fires and topic context is skipped, the session key is **never added** to `contextInjectedKeys`. So on the next `sendMessage` call, all three conditions are met (`!didAutoReset` = true for the new call, `topic != nil`, `!contextInjectedKeys.contains` = true) and topic context **is** injected. This contradicts the spec's own expected result.

**Fix:** Insert `contextInjectedKeys.insert(sessionKey)` unconditionally when auto-reset fires — OR — restructure so the key is always set for the session after the first `sendMessage` regardless of which path ran. Simplest:

```swift
// After the auto-reset block, before topic injection:
if /* auto-reset just ran for this call */ {
    contextInjectedKeys.insert(sessionKey)  // prevent topic context on next call
}

// Or alternatively, always insert at the end of sendMessage:
contextInjectedKeys.insert(sessionKey)
```

The "always insert at end" approach is cleanest — it means every `sendMessage` call marks the session as context-aware, and only the very first call (where the set doesn't contain the key) gets any header.

### Bug B: Migration naming doesn't match existing convention

The spec uses `"v7_add_project_path"` but the codebase uses `"Migration012_Description"` format (currently up to Migration011). The next migration should be `Migration012_AddProjectPath`.

Minor but will cause confusion if copy-pasted. Fix the name.

---

## 3. Codebase Accuracy Check

| Spec Claim | Actual Code | Accurate? |
|-----------|-------------|-----------|
| `Topic` model has no `projectPath` column | Correct — confirmed from Topic.swift | ✅ |
| `upsertColumns` currently excludes `projectPath` | Correct — only has the 8 columns listed | ✅ |
| `fetchLocalHistory` filters `[SESSION-CONTEXT]` and `[SESSION-RESET]` prefixes | Correct — lines in SyncBridge.swift match | ✅ |
| `sendMessage` signature is `sessionKey:text:thinking:attachments:` | Correct — no `topic` param yet | ✅ |
| Auto-reset modifies `effectiveText` before ledger creation | Correct — `effectiveText = formatCombinedContext(...)` then ledger entry | ✅ |
| `resetCooldownCount` is an in-memory `[String: Int]` | Correct — same actor-isolated pattern | ✅ |
| "Clear `contextInjectedKeys` entry on session reset (alongside `resetCooldownCount` cleanup)" | **Inaccurate** — `resetCooldownCount` is not "cleaned up" on reset; it's **set** to `Self.resetCooldownMessages` after auto-reset. It's decremented per send and removed when it hits 0. | ⚠️ |

The `resetCooldownCount` analogy is wrong. The spec says "clear alongside resetCooldownCount cleanup" implying they're both cleared on reset. In reality, `resetCooldownCount` is **set** on auto-reset, not cleared. The cleanup (removal) happens when the cooldown naturally decrements to zero.

For `contextInjectedKeys`, the spec should be explicit: when should entries be removed? Options:
1. **Never** (safest — once a session gets context, it never gets it again until app restart)
2. **On explicit session reset** (when `resetSession()` is called manually, not auto-reset)

I recommend option 1. App restart already clears it (in-memory). There's no scenario where re-injecting topic context mid-session adds value — the agent already knows the topic. If you want option 2, you'd need a hook in `resetSession()`, which doesn't exist yet.

---

## 4. Test Cases — Gaps

The test table covers the happy paths well. Missing scenarios:

1. **Auto-reset fires, then user sends 2nd message during cooldown** — Currently this would (incorrectly) inject `[TOPIC-CONTEXT]` due to Bug A. This is the most important missing test case. If Bug A is fixed, this test should pass with "No header."

2. **Concurrent sends to different topics** — Two topics sending simultaneously via different session keys. Should both get context headers independently. This works by design (set is keyed by session key) but worth an explicit test since the actor concurrency guard (`sendingSessionKeys`) could cause one to fail with `concurrentSendInProgress`.

3. **Topic with `sessionKey` set vs. nil** — The spec passes `Topic?` to `sendMessage`, but doesn't discuss how the caller knows which topic maps to which session. If `Topic.sessionKey` is nil, passing the topic to `sendMessage` would inject context for a session that may not match. Clarify that callers should only pass `topic` when `topic.sessionKey == sessionKey`.

4. **`metadataJSON` is valid JSON but wrong schema** — e.g., `{"color":"blue"}` (valid JSON, wrong keys). `try? JSONDecoder().decode(TopicMetadata.self, ...)` returns nil. Header omits focus/tags. This is fine but should be an explicit test case since "malformed JSON" is already tested — this is a distinct failure mode.

5. **Feature flag toggled mid-session** — User sends one message (context injected), then disables the flag, then continues. The `contextInjectedKeys` set already has the key, so no double injection. But if the flag is re-enabled, context won't re-inject. This is correct behaviour, but worth noting.

---

## 5. Regression Risk

| Scenario | Risk | Why |
|----------|------|-----|
| Existing `sendMessage` call sites break | **None** | `topic: Topic? = nil` default means no changes needed |
| Auto-reset flow breaks | **Very Low** | Context injection is after auto-reset, before ledger. If the injection block has a bug, it's isolated. |
| `fetchLocalHistory` filters too aggressively | **Low** | Adding `[TOPIC-CONTEXT]` filter only affects messages starting with that exact prefix. Existing messages don't have it. |
| Database migration blocks app launch | **Very Low** | Additive column with nil default. GRDB handles this cleanly. |
| `SyncBridge` actor isolation issue | **Low** | `contextInjectedKeys` is a `Set<String>` in an actor. All access is isolated. No risk. |
| Ledger `originalContent` mismatch | **Low** | The spec doesn't mention what `originalContent` stores. Currently `originalContent: text` (the raw input). After this change, `content: effectiveText` (with header) and `originalContent: text` (without header). This is correct — the original is the user's actual input. But worth confirming this is intentional. |

**Biggest regression risk:** Bug A. If topic context is injected on the 2nd message after auto-reset, the agent receives `[TOPIC-CONTEXT]` on a message where it shouldn't. Not catastrophic (agent sees extra info) but violates the spec's stated guarantees and could cause confusion during debugging.

---

## 6. Overcomplication Check

The v2 spec is significantly simpler than v1. Phase 2 deferred. No new UI. No RPC methods. Good.

**Still slightly overcomplicated:**

1. **`didAutoReset` detection** — The pseudocode uses `let didAutoReset = sendingSessionKeys.contains(sessionKey) && /* auto-reset just ran */` which is vague. Just use a local `var didAutoReset = false` set to `true` inside the auto-reset block. Simple, unambiguous.

2. **The feature flag** — Adding a `@AppStorage` flag for this is borderline. It's one more thing to test, and the default is `true`. If the feature is simple and well-tested, the flag adds complexity without value. Consider: is there a realistic scenario where someone needs to turn this off? If yes, keep it. If no, remove it and add it later when needed.

3. **`TopicMetadata` struct with `autoContext` field** — The review synthesis includes `autoContext: Bool?` in the struct but the spec v2 drops it (since Phase 2 is deferred). The spec is correct to drop it. Don't add fields for features that don't exist yet.

---

## Summary

| Category | Status |
|----------|--------|
| v1 must-fix items | 5.5/6 addressed |
| New must-fix issues | 2 (Bug A: contextInjectedKeys logic, Bug B: migration naming) |
| Codebase accuracy | Good, one analogy mismatch |
| Test coverage | 5 gaps identified |
| Regression risk | Low (Bug A is the main concern) |
| Complexity | Much improved, 3 minor items to simplify |

**Recommendation:** Fix Bug A (contextInjectedKeys insertion after auto-reset) and Bug B (migration naming), add the missing test for "2nd message after auto-reset," then ship. Everything else is nit-level.

---

*End of v2 review.*