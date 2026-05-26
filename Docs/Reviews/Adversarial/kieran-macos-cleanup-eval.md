# Kieran macOS Cleanup Evaluation — Gate 2F Steps 1–3

**Date:** 2026-05-26 10:35 GMT
**Reviewer:** Kieran
**Commits evaluated:** `d0c6cec` (Step 1), `3ff639d` (Step 2), `5b6a5f7` (Step 3)
**Branch:** `develop`
**Baseline:** `a0ba4eb` (last commit before these three)

---

## Key Finding

**None of the macOS-specific additions are redundant.** The macOS app had **zero** topic editing UI, **zero** project path binding, and **zero** project directory scanning/scaffolding before these commits. The `buildContextHeader` only emitted `[TOPIC-CONTEXT]\nTopic: <name>` — no project context whatsoever.

These were cherry-picked from `feature/gate-2f-unified` where they were developed alongside the iPhone implementation. The macOS app receives genuinely new functionality that it did not have before.

---

## File-by-File Classification

### Step 1 (`d0c6cec`) — Topic Sync Types and RPC Methods

#### 1. `Sources/BeeChatSyncBridge/Models/BeeChatTopicMetadata.swift` (new file, 27 lines)
**KEEP** — Shared model used by both macOS and mobile. Defines the metadata schema (`topicId`, `isArchived`, `projectPath`, `updatedAt`) published to the gateway via `sessions.pluginPatch`. No pre-existing equivalent.

#### 2. `Sources/BeeChatSyncBridge/Models/GatewaySessionInfo.swift` (new file, 34 lines)
**KEEP** — Shared model. Lightweight struct for gateway session persistence. Used by `SessionInfo.asGatewaySessionInfo` conversion (added in Step 2). Mobile needs this for its own persistence layer.

#### 3. `Sources/BeeChatSyncBridge/RPCClient.swift` (modified, +63 lines)
**KEEP** — Added 3 new RPC methods to the protocol and implementation:
- `sessionsPatch` — rename topics on gateway
- `sessionsPluginPatch` — publish metadata to gateway
- `chatInject` — session reset summary injection

All three are **shared infrastructure** used by both macOS (topic publishing, context injection) and mobile (topic sync, reset flow). The `AnyCodable` round-trip in `sessionsPluginPatch` is a genuine improvement for encoding `Codable` structs into gateway params.

#### 4. `Sources/BeeChatSyncBridge/TopicPublishQueue.swift` (new file, 31 lines)
**KEEP** — Shared actor that serialises publishing per topic. Prevents stale overwrites during rapid CRUD. Step 3 added a small fix (`queues.removeValue(forKey:)` on drain completion). Both platforms need this.

#### 5. `BEECHAT-RESTORATION-PLAN.md` (new file, 213 lines)
**KEEP** — Documentation. The restoration plan for rebuilding macOS from develop. Not code, harmless to keep.

#### 6. `BeeChatApp.app/` (bundle, 11MB binary + resources)
**REMOVE** — Build artifact committed to git. Should be in `.gitignore`. The working tree has a copy (not git-tracked), so even if removed from git, the built app survives locally. This is noise, not code.

#### 7. `Sources/BeeChatSyncBridge/Sources/SyncBridgeTests.swift` (+5 lines)
**KEEP** — Tests are always worth keeping. The +5 lines are likely new test helpers or assertions for topic publishing.

---

### Step 2 (`3ff639d`) — Additive Changes to Shared Files

#### 8. `Sources/BeeChatGateway/AnyCodable.swift` (modified, −26/+24 lines)
**KEEP** — Refactored `Equatable` implementation to use a recursive `deepEqual` nested function instead of separate `compareAnyArrays` helper. Cleaner, same behaviour, better handling of nested arrays. Both platforms share this file.

#### 9. `Sources/BeeChatGateway/GatewayClient.swift` (modified, +11 lines)
**KEEP** — Added `_helloResponse` storage, `helloResponse` accessor, and `grantedScopes()` method. Used by `SyncBridge.verifyAdminScope()` and `SyncBridge.hasAdminScope()` (added in Step 3). Shared infrastructure — both platforms need scope verification.

#### 10. `Sources/BeeChatSyncBridge/Models/SessionInfo.swift` (modified, +66 lines)
**KEEP** — Major shared enhancement:
- Added `pluginExtensions: [String: [String: AnyCodable]]?` field (gateway returns plugin-specific metadata)
- Added `beechatMetadata` convenience accessor (extracts `BeeChatTopicMetadata` from pluginExtensions)
- Added `asGatewaySessionInfo` conversion property
- Full explicit `init` added (was using memberwise init before)

Both platforms need `pluginExtensions` to receive topic metadata from the gateway. Mobile's topic sync depends on this.

#### 11. `Sources/BeeChatSyncBridge/SyncBridge.swift` (modified, +146 lines)
**KEEP** — Major shared additions:
- `publishTopicState(topic:sessionKey:)` — publishes topic name + metadata to gateway
- `clearTopicState(sessionKey:)` / `clearTopicStateWithResult` — clears metadata on topic deletion
- `reconcileAllTopicState()` — republishes all active topics on startup/reconnect
- `verifyAdminScope()` / `hasAdminScope()` — scope verification
- `fetchSessionInfos()` — raw session list with pluginExtensions
- `extractProjectPath(from:)` — helper to parse metadataJSON
- `publishQueue` property — uses TopicPublishQueue

All of these are **shared logic** used by both macOS and mobile. Mobile needs the full topic publishing pipeline.

---

### Step 3 (`5b6a5f7`) — Topic Project Binding, Context Injection, EditTopicSheet

#### 12. `Sources/App/UI/Components/EditTopicSheet.swift` (new file, 219 lines)
**KEEP** — macOS-only file, but **genuinely new functionality**. Before this commit, the macOS app had NO topic editing UI. The sidebar context menu had only "Reset Session" and "Delete Topic". The EditTopicSheet adds:
- Topic name editing
- Project binding (select from existing projects or create new)
- Project unbinding

No duplicate exists. No prior equivalent.

#### 13. `Sources/App/UI/MainWindow.swift` (modified, +116 lines)
**KEEP** — macOS-only file. The changes are:
- Added `EditTopicTarget` struct and `editTopicTarget` state variable for sheet presentation
- Added `.sheet(item: $editTopicTarget)` modifier with `EditTopicSheetWrapper`
- Added "Edit Topic" button to sidebar context menu (above existing "Reset Session")
- Added `saveTopicEdits(_:)` method — saves topic to DB, calls `requeueContextInjection` if project binding changed, refreshes topic list
- Added `EditTopicSheetWrapper` view — fetches Topic from DB before presenting the sheet, handles loading/error states

**No duplicate exists.** The context menu previously had no edit capability. No other topic editing flow exists in the macOS app.

#### 14. `Sources/App/Utils/ProjectDirectoryUtils.swift` (new file, 38 lines)
**KEEP** — macOS-only utility. Lists project directories under `/Users/openclaw/Projects/`. Used by `EditTopicSheet.onAppear` to populate the project picker. No pre-existing equivalent.

#### 15. `Sources/App/Utils/ProjectScaffolder.swift` (new file, 116 lines)
**KEEP** — macOS-only utility. Creates new project directories from `_template` with placeholder substitution. Used by `EditTopicSheet.createAndBindProject()`. No pre-existing equivalent.

#### 16. `Sources/BeeChatPersistence/Models/Topic.swift` (modified, +76 lines)
**KEEP** — Shared persistence model. Added:
- `TopicMetadata` struct (projectPath stored in metadataJSON)
- `TopicError` enum (validation errors)
- `projectPath` computed property (extracts from metadataJSON)
- `setProjectPath(_:)` mutating method with validation (prefix check, directory existence, symlink resolution)

Both platforms read/write topics. Mobile's topic sync needs `projectPath` access.

#### 17. `Sources/BeeChatPersistence/Repositories/TopicRepository.swift` (modified, +26 lines)
**KEEP** — Shared repository. Added `updateProjectPath(topicId:path:)` method. Both platforms need to persist project bindings.

#### 18. `Sources/BeeChatSyncBridge/SyncBridge.swift` (modified, +93 lines)
**KEEP** — Shared sync bridge. Added:
- `buildContextHeader` enhancement — now includes `[PROJECT-CONTEXT]` with project path, STATUS.md instructions, and ACTIVITY.md logging directive
- `requeueContextInjection(sessionKey:)` — clears injection state so next message gets fresh context
- `projectPathForSession(_:)` — resolves topic to find project path
- `formatSessionSummary(_:projectPath:)` — creates 1-2 paragraph summary from recent messages for session reset carry-forward

**Note:** `requeueContextInjection` is called from exactly one place: `MainWindow.saveTopicEdits()` (macOS). It's a shared method but only macOS uses it *today*. Mobile may use it in the future for its own topic editing flow.

**Note:** `formatSessionSummary` is defined but **not called anywhere** in the current codebase. It's infrastructure for the session reset flow. Mobile's reset flow will likely use it. Not dead code — just not yet wired into the macOS call path.

#### 19. `Sources/BeeChatSyncBridge/TopicPublishQueue.swift` (modified, +1 line)
**KEEP** — Tiny fix: `queues.removeValue(forKey: sessionKey)` on drain completion. Prevents memory leak from accumulated empty queue entries. Both platforms benefit.

#### 20. `Docs/Reviews/kieran-step1-step2-review.md` (new file, 168 lines)
**KEEP** — Review documentation.

#### 21. `Docs/Reviews/q-step1-step2-review.md` (new file, 208 lines)
**KEEP** — Review documentation.

---

## Summary

| # | File | Step | Verdict | Reason |
|---|---|---|---|---|
| 1 | `BeeChatTopicMetadata.swift` | 1 | KEEP | Shared model, both platforms need it |
| 2 | `GatewaySessionInfo.swift` | 1 | KEEP | Shared model, both platforms need it |
| 3 | `RPCClient.swift` | 1 | KEEP | 3 new shared RPC methods |
| 4 | `TopicPublishQueue.swift` | 1 | KEEP | Shared serialisation actor |
| 5 | `BEECHAT-RESTORATION-PLAN.md` | 1 | KEEP | Documentation |
| 6 | `BeeChatApp.app/` | 1 | **REMOVE** | Build artifact, belongs in `.gitignore` |
| 7 | `SyncBridgeTests.swift` | 1 | KEEP | Tests |
| 8 | `AnyCodable.swift` | 2 | KEEP | Improved shared equality implementation |
| 9 | `GatewayClient.swift` | 2 | KEEP | Shared scope verification infrastructure |
| 10 | `SessionInfo.swift` | 2 | KEEP | Shared model with pluginExtensions |
| 11 | `SyncBridge.swift` (Step 2) | 2 | KEEP | Shared topic publishing pipeline |
| 12 | `EditTopicSheet.swift` | 3 | KEEP | Genuinely new macOS UI, no duplicate |
| 13 | `MainWindow.swift` | 3 | KEEP | Genuinely new macOS integration, no duplicate |
| 14 | `ProjectDirectoryUtils.swift` | 3 | KEEP | macOS-only but no pre-existing equivalent |
| 15 | `ProjectScaffolder.swift` | 3 | KEEP | macOS-only but no pre-existing equivalent |
| 16 | `Topic.swift` | 3 | KEEP | Shared model with projectPath support |
| 17 | `TopicRepository.swift` | 3 | KEEP | Shared repository method |
| 18 | `SyncBridge.swift` (Step 3) | 3 | KEEP | Shared context injection + summary |
| 19 | `TopicPublishQueue.swift` (Step 3) | 3 | KEEP | Memory leak fix |
| 20 | `kieran-step1-step2-review.md` | 3 | KEEP | Documentation |
| 21 | `q-step1-step2-review.md` | 3 | KEEP | Documentation |

---

## Verdict

**21 files assessed: 20 KEEP, 1 REMOVE.**

**Only `BeeChatApp.app/` should be removed** — it's a build artifact that shouldn't be in git.

**No redundant macOS-only code was found.** The task premise assumed the macOS app "already has topic handling and project binding working" — this is incorrect. The baseline (`a0ba4eb`) had:
- Context menu: "Reset Session" + "Delete Topic" only (no edit)
- `buildContextHeader`: only `[TOPIC-CONTEXT]\nTopic: <name>` (no project context)
- No `EditTopicSheet`, no `ProjectDirectoryUtils`, no `ProjectScaffolder`
- No `projectPath` on `Topic` model
- No `requeueContextInjection` or `formatSessionSummary`

The cherry-picked code from `feature/gate-2f-unified` represents **genuinely new functionality** for the macOS app, not duplication.

### One item worth flagging

`formatSessionSummary` in `SyncBridge.swift` is defined but **never called** anywhere in the current codebase (macOS or mobile). It's infrastructure for the session reset flow that mobile will likely use. Not dead code, but worth noting — if the reset flow never lands on macOS, it'll only be exercised by mobile.
