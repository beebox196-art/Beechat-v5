# Review: Fix B Implementation — Streaming State Machine

**Reviewer:** Kieran (independent)  
**Date:** 2026-05-10  
**Spec:** `SPEC-FIX-B-streaming-state.md` v1.1  
**Verdict:** ✅ **APPROVE**

---

## Verification Matrix

| # | Change | Spec Requirement | Implemented | Status |
|---|--------|-----------------|-------------|--------|
| B1a | `didStartStreaming` — agent activity tracking before guard | `self.agentActivityTracker.didStartStreaming` before the mismatch check | ✅ Line 88: called before `if normalizedIncoming != normalizedCurrent` | ✅ |
| B1b | `didStartStreaming` — background session tracks `streamingSessionKey` | Set `streamingSessionKey = sessionKey` when `!isStreaming` in mismatch branch | ✅ Lines 95–99: `if !self.isStreaming { self.streamingSessionKey = sessionKey }` | ✅ |
| B1c | `didStartStreaming` — "last wins" comment + Fix B2 reference | Comment explaining last-wins behavior and referencing future Fix B2 | ✅ Lines 93–96: Full comment present | ✅ |
| B1d | `didStartStreaming` — active topic path unchanged | Cancel thinking timeout, set isStreaming/streamingSessionKey/thinkingState, start poll, start timeout | ✅ Lines 102–109: All present, order matches spec | ✅ |
| B2a | `didStopStreaming` — branch 1: streamingSessionKey match → reset | `if normalizedSessionKey(streamingSessionKey ?? "") == normalizedIncoming` → `resetStreamingState()` | ✅ Lines 124–127 | ✅ |
| B2b | `didStopStreaming` — branch 2: background not tracked → log | `else if normalizedIncoming != normalizedCurrent` → log only | ✅ Lines 128–130 | ✅ |
| B2c | `didStopStreaming` — branch 3: defensive else → reset | `else` → defensive reset with log | ✅ Lines 131–134 | ✅ |
| B2d | `didStopStreaming` — agent activity tracker always updated | Before branching logic | ✅ Line 118: `self.agentActivityTracker.didStopStreaming(sessionKey: sessionKey)` | ✅ |
| B3 | `catchUpStreaming(for:)` | Sets thinkingState, isStreaming, streamingSessionKey, starts poll, starts timeout, logs | ✅ Lines 160–167: All 6 steps present, not private | ✅ |
| B4 | `sidebarSelection` — catch-up on topic switch | `if let key = newSessionKey, syncBridgeObserver.isStreamingSession(key)` → `catchUpStreaming` | ✅ Lines 33–35 | ✅ |
| B5 | No unintended changes | Other methods untouched | ✅ Spot-checked `resetStreamingState`, `startStreamingPoll`, `startStreamingTimeout`, `startThinkingTimeout`, `isStreamingSession`, `clearUnread`, `normalizedSessionKey`, connection handler, error handler — all match pre-existing logic | ✅ |

---

## Detailed Observations

### didStartStreaming (Lines 80–111)
- ✅ `agentActivityTracker.didStartStreaming` called unconditionally before the mismatch guard — this means even background sessions are tracked for agent activity display, which is correct.
- ✅ The `!self.isStreaming` guard prevents overwriting an active streaming session's key with a background one. This is the "last background wins" behavior documented in the comment.
- ✅ The comment explicitly calls out the `Set<String>` limitation and references "future Fix B2" — matches spec.

### didStopStreaming (Lines 116–135)
- ✅ Three-branch structure matches spec exactly. The `normalizedSessionKey` comparison uses the same normalizer as `didStartStreaming`, so session key format differences (with/without prefix, case) are handled consistently.
- ✅ The defensive `else` branch handles the edge case where `streamingSessionKey` was overwritten by a background session, so the current topic's stop event would otherwise be lost.

### catchUpStreaming (Lines 160–167)
- ✅ Access level is internal (no `private` modifier) — correct, it needs to be callable from `MainWindow`.
- ✅ Calls `cancelThinkingTimeout()` first, then sets all streaming state, then starts poll and timeout. Order matches spec.
- ✅ Log message matches spec text.

### sidebarSelection (Lines 27–36)
- ✅ `newSessionKey` extracted once and reused for `currentSelectedSessionKey`, `clearUnread`, and the `catchUpStreaming` check — avoids repeated optional chaining.
- ✅ The `isStreamingSession` check uses the observer's method which normalizes both keys, so format mismatches won't cause false negatives.

### Unintended Changes Check
- No modifications to `resetStreamingState`, polling logic, timeout durations, `AgentActivityTracker`, or any other method. The diff is clean — only the four specified changes plus the `isStreamingSession` method (which was pre-existing).

---

## Edge Cases Considered

1. **Race: didStopStreaming arrives while user is mid-switch** — `catchUpStreaming` sets `isStreaming = true` and starts a new poll. If `didStopStreaming` arrives first and resets, the user sees idle (correct — stream ended). If `catchUpStreaming` runs first, `didStopStreaming` will reset via branch 1 (streamingSessionKey match). Both paths are safe.

2. **Multiple background streams** — Only the last one's `streamingSessionKey` is tracked (documented limitation). Agent activity tracker still tracks all of them. This matches the spec's known limitation note.

3. **Empty string streamingSessionKey** — `normalizedSessionKey("")` strips prefix and lowercases, yielding `""`. This won't accidentally match a real session key. Safe.

4. **nil streamingSessionKey** — The `?? ""` fallback in `didStopStreaming` branch 1 normalizes to `""`, which won't match any real key. Branch 3 (defensive else) would then fire if the current topic stopped, correctly resetting. Safe.

---

## Verdict: **APPROVE**

The implementation matches the approved spec in every detail. No unintended changes. No missing logic. Edge cases are handled. Ready to ship.