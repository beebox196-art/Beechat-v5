# Mel's Review — BC5-SPEC-004 v2

**Reviewer:** Mel (UX)  
**Date:** 2026-05-08  
**Verdict:** ✅ Approve Phase 1 with minor notes

---

## 1. Does the user experience improve with zero UI?

**Yes, genuinely.** The core insight is solid: the agent "just knowing" what topic you're in is a better experience than any UI indicator. Users already named the topic — that's the signal. Surfacing it to the agent via a hidden header is the right move.

The `[TOPIC-CONTEXT]` header approach means:
- User opens "Topcon-Eval" topic → agent says something like "Working on the Topcon evaluation?" instead of "How can I help?"
- No onboarding, no settings, no toggle to explain
- The improvement is felt, not seen

**One subtlety:** The agent's first response should feel natural, not robotic. If the agent starts every topic with "I see we're in the Hex Trading topic, your active focus is…" that's worse than nothing. The spec's agent convention covers this ("acknowledge briefly, don't repeat verbatim") — good. But it's worth calling out that this is the single point where the feature lives or dies UX-wise. If the agent parrots the header, users will hate it. The convention needs to be tested with real conversations, not just documented.

---

## 2. Is anything missing from a UX perspective?

**Almost nothing — but one thing nags me.**

When the context header fires after an app restart, the user has no indication it happened. That's fine — it's invisible by design. But there's an edge case: if the user has multiple BeeChat windows open (or reopens the app and sends quickly to the wrong topic), the context injection fires based on session key, not on what the user *thinks* they're in.

This is extremely low-risk because:
- Session keys already bind to the correct topic
- The user literally typed into that topic's input field
- Multiple windows share the same `SyncBridge` instance so `contextInjectedKeys` tracks correctly

No action needed. Just flagging that "invisible UX" means the user can't debug it if something feels off. The feature flag helps — if context injection causes weird agent behaviour, the user can turn it off. That's a reasonable escape hatch.

**Minor suggestion:** Consider a brief log entry or debug-mode indicator for the context injection. Not a UI element — just something that shows up in a hypothetical debug console. Phase 1 doesn't need this; flag for Phase 1.5 if users report confusion.

---

## 3. Is the Phase 1 / Phase 1.5 split sensible?

**Yes, this is exactly right.**

The v1 spec had UI mixed into Phase 1 and it was the weakest part. v2 cleanly separates:

| Phase | What | Why |
|-------|------|-----|
| Phase 1 | Backend context injection | Ship it, validate the agent behaviour, gather feedback |
| Phase 1.5 | UI chrome (folder picker, sidebar icons, topic settings) | Add controls once we know what users actually need |
| Phase 2 | Resume context button | Defer entirely |

This is the correct sequencing. Shipping UI before validating the backend feature is how you build features nobody uses. The "validate, then chrome" approach is mature.

**One Phase 1.5 callout:** The 📁 icon inline with the title at 0.6 opacity (from the synthesis) is the right approach. Dots are already crowded. Inline icon is subtle, scannable, doesn't add visual weight. 👍

---

## 4. Is anything still overcomplicated from a UX angle?

**No.** The v2 spec is dramatically simpler than v1. The removals are exactly right:

- ❌ `chat.inject` RPC — gone (didn't exist, wasn't needed)
- ❌ `needsContextInjection()` with gateway calls — gone (replaced by in-memory set)
- ❌ Phase 2 auto-trigger — gone (deferred to button-only)
- ❌ New-topic sheet UI changes — gone (Phase 1.5)

What's left is: a text prefix on the first message of a topic session. That's as simple as it gets.

The `TopicMetadata` struct (activeFocus, tags) feels slightly speculative since Phase 1 has no UI to set them and they'll always be nil. But since they're `try?` decoded and silently omitted from the header, there's no UX or complexity cost. It's forward-compatible scaffolding — acceptable.

---

## Summary

| Question | Answer |
|----------|--------|
| Does zero-UI improve UX? | Yes. Agent "just knowing" > any indicator. |
| Missing UX? | No critical gaps. Agent response naturalness is the key variable — test it. |
| Phase split sensible? | Yes. Backend-first is correct. |
| Still overcomplicated? | No. v2 is clean and minimal. |

**Approve.** Ship Phase 1, watch how the agent uses the context header in real conversations, then design Phase 1.5 UI based on evidence.