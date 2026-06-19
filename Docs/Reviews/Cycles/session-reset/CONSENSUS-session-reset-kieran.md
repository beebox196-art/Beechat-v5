# Kieran's Adversarial Review: Session Reset Options

**Reviewer:** Kieran (adversarial)  
**Date:** 2026-05-14  
**Spec:** SPEC-session-reset-options.md  
**Verdict:** Option B is viable, but the pending-state concern is **real and has teeth**. The hybrid (Option C) is actually the cleanest path — not because it's simpler, but because it eliminates the worst failure mode while preserving user control.

---

## 1. The Pending-State Concern in Option B

### The Problem

Option B introduces `pendingResetContext: [String: String]` — a dictionary mapping session keys to pre-formatted context payloads. The reset happens on tap, but the context payload is only injected on the *next send*. This creates a window between reset and send where state is in limbo.

**Is this a real risk?** Yes. Here are the concrete failure modes:

#### Failure Mode 1: Crash Between Reset and Send

The user taps the red dot → `manualReset()` runs → session is reset on the gateway → context payload stored in `pendingResetContext` → **app crashes** before the user sends a message.

Result: The gateway session is wiped. The pending context is in-memory only (SyncBridge is an actor, no persistence). On restart, `pendingResetContext` is empty. The conversation history is gone and the context is gone. **This is data loss.**

Auto-reset (Option A) doesn't have this problem because the reset and the send are atomic within a single `sendMessage()` call. If the send fails, the reset never happened (it's gated behind the usage check). If the app crashes mid-send, the delivery ledger records the attempt and the message can be retried — the context is never orphaned.

#### Failure Mode 2: Topic Switch During Pending State

User taps reset on Topic A → `pendingResetContext["A"]` is set → user switches to Topic B → user switches back to Topic A → sends a message.

Does the pending context for A still apply? The spec says "if the user switches topics before sending, we clear the pending context." But looking at the current code, **there is no topic-switch hook that clears `pendingResetContext`**. The sidebar selection change handler in `MainWindow` (line ~47) updates `messageViewModel.selectedTopicId` and clears unread counts — it would need a new call to `syncBridge.clearPendingReset(sessionKey:)`.

This is an easy fix, but it's a new invariants tax: every topic-switch path must clear pending state. Miss one, and the user sends a message with stale context from a reset they may not even remember triggering.

#### Failure Mode 3: Race — Rapid Tap + Send

User taps reset → `manualReset()` is async (it calls `rpcClient.sessionsReset`) → user immediately types and sends before the RPC completes.

`sendMessage()` checks `pendingResetContext[sessionKey]` — it's empty because the reset hasn't finished yet. The message goes through on the **already-reset** session with **no context payload**. The pending context is then written *after* the send, and sits there forever until the next send picks it up — injecting stale history into a conversation that's already moved on.

This is the nastiest failure mode because it's silent. The user has no indication that their first message after reset was sent without context.

#### Failure Mode 4: Double-Tap

User taps red dot twice quickly. `manualReset()` is called twice. The second call resets an already-reset session and fetches empty local history (because `fetchLocalHistory()` returns nothing after a fresh reset). The pending context is now empty or near-empty, and the *first* pending context is overwritten.

**Mitigation:** `manualReset()` needs a guard — if `pendingResetContext[sessionKey]` already exists, either ignore the tap or replace the payload. But even with the guard, the first reset's RPC may still be in-flight, so `fetchLocalHistory()` might return stale data.

---

## 2. Is the Hybrid Worth It?

The spec asks: "Is a hybrid (auto at 80%, manual at 50%) worth the extra complexity?"

**Yes, but not for the reason the spec suggests.** The hybrid isn't about giving the user "the best of both worlds." It's about **eliminating the worst failure mode** — the crash-between-reset-and-send data loss in Option B.

### How the Hybrid Solves the Problem

- **Below 80%:** The red dot appears at 50%. User can tap to manually reset. This uses the pending-context path from Option B. If the app crashes, the context is lost, but the session is still below 80% — the user hasn't hit the ceiling, and the next message will still work (just without the context summary).

- **At 80%:** Auto-reset fires atomally inside `sendMessage()`. No pending state. No crash window. No data loss risk for the critical case.

This is the key insight: **the hybrid makes pending state failures non-catastrophic**. If you lose the pending context between 50-80%, the session still works — you just don't get the context summary. At 80%+, the auto-reset guarantees atomicity and you never lose data.

### But Is It More Complex?

Looking at the code, the hybrid is actually **not much more complex than Option B alone**:

- Option B requires: disable auto-reset in `sendMessage`, add `manualReset()`, add `pendingResetContext`, inject pending context into `sendMessage`, wire UI, add context menu, handle crash/race guards.
- Hybrid requires: keep auto-reset in `sendMessage` but change the threshold from 50% to 80%, *then* add everything from Option B on top.

The incremental complexity over Option B is: changing one constant (0.50 → 0.80) and keeping the auto-reset code path that already exists. That's literally one line change (`redDotThreshold` stays 0.50, add a new `autoResetThreshold = 0.80`).

The complexity tax is the same pending-state concerns from Option B. But now the consequences of those failures are bounded — the session never bricks, because the 80% safety net catches it.

---

## 3. Failure Modes I Haven't Seen Discussed

### A. The Cooldown Interaction

The current auto-reset has a 5-message cooldown (`resetCooldownMessages = 5`). In the hybrid model:
- User manually resets at 60% → cooldown starts → usage drops to ~0% after reset → usage climbs back to 80% during cooldown → auto-reset is blocked for 5 messages.

This means the safety net has a 5-message gap. If usage grows fast (long messages, tool-heavy conversations), the session could hit 100% during cooldown and the message would fail.

**Fix:** Make the auto-reset threshold override the cooldown. If usage ≥ 80%, always reset regardless of cooldown. The cooldown should only apply to the manual reset path (preventing double-tap issues) and the auto-reset path at 50%.

Actually, simpler: the cooldown exists to prevent reset *loops* (reset → short history → usage still high → reset again). But at 80%, the post-reset usage will always be low because we're injecting 30 messages worth of context (which is far less than whatever brought it to 80%). The cooldown is solving a problem that doesn't exist at 80%.

**Recommendation:** Remove the cooldown for auto-reset at the 80% ceiling. Keep it only for the 50% auto-reset (if that path is even retained in the hybrid — I'd argue it shouldn't be, since manual replaces it).

### B. `contextInjectedKeys` Never Gets Cleared on Manual Reset

Looking at `resetSession()` (line ~195):
```swift
contextInjectedKeys.remove(sessionKey)  // re-inject on next send
```

This is correct for auto-reset — it ensures topic context is re-injected after the session is wiped. But in Option B, `manualReset()` calls `resetSession()`, which clears `contextInjectedKeys`. Then on the next send, `sendMessage()` will inject topic context *and* the pending reset context. Both will be prepended.

Is this a problem? The `[SESSION-CONTEXT]` block and the `[TOPIC-CONTEXT]` header are both injected. They're not conflicting — they're complementary. But the user's message will have two separate context blocks prepended, which is more token usage than either alone.

**For the hybrid, this is fine** — the context is only injected once after reset, and the combined payload is bounded by the 100K char limit in `formatCombinedContext`. But it's worth noting that the effective context budget for the *user's actual message* shrinks after a reset.

### C. `fetchLocalHistory()` After Reset Returns Empty

In `manualReset()`, the sequence is: (1) fetch local history, (2) reset session on gateway, (3) format context, (4) store in `pendingResetContext`.

But what if `fetchLocalHistory()` is called *after* the reset RPC completes instead of before? The local SQLite still has the messages (they're not deleted locally). So this is fine — the local history survives the gateway reset. **But only because we're reading from local storage, not from the gateway.** If anyone changes `fetchLocalHistory` to call the gateway's `chatHistory` RPC, the history would be empty after reset. This is a hidden coupling that should be documented.

### D. Sidebar Refresh After Manual Reset

After a manual reset, the gateway session is cleared, but the local topic's message count, last activity, and session usage are stale. The UI needs to:
1. Clear the message list (or show empty state)
2. Reset the usage indicator
3. Update the red dot to show 0%

Looking at the current code, `sessionUsageCache` in SyncBridge is the source of truth for the red dot. `manualReset()` would need to update this cache to 0 after a successful reset. But the `sidebarSelection` binding in MainWindow doesn't trigger a usage re-poll — `startUsagePolling` only runs on `start()` and for newly fetched sessions.

**Fix:** `manualReset()` should call `pollSessionUsage()` after reset to update the cache, and the observer should fire a delegate callback so the UI refreshes.

### E. The Delivery Ledger Entry Created During Auto-Reset Has the Wrong Content

Minor but worth noting: when auto-reset fires, `sendMessage()` creates a `DeliveryLedgerEntry` with `content: effectiveText` (the combined context + user message) and `originalContent: text` (just the user message). If the send fails and is retried, the retry would use `effectiveText` — which includes the context summary from the *original* reset. If usage has climbed again between the failure and retry, the retry would use stale context. This is unlikely to cause problems in practice, but it's another case where auto-reset's atomicity helps and the pending-state approach would need similar care.

---

## Summary Verdict

| Concern | Option A | Option B | Hybrid |
|---|---|---|---|
| Crash data loss | None (atomic) | **Real risk** | Mitigated (80% safety net) |
| Topic-switch stale state | N/A | Needs explicit cleanup | Same as B |
| Rapid tap + send race | N/A | Silent context loss | Same as B, but bounded |
| Double-tap | N/A | Needs guard | Same as B |
| Cooldown vs. safety net | Works at 50% | N/A | Needs tuning (remove at 80%) |
| Code complexity | ~14 lines | ~90 lines | ~95 lines |
| User control | None | Full | Full + safety net |

**My recommendation:** Go with the hybrid. It's 5 lines more than Option B, eliminates the catastrophic failure mode (crash between reset and send at high usage), and gives Adam the manual control he asked for. The failure modes in Option B that remain (stale context, double-tap) are annoying but not data-loss scenarios because the 80% auto-reset catches the worst case.

**But** — if the hybrid is rejected and the choice is strictly A vs B, I'd pick **Option A**. The pending state in Option B is a latent bug. The crash-between-reset-and-send scenario will happen eventually, and when it does, the user loses their entire conversation context with no recovery path. Option A's lack of user control is a UX downgrade, but it's not a data-loss risk.

### Specific Recommendations for the Hybrid Implementation

1. **Rename thresholds:** `redDotThreshold = 0.50` (stays, triggers the red dot), add `autoResetThreshold = 0.80` (new, triggers auto-reset). Remove the cooldown only for the 80% path.

2. **`manualReset()` must be atomic with the next send:** Instead of storing pending context in a dict, consider making `manualReset()` a suspend function that: (a) fetches history, (b) resets session, (c) returns the context payload to the caller, which then prepends it to the next message in the UI layer before calling `sendMessage()`. This way, there's no in-memory pending state — the context lives in the UI's compose flow, not in SyncBridge's mutable state. If the app crashes, the context is lost, but the session is low-usage and the next send works fine.

   Actually, this doesn't fully work either — the user might compose a message, tap reset, and then the context needs to be attached to *that composed message*. If they clear the compose field, the context is lost. This is a UX design question, not just a code question.

3. **Guard `manualReset()` against double-tap:** Check if a reset is already in progress for the session key. Return early if so.

4. **Document the local-only coupling in `fetchLocalHistory()`:** Add a comment that this deliberately reads from SQLite, not the gateway, and that changing it would break the reset flow.

5. **Wire `pollSessionUsage()` after manual reset:** So the red dot updates immediately.

6. **Add a context menu item for "Reset Session"** in the sidebar (already in the spec for Option B — confirming it's needed for the hybrid too).