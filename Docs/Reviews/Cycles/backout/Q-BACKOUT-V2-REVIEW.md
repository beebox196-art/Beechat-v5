# Gate 2F Backout Spec — v2 Codebase Audit

> **Reviewer:** Q  
> **Date:** 2026-05-28 21:11 GMT  
> **Spec:** `Docs/Specs/Active/GATE-2F-BACKOUT.md` (v2)  
> **Method:** Exhaustive grep across both repos (BeeChat-v5 + BeeChat-Mobile) for all 20 target symbols

---

## Executive Summary

The backout spec is **mostly correct** in identifying what to remove and what to keep. The removal order compiles cleanly. Bounce-fix safety is confirmed. However, there are **2 errors in the "What We Keep" section** (dead code falsely classified as live) and **1 missing removal** (dead RPC method not mentioned).

| Finding | Severity | Details |
|---------|----------|---------|
| KEEP→REMOVE | **HIGH** | `chatInject` is dead code (zero callers outside `performPublish`) |
| MISSING | **MEDIUM** | `sessionsPatch` not listed for removal (only caller: `publishTopicState`) |
| KEEP→REMOVE | **LOW** | `fetchSessionInfos()` is dead code (zero callers anywhere) |
| Comment doc reference | **LOW** | `TopicSyncPayload.swift` doc comment references `beechat-sync` session |
| Bounce-fix safety | ✅ PASS | None of the 4 bounce-fix commits touch any backout files |

---

## 1. Symbol Audit — Every Reference Found and Categorized

### 1.1 `publishTopicList`, `performPublish`, `ensureSyncSessionExists`

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 985–1119 | Definitions (all three methods) | **REMOVE** — spec §1 correct |
| `Sources/App/UI/MainWindow.swift` | 421, 425, 453, 482 | Call sites (4) | **REMOVE** — spec §7 correct |
| `Sources/App/AppRootView.swift` | 98 | Startup call site | **REMOVE** — spec §6 correct |
| `Sources/App/UI/Observers/SyncBridgeObserver.swift` | 290 | Session-change call site | **REMOVE** — spec §8 correct |
| `Docs/Specs/Active/*.md` | various | Documentation | N/A |
| `Docs/Reviews/*.md` | various | Review history | N/A |

**Assessment:** All references correctly identified. No missed references.

---

### 1.2 `publishTopicState`, `clearTopicState`, `reconcileAllTopicState`

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 801–900 | Definitions (`publishTopicState`, `clearTopicState`, `clearTopicStateWithResult`, `fetchActiveSessionKeys`, `reconcileAllTopicState`) | **REMOVE** — spec §1 correct |
| `Sources/App/UI/MainWindow.swift` | 445–446 | Commented-out `clearTopicState` call | **COMMENTED-OUT** — spec §7 mentions removing these |
| `Sources/App/UI/MainWindow.swift` | 485–487 | Commented-out `publishTopicState` call | **COMMENTED-OUT** — spec §7 mentions removing these |
| `Sources/App/AppRootView.swift` | 101–106 | Commented-out `reconcileAllTopicState` block | **COMMENTED-OUT** — spec §6 mentions removing this |
| `Docs/Specs/Active/*.md` | various | Documentation | N/A |
| `Docs/Reviews/*.md` | various | Review history | N/A |

**Assessment:** All references correctly identified. Commented-out blocks are all flagged in the spec.

---

### 1.3 `verifyAdminScope`, `hasAdminScope`

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 950–958 | Definitions (`verifyAdminScope`) | **REMOVE** — spec §1 correct |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 962–965 | Definition (`hasAdminScope`) | **REMOVE** — spec §1 correct |

**Assessment:** Zero callers anywhere. Correctly listed for removal.

---

### 1.4 `fetchSyncPayload`

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 970–973 | Definition | **REMOVE** — spec §11 correct |
| `BeeChatMobile/.../BeeChatMobileViewModel.swift` | 499 | Caller: `bridge.fetchSyncPayload(sessionKey: "agent:main:beechat-sync")` inside `readSyncPayload()` | **REMOVE** — caller `readSyncPayload()` is being removed (spec §9) |

**Assessment:** Only one caller, which is being removed. Correct.

---

### 1.5 `fetchSessionInfos`

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 976 | Definition: `public func fetchSessionInfos() async throws -> [SessionInfo]` | **REMOVE (dead code)** |

**FINDING — KEEP classification is WRONG.** The spec lists this as KEEP with reason "Wraps `sessionsList()` — used for general session management." But a full-text search across both repos found **zero callers** outside the definition itself. No file in BeeChat-v5 or BeeChat-Mobile calls `fetchSessionInfos()`.

**Recommended action:** Remove `fetchSessionInfos()` from SyncBridge. It's just `return try await rpcClient.sessionsList()` — any future caller can use `rpcClient.sessionsList()` directly or call `bridge.config.gatewayClient` methods.

---

### 1.6 `TopicPublishQueue`

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/TopicPublishQueue.swift` | 1–31 | Entire file definition | **REMOVE** — spec §2 correct |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 784 | `private let publishQueue = TopicPublishQueue()` property | **REMOVE** — spec §1 correct |
| `Tests/.../SyncBridgeTests.swift` | — | No direct reference | N/A — tests use mock protocol, not concrete type |

**Assessment:** Correct.

---

### 1.7 `BeeChatTopicMetadata`

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatPersistence/Models/BeeChatTopicMetadata.swift` | 1–26 | Entire file definition | **REMOVE** — spec §3 correct |
| `Sources/BeeChatSyncBridge/Models/SessionInfo.swift` | 54–63 | `beechatMetadata` property uses it | **REMOVE** — part of §5 (beechatMetadata removal) |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 812, 873 | Used in `publishTopicState` and `clearTopicStateWithResult` | **REMOVE** — both callers being removed |

**Assessment:** Correct.

---

### 1.8 `sessionsPluginPatch`

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/RPCClient.swift` | 15 | Protocol declaration | **REMOVE** — spec §4 correct |
| `Sources/BeeChatSyncBridge/RPCClient.swift` | 173–191 | Implementation | **REMOVE** — spec §4 correct |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 827–828, 869 | Callers in `publishTopicState` and `clearTopicStateWithResult` | **REMOVE** — callers being removed |
| `Tests/.../SyncBridgeTests.swift` | 38 | Mock implementation | **REMOVE** — test mock will need update |

**Assessment:** Correct. But see **MISSING: `sessionsPatch`** below.

---

### 1.9 `beechatMetadata` (computed property on `SessionInfo`)

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/Models/SessionInfo.swift` | 54–63 | Definition | **REMOVE** — spec §5 correct |

**Assessment:** Zero callers in source code. Correct.

---

### 1.10 `TopicSyncItem`, `TopicListPayload`

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 634–647 | Definitions | **REMOVE** — spec §1 correct |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 1014–1028 | Usage in `performPublish()` | **REMOVE** — caller being removed |

**Assessment:** Correct.

---

### 1.11 `syncSessionKey`, `lastSyncTimestampKey` (iPhone)

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `BeeChatMobile/.../BeeChatMobileViewModel.swift` | 34 | `private static let syncSessionKey = "agent:main:beechat-sync"` | **REMOVE** — spec §9 correct |
| `BeeChatMobile/.../BeeChatMobileViewModel.swift` | 36 | `private static let lastSyncTimestampKey = "beechat_lastSyncTimestamp"` | **REMOVE** — spec §9 correct |
| `BeeChatMobile/.../BeeChatMobileViewModel.swift` | 499 | Used in `readSyncPayload()` | **REMOVE** — method being removed |
| `BeeChatMobile/.../BeeChatMobileViewModel.swift` | 507, 514 | UserDefaults read/set with `beechat_lastSyncTimestamp` | **REMOVE** — inside `readSyncPayload()` |
| `BeeChatMobile/.../BeeChatMobileViewModel.swift` | 626–627 | `beechat-sync` filter in `didReceiveSessionChange` | **REMOVE** — spec §9 correct |

**Assessment:** Correct.

---

### 1.12 `beechat-sync` (string literal)

| File | Line(s) | Usage | Verdict |
|------|---------|-------|---------|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | 1051, 1069, 1076–1077 | Hardcoded `"agent:main:beechat-sync"` in `ensureSyncSessionExists()` and `performPublish()` | **REMOVE** — all inside methods being removed |
| `BeeChatMobile/.../BeeChatMobileViewModel.swift` | 499 | Hardcoded `"agent:main:beechat-sync"` in `readSyncPayload()` | **REMOVE** — method being removed |
| `BeeChatMobile/.../TopicSyncPayload.swift` | 5 | Doc comment: `via the \`agent:main:beechat-sync\` session` | **COMMENTED-OUT** — doc comment, should be updated |

**Assessment:** All source code references are within methods being removed. The doc comment in `TopicSyncPayload.swift` should be updated (or will be when the file is renamed to `TopicTypes.swift` per spec §10).

---

## 2. FINDINGS — Items the Backout Spec Got Wrong

### 2.1 HIGH: `chatInject` is DEAD CODE (spec says KEEP)

**Spec claim (§ What We Keep):**
> `chatInject` RPC method | `RPCClient.swift` | Used for session reset context injection

**Reality:** The only call to `rpcClient.chatInject()` in the entire codebase (outside tests and RPCClient definition) is at `SyncBridge.swift:1050` — inside `performPublish()`, which is being removed.

```
Sources/BeeChatSyncBridge/SyncBridge.swift:1050
  _ = try await rpcClient.chatInject(
      sessionKey: "agent:main:beechat-sync",
      ...
  )
```

There is **no** session-reset use of `chatInject`. The session-reset flow (`SessionResetManager`) does not call `chatInject`. `requeueContextInjection()` manages the `contextInjectedKeys` Set — it doesn't call `chatInject`.

**Impact:** If `chatInject` is kept but `performPublish()` is removed, `chatInject` becomes dead code in the codebase. It's a protocol method with an implementation that's never called. It won't cause compilation errors but it is dead code — contrary to the spec's stated goal of "Clean foundation, no dead code."

**Recommendation:** Either:
- (a) Remove `chatInject` from the protocol and implementation alongside `performPublish()`, or
- (b) Clarify in the spec that `chatInject` is being kept as **planned future use** for the REST-based session-reset injection, and accept the temporary dead-code state.

If (b), rename the "Used for session reset context injection" to "Reserved for REST-based session reset (future)" to be honest about current state.

---

### 2.2 MEDIUM: `sessionsPatch` is NOT listed (only used by dead code)

**Not in the backout spec at all.**

`sessionsPatch` is defined in `RPCClientProtocol` (line 14) and implemented (lines 159–170). The only callers in source code are both inside `publishTopicState()`:

```
Sources/BeeChatSyncBridge/SyncBridge.swift:843
  let labelOk = try await self.rpcClient.sessionsPatch(
      key: sessionKey,
      label: topic.name
  )
```

After `publishTopicState()` is removed, `sessionsPatch` has zero callers (just like `sessionsPluginPatch`). It should be removed from `RPCClientProtocol` and `RPCClient`, alongside `sessionsPluginPatch`.

**Recommendation:** Add to spec §4 (Remove sessionsPluginPatch from RPCClient):
- Also remove `sessionsPatch(key:label:)` from `RPCClientProtocol` and `RPCClient` — its only caller (`publishTopicState`) is being removed.

---

### 2.3 LOW: `fetchSessionInfos()` is DEAD CODE (spec says KEEP)

**Spec claim (§ What We Keep):**
> `fetchSessionInfos()` on SyncBridge | `SyncBridge.swift` | Wraps `sessionsList()` — used for session management, not just sync

**Reality:** Zero callers across both repos. Not in BeeChat-v5, not in BeeChat-Mobile. It's a public thin wrapper around `rpcClient.sessionsList()` that nothing uses.

**Recommendation:** Remove it. Any future caller can call `rpcClient.sessionsList()` or `config.gatewayClient` methods directly.

---

### 2.4 LOW: `TopicSyncPayload.swift` doc comment still references `beechat-sync`

The doc comment at line 5 says:
```swift
/// Payload format for topic sync via the `agent:main:beechat-sync` session.
```

When this file is renamed to `TopicTypes.swift` per spec §10, update the doc comment to reflect REST-based usage instead.

---

## 3. Removal Order — Compilation Safety Check

The spec's 18-step removal order is **sound**. I verified dependencies:

| Step | What | Dependencies Satisfied? |
|------|------|------------------------|
| 1 | AppRootView.swift: Remove `publishTopicList()` call | ✅ No dependency on later steps |
| 2 | MainWindow.swift: Remove 4 `publishTopicList()` calls + commented blocks | ✅ No dependency on later steps |
| 3 | SyncBridgeObserver.swift: Remove `publishTopicList()` call | ✅ No dependency on later steps |
| 4 | Mac build verify | ✅ Should pass (no sync methods removed yet) |
| 5 | SyncBridge.swift: Remove all methods/types | ✅ Callers (steps 1–3) already cleaned |
| 6 | Delete `TopicPublishQueue.swift` | ✅ Only reference was `publishQueue` property (step 5) |
| 7 | Delete `BeeChatTopicMetadata.swift` | ✅ Only references were `publishTopicState`/`clearTopicState`/`beechatMetadata` (steps 5, §5) |
| 8 | RPCClient.swift: Remove `sessionsPluginPatch` | ✅ Only callers were `publishTopicState`/`clearTopicState` (step 5) |
| 9 | Remove `beechatMetadata` from `SessionInfo` | ✅ Type `BeeChatTopicMetadata` being deleted (step 7) |
| 10 | Mac build verify | ✅ Should pass |
| 11 | iPhone: BeeChatMobileViewModel.swift changes | ✅ Shared package intact at this point |
| 12 | iPhone: Stub `connect()` | ✅ |
| 13 | iPhone build verify | ✅ |
| 14 | iPhone: Refactor `TopicSyncPayload.swift` | ✅ |
| 15 | Shared: Remove `fetchSyncPayload()` | ✅ iPhone caller (step 11) already removed |
| 16 | Final build verify | ✅ |
| 17 | Gateway cleanup | ✅ Post-build |
| 18 | Commit | ✅ |

**Additional step needed:** After step 8 (RPCClient.swift), also remove `sessionsPatch` (see §2.2 above). No compilation impact — same step, same file.

**`chatInject` decision point:** If removing it (recommendation §2.1a), add to step 8. If keeping it (§2.1b), no extra step needed.

---

## 4. Bounce-Fix Safety

**VERIFIED — SAFE.**

The 4 bounce-fix commits are:
- `1bdedf8` — `Sources/App/UI/Components/MessageCanvas.swift`
- `16b0130` — `Sources/App/UI/Components/MessageCanvas.swift`
- `2c507d5` — `Sources/App/UI/Components/MessageCanvas.swift`
- `64b150f` — `Sources/App/UI/Components/MessageCanvas.swift`

The backout spec touches:
- `Sources/BeeChatSyncBridge/SyncBridge.swift` — ❌ not `MessageCanvas.swift`
- `Sources/BeeChatSyncBridge/TopicPublishQueue.swift` — ❌ not `MessageCanvas.swift`
- `Sources/BeeChatPersistence/Models/BeeChatTopicMetadata.swift` — ❌ not `MessageCanvas.swift`
- `Sources/BeeChatSyncBridge/RPCClient.swift` — ❌ not `MessageCanvas.swift`
- `Sources/BeeChatSyncBridge/Models/SessionInfo.swift` — ❌ not `MessageCanvas.swift`
- `Sources/App/UI/MainWindow.swift` — ❌ not `MessageCanvas.swift`
- `Sources/App/AppRootView.swift` — ❌ not `MessageCanvas.swift`
- `Sources/App/UI/Observers/SyncBridgeObserver.swift` — ❌ not `MessageCanvas.swift`
- iPhone: `BeeChatMobileViewModel.swift`, `TopicSyncPayload.swift` — ❌ different repo

**No overlap.** Zero files in the backout spec intersect with the bounce-fix commits.

---

## 5. Missing Items Summary

| Item | Location | Status | Why Missing |
|------|----------|--------|-------------|
| `sessionsPatch` protocol + impl | `RPCClient.swift` lines 14, 159–170 | Should be removed | Only caller is `publishTopicState` (being removed) |
| `sessionsPatch` mock | `SyncBridgeTests.swift` line 37 | Should be removed | Test mock for removed protocol method |
| Test mock for `chatInject` | `SyncBridgeTests.swift` line 39 | Depends on decision | If `chatInject` is removed, mock must go too |

---

## 6. Spec Corrections Summary

Apply these changes to `GATE-2F-BACKOUT.md`:

### In "What We Keep" table — change 2 entries from KEEP to REMOVE:

1. **Remove the row:** `chatInject` RPC method → move to removal list (or mark as "KEEP (dead, reserved for future REST)")
2. **Remove the row:** `fetchSessionInfos()` on SyncBridge → move to removal list

### In "What We Remove" — §4 (RPCClient.swift):

Add:
> - `sessionsPatch(key:label:)` from `RPCClientProtocol` (line ~14) — only caller is `publishTopicState()`, being removed
> - `sessionsPatch(...)` implementation from `RPCClient` (lines ~159–170)

### In "What We Remove" — §11 (SyncBridge.swift — shared):

Add:
> - `fetchSessionInfos()` — zero callers, thin wrapper around `sessionsList()`

### In iPhone §10 (TopicSyncPayload.swift → TopicTypes.swift):

Add:
> - Update doc comment at line 5 — remove reference to `beechat-sync` session

---

## 7. Final Verdict

**Spec quality: Good, with minor corrections needed.**

The spec correctly identifies all major sync code for removal, the removal order preserves compilation, and bounce-fix safety is confirmed. The three errors in the "What We Keep" section are all cases where the spec assumed a method was live when a codebase search proves it's dead. Fixing these means a cleaner final state — which aligns with the spec's stated principle of "Clean foundation, no dead code."
