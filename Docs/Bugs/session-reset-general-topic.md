# Bug: Session Reset on General Topic Resets Wrong Session

**Status:** Root cause identified  
**Severity:** High — user-facing data loss risk (wrong session archived)  
**Date:** 2026-06-22  
**Affected:** BeeChat v5 (macOS app + SyncBridge)

## Symptoms

- Tapping the amber/orange "Reset Session" dot on the **General** topic (topic:1 in the Telegram group) appears to succeed but does NOT actually reset the topic:1 session.
- The orange-dot indicator persists after reset because the wrong session was archived.
- A **different session** (webchat subagent/cron key `491ea8d6...`) gets archived instead, losing its conversation history.
- The `sessions.json` mapping for `agent:main:telegram:group:-1003830552971:topic:1` continues pointing to the old session `b93cfcd2`, which was never reset.

## Root Cause

**Session key mismatch between the macOS app's local SQLite database and the gateway's canonical session keys.**

### The Chain of Events

1. The macOS app stores topics with locally-generated UUID session keys in its local SQLite `topics` table:
   - **Local DB:** `General` → `agent:main:491ea8d6-9527-4e71-89b4-d0a06df3f49d` (UUID format)
   
2. The gateway uses canonical, format-aware session keys that encode the Telegram group/thread structure:
   - **Gateway:** `agent:main:telegram:group:-1003830552971:topic:1`

3. These are **two completely different keys** that refer to two **different sessions** in `sessions.json`:
   - `agent:main:491ea8d6...` → mapped to session `d557fa18-c42b-45f3-865a-591710432225` (webchat channel)
   - `agent:main:telegram:group:-1003830552971:topic:1` → mapped to session `b93cfcd2-ec72-4fd8-9ca6-ae7aa02f7fba`

4. When the user taps "Reset Session" on the General topic, `MainWindow.swift` line 520 passes `topic.sessionKey` to `SyncBridge.manualReset()`. This value comes from the local SQLite `topics.sessionKey` column — which holds the UUID key `491ea8d6...`.

5. `SyncBridge.manualReset()` → `resetSession()` → `RPCClient.sessionsReset()` sends `sessions.reset` with `key = "agent:main:491ea8d6-9527-4e71-89b4-d0a06df3f49d"`.

6. The gateway resolves this to the canonical key for that entry (which maps to `d557fa18`), archives it, and creates a new session for the `491ea8d6...` key — **not** for `topic:1`.

7. The `agent:main:telegram:group:-1003830552971:topic:1` entry in `sessions.json` is **never touched**. Session `b93cfcd2` remains active and unchanged.

### Why the Orange Dot Persists

After `manualReset()`, the code:
1. Sets `sessionUsageCache[sessionKey] = 0` (for the UUID key, not topic:1)
2. Runs `UPDATE sessions SET totalTokens = NULL WHERE id = ?` using the UUID key

But `MessageViewModel.startSessionUsageObservation()` observes `totalTokens` on the **gateway-keyed row** (`agent:main:telegram:group:-1003830552971:topic:1`), which was never modified. The orange dot reads from `sessionUsageMap`, which is refreshed from the sessions table — the UUID-keyed row update is invisible to it.

### Why Topic:1185 Works

Topic 1185 was reset successfully because:
- Its local DB key (`agent:main:7c24fe58-084f-4fe5-8de2-23e558acbbf1`) is a **post-reset** key that was created fresh by the gateway during a prior reset cycle
- More importantly, the `sessions.json` entry for topic:1185 includes `usageFamilySessionIds` tracking the rotation chain, suggesting the session key alignment may have been corrected at some point

### Evidence

| Artifact | Value | Explanation |
|---|---|---|
| `d557fa18` archive | `d557fa18-...-topic-1.jsonl.reset.2026-06-22T16-35-50.856Z` | Wait — actually the filename has NO `-topic-1` suffix! It's just `d557fa18-c42b-45f3-865a-591710432225.jsonl.reset...` |
| `b93cfcd2` status | Still live, NOT archived | Confirms topic:1 was never reset |
| `sessions.json` topic:1 | Still maps to `b93cfcd2` | Gateway mapping unchanged |
| Local SQLite `topics` table | `General` → `491ea8d6...` (UUID key) | Wrong key used for reset |
| Local SQLite `sessions` table | Has BOTH keys as separate rows | Both `topic:1` and `491ea8d6` exist as distinct sessions |

## Fix

### Option A: Key Alignment on Sync (Recommended)

When `fetchSessions()` receives sessions from the gateway, match gateway session keys back to local topics and update `topics.sessionKey` to the gateway's canonical key. This ensures the local DB always uses the same key the gateway uses.

**Implementation:**
1. In `SyncBridge.fetchSessions()`, after receiving sessions from the gateway, check each session's key against local topics.
2. If a gateway session has a Telegram group key like `agent:main:telegram:group:-<groupId>:topic:<threadId>`, match it to the local topic by `groupId` + `threadId` (stored in topic metadata or derivable from the delivery context).
3. Update `topics.sessionKey` to the gateway's canonical key if they differ.
4. Also update the `topic_session_bridge` table to map the old UUID key → gateway key.

**Risk:** Low. This is a data consistency fix that ensures the app and gateway use the same key.

### Option B: Key Resolution in manualReset

Before calling `sessions.reset`, resolve the local session key to the gateway's canonical key by:
1. Checking if the key exists in `sessions.json` (via a new RPC or local cache).
2. If not found, look up the topic's Telegram group/thread metadata and construct the canonical key.
3. Pass the canonical key to `sessions.reset`.

**Risk:** Medium. Requires knowing how to construct canonical keys, which couples the client to gateway key format internals.

### Option C: Fix the Local Session Key at Topic Creation

Ensure that when a Telegram topic is first created or discovered, the local DB stores the gateway's canonical key (`agent:main:telegram:group:-...:topic:N`) rather than generating a UUID key.

**Risk:** Medium. Requires migration of existing topics. But this is the cleanest long-term solution.

### Recommended: Option A + C Combined

1. **Immediate fix (Option A):** Add key alignment in `fetchSessions()` to update stale UUID keys to canonical keys.
2. **Long-term fix (Option C):** When creating topics from Telegram group messages, use the canonical gateway key from the start instead of generating local UUIDs.

## Test Plan

1. **Reproduce:** Open BeeChat, navigate to General topic (topic:1), tap "Reset Session" (amber dot). Verify that the gateway receives `sessions.reset` with key `agent:main:telegram:group:-1003830552971:topic:1` (not a UUID).
2. **Verify sessions.json:** After reset, check that `sessions.json` now maps topic:1 to a new sessionId, and the old `b93cfcd2` session file is archived.
3. **Verify orange dot:** After reset, confirm the orange dot clears (totalTokens set to NULL for the correct row, GRDB observation fires).
4. **Verify no side effects:** Confirm no other session (especially `491ea8d6`/webchat) was archived by mistake.
5. **Regression:** Reset topic:1185 and verify it still works correctly with the canonical key format.

## Impact Assessment

- **Data impact:** The `d557fa18` session (webchat key `491ea8d6...`) was incorrectly archived during the user's reset attempt. Its conversation data is preserved in the `.reset` archive file but is no longer live.
- **User impact:** The General topic (topic:1) still has its full old conversation and the reset had no effect. The orange dot persists. The user likely believes the reset happened but their conversation wasn't actually reset.
- **Scope:** All locally-created topics (those with UUID keys instead of canonical gateway keys) are affected. In the local DB, 14 out of 14 topics use UUID keys — they are ALL susceptible to this mismatch. Telegram-sourced sessions that bypass local creation (like topic:1185, topic:2) may have been aligned by a prior sync, but newly created local topics won't be.
- **Urgency:** High. Every manual reset on a locally-created topic destroys a wrong session and fails to reset the intended one.

## Files

- **SyncBridge.swift:** `manualReset()` line 415, `resetSession()` line 406, `fetchSessions()` line 188
- **RPCClient.swift:** `sessionsReset()` line 87
- **MainWindow.swift:** `resetTargetSessionKey = topic.sessionKey` line 520
- **TopicRepository.swift:** `create()` line 12 (UUID key generation), `resolveSessionKey()` line 204
- **Gateway:** `performGatewaySessionReset()` in `session-reset-service-BOn9y-zP.js`
- **Gateway:** `resetSessionEntryLifecycle()` in `store-CnMhVMz1.js`
- **Local DB:** `BeeChat.sqlite` — `topics` table (UUID keys), `sessions` table (mixed keys), `session_key_mapping` table (empty)