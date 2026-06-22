# Gate 2F Phase 1 — Merge Conflict Audit Report

**Auditor:** Q (subagent)  
**Date:** 2026-05-26  
**Branches:** `develop` (target) vs `feature/gate-2f-phase1` (source)  
**Merge base:** `476c85a` (14 commits on phase1, 54 commits on develop since divergence)  
**Status:** 🔴 **8 BLOCKERS — DO NOT MERGE without resolution**

---

## Executive Summary

The `feature/gate-2f-phase1` branch diverged from `develop` at commit `476c85a`. Since then, `develop` has received **54 commits** including critical fixes (protocol v4 upgrade, BeeBoard P1–P3c, double-resume crash fix, Swift 6.0 migration), while `phase1` has only **14 commits** focused on Gate 2F topic publishing. The phase1 branch appears to have been branched from an **older point** (pre-Swift 6.0, pre-BeeBoard, pre-protocol v4) and never rebased. As a result, merging phase1 into develop would **revert or destroy** multiple critical features.

**Verdict:** All 8 blockers require manual merge resolution. A simple `git merge` will cause severe regressions.

---

## BLOCKER 1: BeeBoard Feature Deleted ✅ VERIFIED — CRITICAL REGRESSION

### Evidence

| | `develop` | `feature/gate-2f-phase1` |
|---|---|---|
| **Module exists** | ✅ `Sources/BeeBoard/` (Models, Repositories, Services, Migrations) | ❌ **Deleted entirely** |
| **Package.swift** | `.library(name: "BeeBoard", ...)` + `.target(name: "BeeBoard", ...)` | **Both entries removed** |
| **App callers** | `Sources/App/UI/Components/BeeBoardPinCard.swift`, `BeeBoardViewModel.swift` | Will fail to compile |

### Analysis

- `develop` has **11 BeeBoard commits** since divergence: P1 foundation → P2 core → P3a priority/tags → P3b groups → P3c attachments/links.
- `feature/gate-2f-phase1` has **zero BeeBoard commits** — the module was never part of its history.
- The phase1 branch's `Package.swift` removes BeeBoard entirely, treating it as dead code.

### Classification

**B — Accidental regression from branch divergence.** BeeBoard was added on `develop` AFTER the phase1 branch point. Phase1's Package.swift simply doesn't know about it.

### Required Action

When merging, **keep** the BeeBoard library/target entries in `Package.swift`. Do NOT let phase1's Package.swift override develop's.

---

## BLOCKER 2: Package.swift Downgraded ✅ VERIFIED — BUILD BREAKING

### Evidence

| Setting | `develop` | `feature/gate-2f-phase1` |
|---|---|---|
| **Swift tools version** | `6.0` | `5.9` (downgrade) |
| **ChatField dependency** | `.package(path: "Vendors/ChatField")` (local) | `.package(url: "https://github.com/kevinhermawan/ChatField", from: "3.0.4")` (remote) |
| **swiftSettings** | `[.swiftLanguageVersion(.v5)]` on all targets | **Removed entirely** |
| **Platforms** | `.macOS(.v15), .iOS(.v17)` | `.macOS(.v14), .iOS(.v17)` |

### Analysis

- `develop` upgraded to Swift 6.0 in commit `99e3b69` (May 15). The `swiftLanguageVersion(.v5)` setting is intentional — it allows Swift 5 syntax mode under Swift 6.0 toolchain, a common migration pattern.
- `phase1` branched before this upgrade. Its `Package.swift` still uses 5.9 tools version.
- The remote ChatField package (`3.0.4`) vs local vendor path suggests phase1 was created from an even earlier point in history (ChatField was moved to local vendor after initial integration).
- **Platform downgrade** `.macOS(.v15)` → `.macOS(.v14)` may break APIs used on develop.

### Classification

**B — Accidental regression from branch divergence.** Phase1 branched before the Swift 6.0 + local ChatField + platform upgrade changes.

### Required Action

Keep ALL of `develop`'s Package.swift settings:
- `swift-tools-version: 6.0`
- Local `Vendors/ChatField` path
- `swiftSettings: [.swiftLanguageVersion(.v5)]` on all targets
- `.macOS(.v15)` platform requirement
- BeeBoard library and target entries

Phase1's only Package.swift contribution should be the `BeeChatTopicMetadata` types if they need new dependencies (they don't appear to).

---

## BLOCKER 3: ConnectParams.ClientInfo Simplified ✅ VERIFIED — PARTIAL IMPACT

### Evidence

| Field | `develop` | `feature/gate-2f-phase1` |
|---|---|---|
| `id` | ✅ | ✅ |
| `version` | ✅ | ✅ |
| `platform` | ✅ | ✅ |
| `mode` | ✅ | ✅ |
| `displayName` | ✅ **Present** | ❌ **Removed** |
| `deviceFamily` | ✅ **Present** | ❌ **Removed** |
| `modelIdentifier` | ✅ **Present** | ❌ **Removed** |
| `instanceId` | ✅ **Present** | ❌ **Removed** |

### macOS App Callers Checked

```
Sources/App/AppRootView.swift:  clientInfo: .init(id: "openclaw-control-ui", version: "1.0", platform: "macos", mode: "webchat", deviceFamily: "desktop")
```

- **1 caller** on `develop` uses `deviceFamily` parameter in `AppRootView.swift`.
- `Sources/App/UI/MainWindow.swift` and `SyncBridgeObserver.swift` do NOT directly construct `ClientInfo` — they receive it from configuration.

### Analysis

- The additional fields (`displayName`, `deviceFamily`, `modelIdentifier`, `instanceId`) were added on `develop` for richer client identification.
- `feature/gate-2f-phase1` uses a minimal 4-field struct.
- `AppRootView.swift` will fail to compile if the simplified struct is adopted, because it passes `deviceFamily: "desktop"`.

### Classification

**B — Accidental regression from branch divergence.** The expanded ClientInfo was added on `develop` after phase1 branched.

### Required Action

Keep `develop`'s full `ClientInfo` struct with all 8 fields. The macOS app depends on `deviceFamily` at minimum. The extra fields are harmless — they just provide more context to the gateway.

---

## BLOCKER 4: GatewayClient.swift Major Refactoring ✅ VERIFIED — CRITICAL REGRESSION

### Evidence

| Feature | `develop` | `feature/gate-2f-phase1` |
|---|---|---|
| **Debug logging** | ✅ File-based debug log to `~/Desktop/BeeChat-debug.log` + `print("[GW] ...")` | ❌ **All debug logging removed** |
| **Double-resume guard** | ✅ `OSAllocatedUnfairLock` atomic guard in `request()` closure | ❌ **Removed** |
| **Cancellation handler** | ✅ `withTaskCancellationHandler` wrapping `request()` | ❌ **Removed** |
| **Default clientInfo** | Platform-conditional: `#if os(iOS)` → `openclaw-ios` / `#if os(macOS)` → `openclaw-control-ui` | Hardcoded: `.init(id: "openclaw-macos", ...)` |
| **helloResponse accessor** | ❌ Not present | ✅ Added `_helloResponse` + `grantedScopes()` |

### Analysis

- The `OSAllocatedUnfairLock` + `withTaskCancellationHandler` pattern was added in commit `99e3b69` as part of the **double-resume crash fix** (SPEC-FIX-A-double-resume.md). This was a critical stability fix.
- Removing it reintroduces the crash risk: if a request times out and the Task is cancelled, both the timeout handler and cancellation handler could call `continuation.resume()`, which is a Swift runtime fatal error.
- The debug logging was also added in `99e3b69` for production diagnostics. Removing it makes gateway issues impossible to diagnose in the field.
- The hardcoded `"openclaw-macos"` default breaks iOS builds — there is no iOS fallback.
- Phase1 adds `helloResponse`/`grantedScopes()` which is a **valid new feature** for topic publishing scope verification.

### Classification

**B — Accidental regression** for debug logging, double-resume guard, and cancellation handler.  
**A — Intentional change** for `helloResponse`/`grantedScopes()` (new feature).  
**B — Accidental regression** for hardcoded platform (breaks iOS).

### Required Action

Merge strategy:
1. **Keep** `develop`'s debug logging system (`debugLogURL`, `debugLog()`)
2. **Keep** `develop`'s `OSAllocatedUnfairLock` double-resume guard
3. **Keep** `develop`'s `withTaskCancellationHandler`
4. **Keep** `develop`'s platform-conditional default clientInfo
5. **Adopt** phase1's `helloResponse` / `grantedScopes()` additions (new value)

---

## BLOCKER 5: Gateway Protocol Version Downgrade ✅ VERIFIED — GATEWAY BREAKAGE

### Evidence

| Location | `develop` | `feature/gate-2f-phase1` |
|---|---|---|
| `ConnectParams.minProtocol` | `4` | `4` (unchanged) |
| `ConnectParams.maxProtocol` | `4` | `4` (unchanged) |
| `HelloOk` **fallback** (`??` operator) | `?? 4` | `?? 3` (downgrade) |
| `HelloOk` **decoder** default | `4` | `3` |

### Git History

- Commit `99e3b69` (on `develop`): "fix: upgrade gateway protocol to v4 for OpenClaw 5.12 compatibility"
- Commit `a118e49` (on `feature/gate-2f-phase1`): "fix: bump gateway protocol 3→4 for OpenClaw compatibility" — but this only changed `minProtocol`/`maxProtocol`, **not** the `HelloOk` decoder fallback.

### Analysis

- The `HelloOk` decoder uses `(try? container.decode(Int.self, forKey: .protocol)) ?? X` as a fallback when the server doesn't send a protocol version.
- `develop` correctly defaults to `4` after the protocol v4 upgrade.
- `feature/gate-2f-phase1` still defaults to `3` in the decoder, despite claiming to have bumped to v4.
- **Result:** If the gateway omits the protocol field, phase1 will negotiate v3, causing a protocol mismatch with OpenClaw 5.12+.

### Classification

**B — Partial/incomplete fix on phase1.** The phase1 commit `a118e49` only changed `minProtocol`/`maxProtocol` but missed the decoder fallback. This is an oversight, not intentional.

### Required Action

Ensure `HelloOk` decoder fallback is `?? 4` on all branches. Phase1's decoder code must be updated to match develop.

---

## BLOCKER 6: Topic.swift Field Removed ✅ VERIFIED — DATA MIGRATION RISK

### Evidence

| Field | `develop` | `feature/gate-2f-phase1` |
|---|---|---|
| `pendingGatewaySync: Bool` | ✅ Present in model, init, upsertColumns | ❌ **Removed entirely** |

### Database Migration Status

- `develop`: `pendingGatewaySync` was added in a migration. The column exists in production databases.
- `feature/gate-2f-phase1`: The field is removed from the model but the migration history is unchanged.

### Callers on `develop`

```
Sources/BeeChatPersistence/Repositories/TopicRepository.swift:
  - create(name:pendingGatewaySync:)
  - fetchPendingSyncTopics()
  - markSynced(topicId:)

Sources/BeeChatPersistence/Database/DatabaseManager.swift:
  - References in migration logic
```

### Analysis

- Removing `pendingGatewaySync` from `Topic.swift` while the database still has the column will cause:
  1. **GRDB decoding errors** when fetching topics (unknown column → decode failure)
  2. **Broken `TopicRepository` methods** that depend on the field
  3. **Lost sync state tracking** — topics created before the merge will have orphaned sync flags

### Classification

**B — Accidental regression.** Phase1 never had the `pendingGatewaySync` field (it was added on `develop` after the branch point). Phase1's topic publishing model doesn't need it, but removing it breaks existing data.

### Required Action

**Keep** `pendingGatewaySync` in `Topic.swift`. If phase1's topic publishing doesn't use it, that's fine — the field can remain at its default `false`. Do NOT remove database columns without a migration.

---

## BLOCKER 7: TopicRepository.swift Methods Deleted ✅ VERIFIED — APP BREAKAGE

### Evidence

| Method | `develop` | `feature/gate-2f-phase1` |
|---|---|---|
| `create(name:pendingGatewaySync:)` | ✅ Creates topic with gateway key + bridge | ❌ **Deleted** |
| `fetchAllActiveWithCounts()` | ✅ SQL JOIN to compute message counts | ⚠️ **Replaced** with simpler version (no JOIN) |
| `fetchPendingSyncTopics()` | ✅ Filter by `pendingGatewaySync == true` | ❌ **Deleted** |
| `archive(topicId:)` | ✅ Set `isArchived = 1` | ❌ **Deleted** |
| `markSynced(topicId:)` | ✅ Clear `pendingGatewaySync` flag | ❌ **Deleted** |
| `syncMetadataFromSessions(_:)` | ✅ Update topic from gateway session data | ❌ **Deleted** |

### macOS App Callers

```
Sources/App/UI/MainWindow.swift (lines 302, 331, 396, 427):
  - Uses: topicRepo.fetchAllActive() ✅ (still exists on phase1)
  - Uses: topicRepo.save(), saveBridge(), updateSessionKey(), deleteCascading() ✅ (still exists)
  - Does NOT call: create(pendingGatewaySync:), fetchAllActiveWithCounts(), fetchPendingSyncTopics(), markSynced(), archive(), syncMetadataFromSessions()

Sources/App/UI/ViewModels/MessageViewModel.swift:
  - Uses: topicRepo.resolveSessionKey(), updateSessionKey(), saveBridge() ✅ (still exists)
```

### Analysis

- The **deleted methods are NOT called by the macOS app** (`Sources/App/`). This is why the app compiles on phase1.
- However, these methods are part of the **public API** of `TopicRepository`. They may be called by:
  - iOS app (Gate 2F Phase 2)
  - Future features
  - Tests
  - External consumers of the package
- The `fetchAllActiveWithCounts()` replacement loses the SQL JOIN that computes `messageCount` from the messages table. On `develop`, this was needed after migration M010 replaced topic-based triggers with session-based triggers. The phase1 version just fetches `Topic` records directly, which will show `messageCount = 0` for all topics (since the DB trigger populates it, but only on insert/update, not on plain fetch).

### Classification

**B — Accidental regression** for the deleted methods (they were added on `develop` after branch point).  
**C — Needs merge resolution** for `fetchAllActiveWithCounts()`: phase1 simplified it but may have lost M010 compatibility.

### Required Action

1. **Keep** all `develop` methods on `TopicRepository` — they are part of the public API.
2. **Review** `fetchAllActiveWithCounts()`: verify if phase1's simpler version correctly returns message counts post-M010. If not, keep `develop`'s SQL JOIN version.
3. Phase1 adds new methods (`resolveTopicIdBySuffix`, `listAllBridgeSessionKeys`) — **keep these**.

---

## BLOCKER 8: SyncBridge.swift — Context Injection Fields Removed ✅ VERIFIED — BEHAVIOR CHANGE

### Evidence

| Field | `develop` | `feature/gate-2f-phase1` |
|---|---|---|
| `contextInjectedKeys: Set<String>` | ✅ Tracks per-session context injection | ❌ **Removed** |
| `pendingResetContext: [String: String]` | ✅ Stores manual reset context for next send | ❌ **Removed** |
| `manualResetKeys: Set<String>` | ❌ Not present | ✅ **New** — replaces pendingResetContext |
| `TopicPublishQueue` | ❌ Not present | ✅ **New** — serialises topic publishing |
| `publishTopicState(topic:sessionKey:)` | ❌ Not present | ✅ **New** — topic publishing API |

### Analysis

- `contextInjectedKeys` prevents double-injection of topic context on the same session. Without it, every message send would re-inject the full topic header, growing the context indefinitely.
- `pendingResetContext` stores formatted context from `manualReset()` to be injected on the next `sendMessage()`. It supports the "reset then send" UX flow.
- `feature/gate-2f-phase1` replaces both with `manualResetKeys` (a simpler cooldown flag) and adds `TopicPublishQueue` + `publishTopicState()` for topic publishing.
- **Risk:** Removing `contextInjectedKeys` means topic context will be injected on EVERY send, not just the first. This could cause context bloat and increased token usage.
- **Risk:** Removing `pendingResetContext` breaks the `manualReset()` → `sendMessage()` flow where the reset context is prepended to the next user message.

### macOS App Callers

```
Sources/App/ (grep for contextInjectedKeys, pendingResetContext, manualResetKeys, TopicPublishQueue, publishTopicState):
  → No direct references found in Sources/App/
```

The macOS app calls `syncBridge.sendMessage()`, `syncBridge.resetSession()`, `syncBridge.manualReset()` but does not directly access these internal fields.

### Classification

**A — Intentional change for topic publishing, but with UX regression risk.**  
The replacements (`manualResetKeys`, `TopicPublishQueue`) serve phase1's topic publishing goals. However, removing `contextInjectedKeys` and `pendingResetContext` changes behavior for existing features:

1. **Context injection** will repeat on every message (potential token bloat)
2. **Manual reset context** will not be prepended to the next message (UX regression)

### Required Action

1. **Evaluate** whether `contextInjectedKeys` behavior is still needed. If yes, merge it alongside `manualResetKeys`.
2. **Evaluate** whether `pendingResetContext` behavior is still needed for the manual-reset-then-send flow. If yes, merge it alongside the new publishing code.
3. **Keep** `TopicPublishQueue` and `publishTopicState()` — they are phase1's core contribution.
4. **Recommended:** Keep both old and new field sets. They serve different purposes and can coexist.

---

## Merge Strategy Recommendation

### Do NOT use `git merge` directly.

The divergence is too deep (54 vs 14 commits). A direct merge will silently adopt phase1's older versions of files, regressing `develop`.

### Recommended Approach: Rebase + Cherry-pick

1. **Create a fresh branch** from current `develop`:
   ```bash
   git checkout -b feature/gate-2f-phase1-rebased develop
   ```

2. **Cherry-pick phase1's actual feature commits** (not the infrastructure regressions):
   ```bash
   # Phase 0 commits (metadata structures)
   git cherry-pick b5a1cb5  # Gate 2F Phase 0
   git cherry-pick 252363b  # Kieran review fixes
   git cherry-pick 52234f7  # Phase 0 final

   # Phase 1 commits (topic publishing)
   git cherry-pick 76fe983  # client mode fix
   git cherry-pick 7177321  # Mac-side topic publishing
   git cherry-pick 7e6a8a9  # inner Task fix
   ```

3. **For each cherry-pick, resolve conflicts by:**
   - Keeping `develop`'s `Package.swift` (Swift 6.0, local ChatField, BeeBoard, swiftSettings)
   - Keeping `develop`'s `Topic.swift` with `pendingGatewaySync`
   - Keeping `develop`'s `TopicRepository.swift` with all methods
   - Keeping `develop`'s `GatewayClient.swift` debug logging + double-resume guard
   - Keeping `develop`'s full `ClientInfo` struct
   - Adopting phase1's `TopicPublishQueue`, `publishTopicState()`, `helloResponse`
   - Keeping `develop`'s protocol v4 settings (`HelloOk ?? 4`)

4. **Verify no regressions:**
   ```bash
   swift build
   swift test
   ```

5. **Replace** `feature/gate-2f-phase1` with the rebased branch after validation.

---

## Risk Summary

| # | Blocker | Severity | Type | Risk if Merged |
|---|---|---|---|---|
| 1 | BeeBoard deleted | 🔴 Critical | B | App fails to compile; 11 commits of work lost |
| 2 | Package.swift downgrade | 🔴 Critical | B | Swift 6.0 code fails under 5.9; remote ChatField may differ from local |
| 3 | ClientInfo simplified | 🟡 Medium | B | `AppRootView.swift` compile failure; lost client metadata |
| 4 | GatewayClient refactoring | 🔴 Critical | B/A | Crash regression (double-resume); iOS build broken; debug diagnostics lost |
| 5 | Protocol version fallback | 🔴 Critical | B | Gateway handshake failure with OpenClaw 5.12+ |
| 6 | Topic field removed | 🔴 Critical | B | Database decode errors; sync state tracking broken |
| 7 | Repository methods deleted | 🟡 Medium | B/C | Public API breakage; message count computation lost |
| 8 | SyncBridge fields removed | 🟡 Medium | A | Context injection bloat; manual-reset UX regression |

**Overall Risk: 🔴 CRITICAL — Merge as-is will break the build, crash the app, and break gateway compatibility.**

---

## Appendix: Divergence Timeline

```
476c85a  (merge base)
    │
    ├── develop (54 commits) ───────────────────────────┐
    │  ├── 43e5b55 BeeBoard P1                           │
    │  ├── 74c5d8a BeeBoard P2                           │
    │  ├── ... BeeBoard P3a/P3b/P3c                      │
    │  ├── e3f363e ChatField local vendor                │
    │  ├── 99e3b69 Swift 6.0 + protocol v4 + crash fix  │
    │  ├── ... (message sort, TopicRepository v2, etc)  │
    │  └── 55bb74a (HEAD)                                │
    │                                                    │
    └── feature/gate-2f-phase1 (14 commits) ────────────┘
       ├── b5a1cb5 Phase 0: SessionInfo.pluginExtensions
       ├── 252363b Kieran review fixes
       ├── 52234f7 Phase 0 final
       ├── 76fe983 client mode "ui" fix
       ├── 7177321 Phase 1: Mac-side topic publishing
       ├── 7e6a8a9 inner Task fix
       ├── 26d9df0 Phase 2 spec docs
       ├── ... (more docs)
       └── a118e49 partial protocol v4 bump (missed HelloOk fallback)
       └── e8d73f4 AnyCodable iOS compat + iOS platform
       └── 2c372f5 (HEAD) session reset summary injection
```

The phase1 branch was created from a pre-Swift 6.0, pre-BeeBoard, pre-protocol v4 baseline and never rebased onto the advancing `develop`. This explains all blockers.

---

*Report generated by Q subagent for Gate 2F merge review.*
