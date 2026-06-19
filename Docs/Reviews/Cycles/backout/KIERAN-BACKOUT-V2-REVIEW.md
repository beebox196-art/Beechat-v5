# Kieran Adversarial Review — GATE-2F-BACKOUT.md v2

> **Date:** 2026-05-28  
> **Reviewer:** Kieran (adversarial)  
> **Verdict:** **CONDITIONAL PASS** — 3 blockers, 2 concerns

---

## Previous Blocker Verification

### B1 (ATS/HTTPS) — ✅ ADDRESSED

The REST spec (GATE-2F-REST-OVER-TAILSCALE.md v2) now uses Tailscale Serve with HTTPS, NWListener binds to localhost only, and the iPhone derives the URL from the gateway domain. The backout spec doesn't need to account for the URL change since the REST spec builds on top of the clean foundation.

### B2 (Dead code) — ✅ ADDRESSED

All previously-kept dead code is now in the removal list:
- `publishTopicState()`, `clearTopicState()`, `clearTopicStateWithResult()`, `fetchActiveSessionKeys()`, `reconcileAllTopicState()`, `verifyAdminScope()`, `hasAdminScope()` — all listed for removal
- `TopicPublishQueue.swift` — listed for deletion
- `BeeChatTopicMetadata.swift` — listed for deletion
- `sessionsPluginPatch` — listed for removal from RPCClient

However, see **B6** below — the spec still says "keep" for two items that are dead code.

### B3 (Type ownership) — ✅ ADDRESSED

§10 is explicit: iPhone types stay (refactored to `TopicTypes.swift`), Mac types are removed, no shared package changes needed.

### B4 (Orphaned session) — ✅ ADDRESSED

§12 includes gateway cleanup step to reset `agent:main:beechat-sync`.

### B5 (UserDefaults) — ✅ ADDRESSED

§13 includes one-time cleanup of `beechat_lastSyncTimestamp`.

---

## NEW BLOCKERS

### B6: `fetchSessionInfos()` and `pluginExtensions` are dead code — listed as "keep"

The spec says to **keep** `fetchSessionInfos()` (§11, "What We Keep" table) with the justification "Wraps `sessionsList()` — used for session management, not just sync."

**This is wrong.** I verified: `fetchSessionInfos()` is defined at `SyncBridge.swift:976` and has **zero callers** anywhere — not in the Mac app, not in the iPhone, not in any shared package code, not in the integration test. It was only used by the now-removed `ensureSyncSessionExists()`.

The comment above it says "Returns raw SessionInfo list including pluginExtensions" — but with `BeeChatTopicMetadata` removed, `pluginExtensions` is just a dead field. See B7.

**Fix:** Remove `fetchSessionInfos()` from SyncBridge.swift. It's 3 lines of dead code that can be re-added as a one-liner wrapper if ever needed.

### B7: `pluginExtensions` on `SessionInfo` should be flagged for removal

After removing `BeeChatTopicMetadata` and `beechatMetadata`, the `pluginExtensions` field on `SessionInfo` has no consumers. The only references to it are:

1. `SessionInfo.beeshatMetadata` computed property — being removed (spec §5)
2. `BeeChatTopicMetadata.swift` doc comment — being deleted (spec §3)
3. `SyncBridge.fetchSessionInfos()` doc comment — being removed (B6 above)

The field itself (`public let pluginExtensions: [String: [String: AnyCodable]]?`) is decoded from the gateway response, so removing it would change the `SessionInfo` struct's `Codable` conformance. This is risky — if the gateway sends `pluginExtensions` in a response, `Codable` will just ignore the unknown key anyway (it's `Optional`). But removing the field means we silently drop data we could use later.

**Fix:** Don't remove `pluginExtensions` from `SessionInfo` now — it's part of the gateway response schema and could be used for other plugin data in the future. But **add a note** in the spec that it's currently unused and could be cleaned up in a future pass. The `Codable` conformance means removing it would change the decoding behaviour, which is unnecessary churn.

**Update:** Actually, since `pluginExtensions` is `Optional` and uses `decodeIfPresent`, removing it from the struct is safe — the decoder will just skip the field. But it's still unnecessary churn. **Recommendation: leave it.** Add a comment noting it's unused after the backout.

### B8: `sessionsPatch` and `chatInject` should be evaluated for removal

**`sessionsPatch`**: The spec lists this in "What We Keep" with the reason "Used for topic label updates." I searched the entire codebase. The **only caller** of `sessionsPatch()` outside its own definition is in `publishTopicState()` at `SyncBridge.swift:843`:

```swift
let labelOk = try await self.rpcClient.sessionsPatch(
```

That's inside the `publishTopicState()` method, which we're removing. There are **zero other callers** in the app code, integration tests, or iPhone code.

**Fix:** Move `sessionsPatch` from the KEEP list to the REMOVE list. It's dead code after the backout. Remove it from `RPCClientProtocol` (line 14) and `RPCClient` (lines 159-166).

**`chatInject`**: The spec lists this in "What We Keep" with the reason "Used for session reset context injection." I searched the entire codebase. The **only caller** of `chatInject()` outside its own definition is in `performPublish()` at `SyncBridge.swift:1050`:

```swift
_ = try await rpcClient.chatInject(
```

That's inside the `performPublish()` method, which we're removing. There are **zero other callers** in the app code, integration tests, or iPhone code.

**Fix:** Move `chatInject` from the KEEP list to the REMOVE list. It's dead code after the backout. Remove it from `RPCClientProtocol` (line 16) and `RPCClient` (lines 193-210).

**Note:** Both `sessionsPatch` and `chatInject` are defined in `RPCClientProtocol` (the protocol) AND `RPCClient` (the implementation). Both must be removed from both locations.

---

## CONCERNS

### C1: Removal order — steps 5 and 8 need clarification

Step 5 removes all methods/types from SyncBridge. Step 8 removes `sessionsPluginPatch` from RPCClient. But `sessionsPatch` and `chatInject` are also in RPCClient. If we add them to the removal list (per B8), they should be removed in the same step (step 8) since they follow the same pattern as `sessionsPluginPatch`.

The spec should explicitly list all three RPC methods being removed in step 8:
- `sessionsPluginPatch` (protocol + implementation)
- `sessionsPatch` (protocol + implementation)
- `chatInject` (protocol + implementation)

### C2: `ChatHistoryMessage` has a known bug but is kept — document it

The spec keeps `ChatHistoryMessage` (in "What We Keep") which is correct — it's used by `fetchHistory()`. But we know from the earlier investigation that `ChatHistoryMessage.content` is typed as `String` while the gateway returns content as `[{"type": "text", "text": "..."}]` for assistant messages. This is a latent bug that will surface when we build the REST client and any future feature that reads chat history for assistant messages.

This is **not a blocker for the backout** — `ChatHistoryMessage` is not sync-specific. But it should be documented as a known issue for the REST spec to address.

---

## EDGE CASES

### What happens after backout, before REST is built?

**Mac app:** Works exactly as before. All messaging, topic management, sidebar — unchanged. The only thing removed is sync publishing, which was broken anyway (gateway rejects `sessionsPluginPatch`, `chat.inject` triggers agent responses).

**iPhone app:** Falls back to standalone mode. Local topics still work. The `connect()` method skips the sync payload read (stubbed with `// TODO: REST topic fetch`). The `didReceiveSessionChange` delegate method has the `beechat-sync` filter removed, so it won't try to read from a gateway session that no longer exists. This is safe — the iPhone just operates on its local data until the REST client is built.

**No crashes, no data loss, no dead code.** This is a clean backout.

---

## REMOVAL ORDER VERIFICATION

I verified the 18-step removal order against the codebase:

| Step | What | Safe? | Why |
|------|------|-------|-----|
| 1 | Remove UI calls from AppRootView | ✅ | Methods still exist in SyncBridge |
| 2 | Remove UI calls from MainWindow | ✅ | Methods still exist in SyncBridge |
| 3 | Remove UI calls from SyncBridgeObserver | ✅ | Methods still exist in SyncBridge |
| 4 | Build verify (Mac) | ✅ | — |
| 5 | Remove all methods/types from SyncBridge | ✅ | No UI callers remain after steps 1-3 |
| 6 | Delete TopicPublishQueue.swift | ✅ | `publishQueue` property removed in step 5 |
| 7 | Delete BeeChatTopicMetadata.swift | ✅ | Only referenced by removed code + SessionInfo.be |
| 8 | Remove RPC methods from RPCClient | ✅ | Only callers were removed methods |
| 9 | Remove beechatMetadata from SessionInfo | ✅ | Only referenced by removed code |
| 10 | Build verify (Mac) | ✅ | — |
| 11 | Remove ViewModel sync code | ✅ | iPhone-only changes |
| 12 | Stub connect() | ✅ | Falls back to standalone mode |
| 13 | Build verify (iPhone) | ✅ | — |
| 14 | Refactor TopicSyncPayload.swift | ✅ | Type defs kept, gateway parsing removed |
| 15 | Remove fetchSyncPayload from shared package | ✅ | Only caller was iPhone's readSyncPayload |
| 16 | Final build verify | ✅ | — |
| 17 | Gateway cleanup | ✅ | — |
| 18 | Commit | ✅ | — |

**Order is correct.** Each step keeps both targets compiling.

---

## SUMMARY

| Finding | Severity | Action |
|---------|----------|--------|
| B6: `fetchSessionInfos()` is dead code, listed as "keep" | BLOCKER | Move to REMOVE list |
| B7: `pluginExtensions` on SessionInfo is unused after backout | CONCERN | Leave it, add comment |
| B8: `sessionsPatch` and `chatInject` are dead code, listed as "keep" | BLOCKER | Move both to REMOVE list |
| C1: Step 8 should remove all three RPC methods together | CONCERN | Clarify in spec |
| C2: `ChatHistoryMessage` has a latent content-format bug | CONCERN | Document for REST spec |

**Required changes before implementation:**
1. Move `fetchSessionInfos()` from KEEP to REMOVE (add to step 5)
2. Move `sessionsPatch` from KEEP to REMOVE (add to step 8, both protocol and implementation)
3. Move `chatInject` from KEEP to REMOVE (add to step 8, both protocol and implementation)
4. Add note about `pluginExtensions` being unused after backout
5. Update the "What We Keep" table to remove these three items
6. Add step 8 clarification: remove all three RPC methods (`sessionsPluginPatch`, `sessionsPatch`, `chatInject`)

With these changes, **the spec is approved for implementation.**