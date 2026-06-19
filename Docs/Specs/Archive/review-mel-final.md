# Mel's Final UX Review — Topic Context Persistence

**Spec:** topic-context-persistence.md v2.1  
**Date:** 2026-05-08  
**Reviewer:** Mel (UI/UX)  
**Verdict:** ✅ GREEN LIGHT — with conditions noted below

---

## Decision 1: Zero UI in Phase 1

**Verdict: Correct call.**

The feature is invisible to the user, and that's fine. The user already sees the topic name in the sidebar — they *know* which topic they're in. The only beneficiary of this feature is the agent. Adding UI for something the user doesn't need to interact with would be decoration, not design.

**One concern:** The user might notice the agent "suddenly knows things" after a restart and feel it's uncanny. But this is a *positive* uncanny — the whole point is that the agent feels more aware, not less. If a user asks "how did you know that?", the answer is simple: "I can see the topic you're in." No deception, no magic.

**Condition:** If user testing shows confusion, we add a subtle toast or system message ("Topic context restored") in Phase 1.5. But I don't expect that to be necessary.

---

## Decision 2: Context Header Format

**Verdict: Correct format, with one tweak.**

`[TOPIC-CONTEXT]\nTopic: X\nProject: Y` is clean, machine-parseable, and distinct from `[SESSION-CONTEXT]`. The agent convention ("acknowledge briefly, don't parrot") is the right approach.

**Tweak:** I'd add a blank line between the header and the user's actual message. The spec shows this in the code (`"\(header)\n\n\(effectiveText)"`) — good, that's already there. The double newline gives the agent a clear visual boundary between context metadata and the user's actual intent.

**Agent convention concern:** The convention says "don't repeat it verbatim." This is good guidance but I'd strengthen it slightly: the agent should *use* the topic context to shape its response, not *acknowledge* it. A user doesn't want "I see you're in the DJI topic — how can I help?" They want the agent to just *be in the DJI topic*. The acknowledgment should be implicit in the response quality, not explicit in the text.

**Recommendation:** Update the Agent Convention section to say:
> "Use the topic context to inform your response. Do not acknowledge the topic explicitly unless the user asks. Let the relevance of your response demonstrate awareness."

---

## Decision 3: `projectPath` Column in Phase 1

**Verdict: Defer the column.**

There is no UI to set it, no way to populate it, and it will always be nil. Adding a database column that serves zero purpose in Phase 1 is premature. The migration itself is low-risk, but it's still unnecessary code that adds cognitive load during review and introduces a field that future developers will wonder about.

**Recommendation:** Remove the `projectPath` column, the migration, and the `upsertColumns` update from Phase 1. Add it in Phase 1.5 alongside the UI that actually uses it. The `buildContextHeader` function can still reference `projectPath` as a future field — just don't add the column yet.

**Risk if deferred:** None. The column is additive. Adding it later is a one-line migration.

---

## Decision 4: `TopicMetadata` Struct in Phase 1

**Verdict: Defer the struct.**

Same logic as `projectPath`. `activeFocus` and `tags` will always be nil. The `parsedMetadata` computed property returns nil on malformed JSON (good safety), but if the JSON is always nil, the property always returns nil. This is dead code in Phase 1.

**Recommendation:** Remove `TopicMetadata` struct and `parsedMetadata` from Phase 1. Add them in Phase 1.5 with the UI. The `buildContextHeader` function can be simplified for Phase 1 to just output Topic name — that's the only value that will ever be populated.

**Simplified Phase 1 header:**
```swift
func buildContextHeader(topic: Topic) -> String {
    return "[TOPIC-CONTEXT]\nTopic: \(topic.name)"
}
```

That's it. One line of actual logic. Everything else is future-proofing that doesn't need to exist yet.

---

## Decision 5: Feature Flag

**Verdict: Overengineered. Remove it.**

A feature flag for something with zero user-visible UI, zero risk profile, and a default of `true`? This is a flag that no one will ever toggle and no one will ever need to toggle. If it breaks, we revert the code — same as any other bug.

The `@AppStorage` flag adds:
- A new persisted setting
- A conditional branch in the code
- A test case ("feature flag toggled mid-session")
- Cognitive overhead for future developers wondering "why does this exist?"

**Recommendation:** Ship without a flag. If we need to kill it for any reason, a code revert takes 30 seconds. The flag solves a problem that doesn't exist.

---

## Decision 6: Is This the Simplest Possible Version?

**Verdict: Almost. Here's what I'd cut:**

| Element | Keep? | Reason |
|---------|-------|--------|
| `contextInjectedKeys` set | ✅ Yes | Core mechanism — prevents double injection |
| `buildContextHeader` function | ✅ Yes | Needed, but simplify to Topic-only (see Decision 4) |
| `topic` parameter on `sendMessage` | ✅ Yes | Required to pass topic into the injection block |
| `[TOPIC-CONTEXT]` filter in `fetchLocalHistory` | ✅ Yes | Prevents context pollution on auto-reset |
| `projectPath` column | ❌ Cut | Never used in Phase 1 |
| `TopicMetadata` struct | ❌ Cut | Never used in Phase 1 |
| Feature flag | ❌ Cut | No user-facing toggle needed |
| Migration | ❌ Cut | Goes with `projectPath` |

**The absolute simplest Phase 1 is:**

1. Add `topic: Topic? = nil` parameter to `sendMessage`
2. Add `contextInjectedKeys: Set<String>` to `SyncBridge`
3. Add `buildContextHeader(topic:)` that returns `[TOPIC-CONTEXT]\nTopic: <name>`
4. Add injection block (with auto-reset guard)
5. Add `[TOPIC-CONTEXT]` to history filter

That's 5 changes instead of 10. Everything else is Phase 1.5.

---

## Decision 7: Phase 1 vs Phase 1.5 Split

**Verdict: The split is right, but Phase 1 is overweight.**

Phase 1.5 correctly contains all the UI chrome (project picker, active focus field, tags). Phase 1 correctly contains the backend plumbing.

**But Phase 1 includes backend for features that don't exist yet** (`projectPath` column, `TopicMetadata` struct). Those belong in 1.5 alongside the UI that populates them. There's no value in having a column nobody can write to.

**Adjusted split:**

| Phase 1 | Phase 1.5 |
|---------|-----------|
| `contextInjectedKeys` set | Project path UI (picker) |
| `buildContextHeader` (Topic-only) | `projectPath` column + migration |
| `sendMessage` topic parameter | `TopicMetadata` struct |
| `[TOPIC-CONTEXT]` history filter | Active focus UI |
| Agent convention update | Tags UI |
| | Expanded `buildContextHeader` (project, focus, tags) |

---

## Decision 8: Risk to Existing UX

**Verdict: Low risk, but one real concern.**

The `[TOPIC-CONTEXT]` header is prepended to the user's first message. If the agent interprets it poorly, the first response could be something like "I see you're in the DJI Enterprise topic. How can I help?" — which is robotic and adds no value.

**This is the single biggest UX risk in the entire spec.** Not a crash, not a data loss — a *worse first impression* of the agent's intelligence.

**Mitigations:**
1. **Agent convention is critical** — see my tweak in Decision 2. The agent must *use* the context, not *acknowledge* it.
2. **Test with multiple models** — the spec already says this. Do it. Send the same message with and without the header and compare responses. If the header degrades response quality, we have a problem.
3. **Consider making the header a system message instead of prepending to user text** — but the spec deliberately avoids gateway changes, so this isn't an option in Phase 1. Accept the risk and test thoroughly.

**Bottom line:** If the agent convention is followed and tested, the risk is low. If it's not, the first response in every topic after a restart will feel slightly more robotic. That's unacceptable.

**Condition for green light:** The agent convention must be tested with at least 3 real topics and 2 models before merge. Not "looks good in theory" — actual side-by-side comparison of responses.

---

## Summary

| Decision | Verdict | Action |
|----------|---------|--------|
| 1. Zero UI | ✅ Correct | No change |
| 2. Header format | ✅ Correct, tweak convention | Strengthen "don't acknowledge" guidance |
| 3. `projectPath` column | ❌ Defer | Remove from Phase 1 |
| 4. `TopicMetadata` struct | ❌ Defer | Remove from Phase 1 |
| 5. Feature flag | ❌ Remove | No user-facing toggle needed |
| 6. Simplest version | ⚠️ Almost | Cut 3 elements, simplify header |
| 7. Phase split | ⚠️ Adjust | Move backend for unused fields to 1.5 |
| 8. UX risk | ⚠️ Monitor | Test agent convention before merge |

**Overall: GREEN LIGHT with conditions.**

Cut `projectPath`, `TopicMetadata`, and the feature flag from Phase 1. Simplify the header to Topic-only. Strengthen the agent convention. Test responses before merge. That's it.

The core mechanism — `contextInjectedKeys` + `buildContextHeader` + injection block — is solid. It's the future-proofing cruft around it that needs trimming.

---

*Mel — 2026-05-08*
