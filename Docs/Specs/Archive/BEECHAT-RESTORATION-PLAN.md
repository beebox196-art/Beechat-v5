# BeeChat Restoration Plan

**Date:** 2025-05-24
**Goal:** Restore macOS working baseline from `develop`, then layer in mobile changes one at a time with validation.
**Baseline branch:** `feature/gate-2f-unified` (from develop)
**Merge-base:** `476c85a`
**Mobile branch:** `feature/gate-2f-phase1` (14 commits ahead of merge-base, including 1 merge commit)

---

## Phase 1: macOS Baseline (develop)

- [x] `feature/gate-2f-unified` created from develop
- [x] macOS build verified — **PASS** (clean, 6.64s, zero errors)
- [x] Tag `develop-pre-fix` created for rollback reference

---

## Phase 2: Layer Mobile Changes (one at a time)

Commits are listed in **dependency order** (earliest first, not chronological).
The mobile branch is chronologically ordered correctly already — each depends on the previous.

### Commit 1: `b5a1cb5` — Gate 2F Phase 0 — SessionInfo.pluginExtensions + BeeChatTopicMetadata
- **Files changed (3):**
  - `Sources/BeeChatSyncBridge/Models/BeeChatTopicMetadata.swift` (new, +27)
  - `Sources/BeeChatSyncBridge/Models/SessionInfo.swift` (+18)
  - `Sources/BeeChatGateway/Tests/Sources/SessionInfoPluginExtensionsTests.swift` (+281)
- **Conflict risk with develop:** LOW — new structs + extension to SessionInfo, backwards compatible (`decodeIfPresent`)
- **Platform conditional needed?** No — pure Swift Codable, no platform APIs
- **Validation after applying:** `swift build` + `swift test` (12 new tests)
- **Risk:** LOW — additive, backwards compatible, well-tested

### Commit 2: `252363b` — fix: address Kieran review blockers B1, B2, W2, W5
- **Files changed (2):**
  - `Sources/BeeChatSyncBridge/Models/SessionInfo.swift` (+43)
  - `Sources/BeeChatGateway/Tests/Sources/SessionInfoPluginExtensionsTests.swift` (+146)
- **Conflict risk with develop:** LOW — builds on commit 1, same files, metadata type-safety improvements
- **Platform conditional needed?** No
- **Validation after applying:** `swift test` (87 tests expected)
- **Risk:** LOW — more type-safety guards, test additions

### Commit 3: `52234f7` — Gate 2F Phase 0 merge commit
- **Files changed:** Merge of commit 2 into main branch
- **Conflict risk with develop:** NONE — just a merge commit
- **Platform conditional needed?** No
- **Validation:** None needed — will be skipped during cherry-pick (merge commit)
- **Risk:** NONE

### Commit 4: `76fe983` — fix: change client mode to "ui" for sessions.patch compatibility
- **Files changed (1):**
  - `Sources/App/AppRootView.swift` (+2/-2) — `clientMode: "webchat"` → `"ui"`, `clientInfo.mode: "webchat"` → `"ui"`
- **Conflict risk with develop:** LOW — simple 2-line string change
- **Platform conditional needed?** No — macOS uses "ui" now, works fine
- **Validation after applying:** `swift build`
- **Risk:** LOW — gateway compatibility fix, no platform-specific code

### Commit 5: `7177321` — feat: Mac-side topic publishing
- **Files changed (7):**
  - `Sources/App/UI/MainWindow.swift` (+12)
  - `Sources/BeeChatGateway/GatewayClient.swift` (+11)
  - `Sources/BeeChatSyncBridge/RPCClient.swift` (+36)
  - `Sources/BeeChatSyncBridge/SyncBridge.swift` (+150)
  - `Sources/BeeChatSyncBridge/TopicPublishQueue.swift` (new, +31)
  - `Sources/BeeChatGateway/Tests/Sources/SyncBridgeTests.swift` (+6)
  - `Sources/BeeChatGateway/Tests/Sources/TopicPublishingTests.swift` (new, +292)
- **Conflict risk with develop:** **HIGH** — SyncBridge.swift gets +150 lines; MainWindow gets topic CRUD hooks. These are the foundational changes that the rest build on.
- **Platform conditional needed?** No — this is Mac-side publishing, no mobile-specific code
- **Validation after applying:** `swift build` + `swift test`
- **Risk:** MEDIUM — large change but Mac-native, no platform-specific issues expected

### Commit 6: `7e6a8a9` — fix: remove inner Task in publishTopicState
- **Files changed (1):**
  - `Sources/BeeChatSyncBridge/SyncBridge.swift` (+1/-3)
- **Conflict risk with develop:** LOW — fixes serial queue in commit 5's code
- **Platform conditional needed?** No
- **Validation after applying:** `swift build`
- **Risk:** LOW — small fix, depends on commit 5 being applied

### Commit 7: `7177321` → Already listed as commit 5. Next is:

### Commit 7: `26d9df0` — docs: Gate 2F Phase 2 spec (awaiting team review)
- **Files changed (1):**
  - `Docs/Specs/GATE-2F-PHASE2-IPHONE-TOPIC-SYNC.md` (new, +466)
- **Conflict risk with develop:** NONE — docs only
- **Platform conditional needed?** No
- **Validation after applying:** `swift build` (should be unaffected)
- **Risk:** NONE

### Commit 8: `7272465` — docs: Gate 2F Phase 2 spec v3 (all blockers resolved)
- **Files changed (4):**
  - `Docs/Reviews/kieran-gate-2f-phase2-review.md` (new)
  - `Docs/Reviews/mel-gate-2f-phase2-review.md` (new)
  - `Docs/Reviews/q-gate-2f-phase2-review.md` (new)
  - `Docs/Specs/GATE-2F-PHASE2-IPHONE-TOPIC-SYNC.md` (updated, +688/-303)
- **Conflict risk with develop:** NONE — docs/reviews only
- **Platform conditional needed?** No
- **Validation after applying:** `swift build` (should be unaffected)
- **Risk:** NONE

### Commit 9: `e153128` — docs: Gate 2F Phase 2 spec v4 (final validation complete)
- **Files changed (4):**
  - `Docs/Reviews/kieran-gate-2f-phase2-final-validation.md` (new, +270)
  - `Docs/Reviews/mel-gate-2f-phase2-final-validation.md` (new, +83)
  - `Docs/Reviews/q-gate-2f-phase2-final-validation.md` (new, +164)
  - `Docs/Specs/GATE-2F-PHASE2-IPHONE-TOPIC-SYNC.md` (updated, +131/-15)
- **Conflict risk with develop:** NONE — docs/reviews only
- **Platform conditional needed?** No
- **Validation after applying:** `swift build` (should be unaffected)
- **Risk:** NONE

### Commit 10: `ff56a7f` — docs: Gate 2F Phase 2 implementation log
- **Files changed (1):**
  - `Docs/Specs/GATE-2F-PHASE2-IMPLEMENTATION-LOG.md` (new, +178)
- **Conflict risk with develop:** NONE — docs only
- **Platform conditional needed?** No
- **Validation after applying:** `swift build` (should be unaffected)
- **Risk:** NONE

### Commit 11: `1a4ba56` — feat: Gate 2F Phase 2 — iPhone topic sync
- **Files changed (12):**
  - `Sources/App/UI/Observers/SyncBridgeObserver.swift` (+4)
  - `Sources/BeeChatPersistence/BeeChatPersistenceStore.swift` (+20)
  - `Sources/BeeChatPersistence/Models/BeeChatTopicMetadata.swift` (moved, 0 diff)
  - `Sources/BeeChatPersistence/Models/GatewaySessionInfo.swift` (+34)
  - `Sources/BeeChatPersistence/Repositories/TopicRepository.swift` (+203/-99)
  - `Sources/BeeChatPersistence/Utilities/SessionKeyNormalizer.swift` (+13)
  - `Sources/BeeChatSyncBridge/EventRouter.swift` (+6)
  - `Sources/BeeChatSyncBridge/Models/GatewayRPCResponses.swift` (+1)
  - `Sources/BeeChatSyncBridge/Models/SessionInfo.swift` (+21)
  - `Sources/BeeChatSyncBridge/Protocols/SyncBridgeDelegate.swift` (+11)
  - `Sources/BeeChatSyncBridge/SyncBridge.swift` (+28)
  - `Sources/BeeChatPersistence/Utilities/SessionKeyNormalizer.swift` (moved, -68)
- **Conflict risk with develop:** **CRITICAL** — This is the big one. SyncBridge gets +28 more lines (on top of the +150 from commit 5). TopicRepository gets major additions. SessionInfo gets `asGatewaySessionInfo` property. SessionKeyNormalizer moved from BeeChatSyncBridge to BeeChatPersistence. SyncBridgeDelegate gets new required method (with default extension).
- **Platform conditional needed?** **YES** — This adds `fetchSessionInfos()` which calls `sessions.list` and processes results for topic sync. The `asGatewaySessionInfo` property and session-related changes are platform-agnostic, but need checking for any hardcoded platform assumptions. **Specifically check:** TopicRepository SQL, session info processing, any `#if os(iOS)` guards.
- **Validation after applying:** `swift build` — if clean, verify topic sync flow doesn't break Mac functionality
- **Risk:** HIGH — biggest code change, touches multiple modules, moves files between packages

### Commit 12: `e8d73f4` — fix: AnyCodable iOS compatibility + add iOS platform to Package.swift
- **Files changed (2):**
  - `Package.swift` (+2/-1) — adds `.iOS(.v17)` platform
  - `Sources/BeeChatGateway/AnyCodable.swift` (+19) — replaces `NSDictionary` equality with pure Swift `deepEqual`
- **Conflict risk with develop:** LOW — AnyCodable change is a drop-in replacement, backwards compatible
- **Platform conditional needed?** No — the `deepEqual` function is pure Swift, works on both macOS and iOS
- **Validation after applying:** `swift build`
- **Risk:** LOW — improves macOS too (removes Foundation-only NSDictionary dependency)

### Commit 13: `a118e49` — fix: bump gateway protocol 3→4 for OpenClaw compatibility
- **Files changed (1):**
  - `Sources/BeeChatGateway/Protocol/ConnectParams.swift` (+2/-2)
- **Conflict risk with develop:** LOW — single version bump
- **Platform conditional needed?** No
- **Validation after applying:** `swift build`
- **Risk:** LOW — protocol version change, should just work

### Commit 14: `2c372f5` — Implement session reset summary injection (v0.7 spec)
- **Files changed (7):**
  - `Sources/App/UI/Components/Composer.swift` (+4)
  - `Sources/App/UI/MainWindow.swift` (+15/-1)
  - `Sources/App/UI/Observers/SyncBridgeObserver.swift` (+12)
  - `Sources/BeeChatSyncBridge/Protocols/SyncBridgeDelegate.swift` (+6)
  - `Sources/BeeChatSyncBridge/RPCClient.swift` (+26)
  - `Sources/BeeChatSyncBridge/SessionResetManager.swift` (-1)
  - `Sources/BeeChatSyncBridge/SyncBridge.swift` (+184/-33)
- **Conflict risk with develop:** **HIGH** — SyncBridge gets another +151 net lines. Replaces `formatCombinedContext` with `formatSessionSummary`. Adds `chatInject()` RPC, `manualReset()` flow, `waitForStreamCompletion()`. MainWindow gets Reset Session context menu item.
- **Platform conditional needed?** No — this is gateway/session management, platform-agnostic
- **Validation after applying:** `swift build` + manual test of session reset
- **Risk:** HIGH — major behavioral change to session reset flow, replaces existing mechanism

---

## Phase 3: Validation

After all commits applied:
- [ ] `swift build` passes clean
- [ ] `swift test` passes (expected: 87+ tests)
- [ ] macOS gateway handshake works
- [ ] BeeBoard present and functional
- [ ] Session reset flow works (summary injection)
- [ ] Topic publishing to gateway works
- [ ] Protocol v4 handshake succeeds
- [ ] All develop features intact (scroll fixes, reset alerts, etc.)

---

## Summary Table

| # | Commit | Files | Risk | Platform Conditional | Notes |
|---|--------|-------|------|---------------------|-------|
| 1 | `b5a1cb5` Phase 0 metadata | 3 | LOW | No | Foundation — backwards compatible |
| 2 | `252363b` Kieran review fixes | 2 | LOW | No | Type-safety guards |
| 3 | `52234f7` Merge commit | 0 | NONE | No | Skip during cherry-pick |
| 4 | `76fe983` client mode → ui | 1 | LOW | No | Gateway compat |
| 5 | `7177321` Mac-side publishing | 7 | MEDIUM | No | Foundational, Mac-native |
| 6 | `7e6a8a9` remove inner Task | 1 | LOW | No | Serial queue fix |
| 7 | `26d9df0` Phase 2 spec | 1 | NONE | No | Docs only |
| 8 | `7272465` Phase 2 spec v3 | 4 | NONE | No | Docs only |
| 9 | `e153128` Phase 2 spec v4 | 4 | NONE | No | Docs only |
| 10 | `ff56a7f` implementation log | 1 | NONE | No | Docs only |
| 11 | `1a4ba56` iPhone topic sync | 12 | HIGH | Check | Biggest change, file moves |
| 12 | `e8d73f4` AnyCodable iOS fix | 2 | LOW | No | Pure Swift improvement |
| 13 | `a118e49` protocol 3→4 | 1 | LOW | No | Version bump |
| 14 | `2c372f5` session reset summary | 7 | HIGH | No | Behavioral change |

## Notes on Platform Conditionals

After reviewing all diffs: **none of the 14 commits contain hardcoded iOS-only values or `#if os(iOS)` guards.** The mobile branch was designed to work on both platforms — the issue wasn't platform-specific code, it was the branch diverging from develop and other changes being applied on top.

The `Package.swift` change adds `.iOS(.v17)` but doesn't remove macOS — macOS remains `.macOS(.v14)`.

The AnyCodable `deepEqual` replacement removes an `NSDictionary` dependency, which is a macOS-to-iOS portability improvement that also works fine on macOS.

**The biggest risk is commit 11 (`1a4ba56`) — it has 12 files, file moves between packages, and the most code additions. It needs careful cherry-picking and build verification.**
