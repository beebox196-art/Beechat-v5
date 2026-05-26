# Kieran Final Review — Topic Context Persistence (v2.1)

**Reviewer:** Kieran (independent)  
**Spec:** BC5-SPEC-004 v2.1  
**Date:** 2026-05-08  
**Verdict:** 🟡 Approve with conditions — 3 items must be addressed before build, 2 recommended cuts  

---

## 1. `contextInjectedKeys` Lifecycle — "Never remove, app restart clears"

**Verdict: Incomplete.** The "never remove" policy has a gap: **manual session resets.**

Scenarios the spec handles correctly:
- ✅ Normal first message → key inserted, context injected
- ✅ App restart → set is empty, context re-injected
- ✅ Gateway session expiry → new sessionKey, naturally re-injected

Scenario the spec does **not** handle:
- ❌ **Manual session reset from UI** — User taps "reset session" in BeeChat. The sessionKey may stay the same. After reset, the agent starts fresh with no context. But `contextInjectedKeys` still has the key, so `[TOPIC-CONTEXT]` is never re-injected. The user now has a blank agent that doesn't know what topic it's in.

**Fix:** Remove the key from `contextInjectedKeys` when `resetSession()` is called. This is a single line:

```swift
contextInjectedKeys.remove(sessionKey)
```

Add it to `resetSession()` or have the caller remove it. This also correctly handles the auto-reset case — the key is removed on reset, then re-inserted on the next `sendMessage` call (with `[SESSION-CONTEXT]` already providing context, so no `[TOPIC-CONTEXT]` duplication).

This supersedes the v2.0 "clear on reset" approach and the v2.1 "never remove" approach. The correct policy is: **remove on explicit or auto-reset, never remove otherwise.** App restart clears everything as a side effect (correct).

---

## 2. The Unconditional Insert — Scenario Walkthrough

I've walked through every scenario in the spec table plus edge cases:

| Scenario | Correct? | Notes |
|----------|----------|-------|
| First message in a new topic | ✅ | Key not in set, prepend header, insert key |
| Second message in same topic | ✅ | Key in set, skip block |
| After auto-reset (same call) | ✅ | didAutoReset=true, skip header, insert key |
| 2nd message after auto-reset | ✅ | Key in set, skip block |
| After app restart | ✅ | Set empty, context injected on first send |
| Topic is nil (non-topic session) | ✅ | Outer `if topic != nil` skips block |
| Concurrent sends to different topics | ✅ | Different sessionKeys, independent entries |
| **Manual reset, then send** | ❌ | Key still in set, no context re-injected (see point 1) |

**Missing scenario from the spec table:** Manual session reset. Add it.

The unconditional insert logic itself is correct — it prevents double-injection after auto-reset. The only gap is the reset lifecycle covered in point 1.

---

## 3. `topic: Topic? = nil` — Coupling

**Verdict: Acceptable for Phase 1.**

`SyncBridge` only reads `topic.name`, `topic.projectPath`, and `topic.parsedMetadata` (via the computed property). This is read-only, single-function scope. Creating a `TopicContext` struct or protocol would be premature abstraction.

**Caveat:** If Phase 1.5 adds UI fields that SyncBridge shouldn't know about, revisit then. For now, the coupling is shallow and harmless.

---

## 4. `buildContextHeader(topic: topic!)` Force Unwrap

**Verdict: Safe but sloppy.**

The force unwrap is technically safe — `topic != nil` is checked on the outer `if`. But:

```swift
if topic != nil && !contextInjectedKeys.contains(sessionKey) {
    if !didAutoReset {
        let header = buildContextHeader(topic: topic!)  // ← force unwrap
```

This is a code smell. If someone later refactors the outer condition and removes the `topic != nil` check, the force unwrap crashes.

**Fix:** Use `if let`:

```swift
if let topic, !contextInjectedKeys.contains(sessionKey) {
    if !didAutoReset {
        let header = buildContextHeader(topic: topic)
    }
    contextInjectedKeys.insert(sessionKey)
}
```

This is a spec-level change, not just implementation detail. The spec should show `if let` syntax, not force unwrap.

---

## 5. Feature Flag — `@AppStorage` Mechanism

**Verdict: Bug in spec.** `@AppStorage` is a SwiftUI property wrapper. `SyncBridge` is a `public actor` — it **cannot** use `@AppStorage`.

```swift
// Spec says:
@AppStorage("feature_topicContextInjection") 
static var topicContextInjection: Bool = true
```

This won't compile in an actor context. Options:
1. **Read from UserDefaults directly** — `UserDefaults.standard.bool(forKey:)` — simple, works from anywhere
2. **Add to SyncBridgeConfiguration** — the flag lives in config, passed at init
3. **Static property on SyncBridge** — `static var topicContextInjection: Bool = true`

**Recommendation:** Option 1 (UserDefaults directly) for Phase 1. It's simple, testable, and doesn't pollute the config object. The spec should show:

```swift
private var isTopicContextEnabled: Bool {
    UserDefaults.standard.object(forKey: "feature_topicContextInjection") as? Bool ?? true
}
```

**Mid-conversation toggle:** If the user toggles the flag off mid-conversation:
- If the key is already in `contextInjectedKeys`: no effect (context already injected)
- If the key is not yet in the set: next send skips context injection

Both are correct behaviours. No issue here.

---

## 6. "Never Remove" vs v2.0 "Clear on Reset"

**Verdict: v2.0 was closer to correct.**

- v2.0: "Clear entry when session resets" — over-broad (clears on auto-reset too, which is redundant since `didAutoReset` already handles it)
- v2.1: "Never remove entries" — under-broad (doesn't handle manual resets)

**Correct policy:** Remove key on reset (both manual and auto). The auto-reset path already inserts the key unconditionally, so clearing it on reset just means: after reset, the next `sendMessage` will re-evaluate and (if auto-reset provided context) insert the key again without a `[TOPIC-CONTEXT]` header. For manual resets, it means topic context is re-injected on the first post-reset message.

This makes the lifecycle: **insert on first effective context delivery, remove on session reset, clear all on app launch.**

---

## 7. Is `projectPath` Column Needed NOW?

**Verdict: No. Remove from Phase 1.**

Arguments:
- Nil by default, no UI to set it, no code path that populates it
- `buildContextHeader` already handles nil gracefully (`if let projectPath`)
- Adding a migration for a column that will always be nil is pure waste
- If Phase 1.5 changes the column type or semantics, you'd need another migration anyway
- The cost isn't zero: every migration needs testing (test case 15), and additive columns can have edge cases with upsert logic

**Recommendation:** Drop `projectPath` from Migration012. Add it when the UI exists in Phase 1.5. The `buildContextHeader` function can be written without `projectPath` support — add that branch when the column exists.

---

## 8. Is `TopicMetadata` Struct Needed NOW?

**Verdict: No. Remove from Phase 1.**

Same reasoning as `projectPath`:
- `activeFocus` and `tags` will always be nil — there's no UI to create them
- `parsedMetadata` is dead code — no Topic will have valid metadata JSON in Phase 1
- `try?` decode means it never crashes, but it also never runs a meaningful path
- The `TopicMetadata` struct and `parsedMetadata` extension add ~15 lines of untested code

**Recommendation:** Drop `TopicMetadata` and `parsedMetadata` from Phase 1. `buildContextHeader` should just use `topic.name`. When Phase 1.5 adds metadata UI, add the struct and the decode logic then — and write tests that actually exercise it.

---

## 9. Test Coverage — Missing Scenarios

The 16 cases are solid but miss these:

| Missing Scenario | Why It Matters |
|-----------------|----------------|
| **Manual session reset, then send with topic** | Point 1 — context should be re-injected |
| **Feature flag OFF from app launch** | Not just mid-session toggle — verify it never fires |
| **topic is nil (plain session, no topic)** | Verify no header is prepended, no key inserted |
| **sendMessage when feature flag is OFF** | Entire injection block skipped, message sent as-is |

Add these 4 cases. Total: 20 test cases.

---

## 10. The Simplest Possible Version

If I had to cut this spec to the absolute minimum:

**Keep:**
1. `contextInjectedKeys: Set<String>` — essential tracking
2. `topic: Topic? = nil` parameter — essential data path
3. Minimal header: `[TOPIC-CONTEXT]\nTopic: {name}` — essential functionality
4. Insert key on first send, remove key on reset — correct lifecycle
5. `[TOPIC-CONTEXT]` filter in `fetchLocalHistory` — prevents context leaking into auto-reset
6. Feature flag (UserDefaults, not @AppStorage) — kill switch

**Cut:**
1. `projectPath` column + migration — no value until Phase 1.5
2. `TopicMetadata` struct + `parsedMetadata` — dead code in Phase 1
3. `buildContextHeader` as a separate function — inline it or keep it minimal (just name)
4. The `!didAutoReset` conditional — simplify by always inserting the key and only prepending the header when not auto-reset (which is what the code does, but the spec explanation is complex)

The core value proposition is **one line of context on the first message per topic session**. Everything else is scaffolding for future phases. Ship that first.

---

## Summary

| # | Item | Verdict | Action |
|---|------|---------|--------|
| 1 | contextInjectedKeys lifecycle | 🟡 Gap | Remove key on reset (both manual and auto) |
| 2 | Unconditional insert walkthrough | 🟢 Correct | Add manual-reset scenario to table |
| 3 | Topic model coupling | 🟢 Acceptable | No change for Phase 1 |
| 4 | Force unwrap on topic! | 🟡 Style issue | Spec should use `if let topic` |
| 5 | @AppStorage feature flag | 🔴 Bug | Can't use @AppStorage in actor; use UserDefaults |
| 6 | "Never remove" policy | 🟡 Incomplete | Clear on reset, not "never remove" |
| 7 | projectPath column | 🟡 YAGNI | Remove from Phase 1 |
| 8 | TopicMetadata struct | 🟡 YAGNI | Remove from Phase 1 |
| 9 | Test coverage | 🟡 4 missing | Add manual reset, flag-off, nil topic, flag-off-from-launch |
| 10 | Simplest version | 🟢 Identified | Cut projectPath, TopicMetadata; keep flag |

**Must-fix before build:** Items 1 (reset lifecycle), 5 (@AppStorage bug), 6 (policy correction).  
**Recommended cuts:** Items 7 and 8 (YAGNI).  
**Spec updates needed:** Items 2, 4, 9 (documentation/test additions).

---

*Green light once items 1, 5, and 6 are resolved. Items 7 and 8 are strongly recommended but not blocking.*