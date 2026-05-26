# Kieran — Gate 2F Merge Adversarial Review

**Date:** 2026-05-26 09:16 BST
**Scope:** `feature/gate-2f-phase1` + `feature/gate-2f-unified` → `develop`
**Reviewer:** Kieran (adversarial — looking for macOS breakage, cross-device coupling)

---

## A. Coupling Risks

### A1. GatewayClient hardcoded to macOS — iOS will break

**VERDICT: BLOCKER**

`GatewayClient.Configuration` default in phase1 hardcodes macOS:

```swift
// phase1 — GatewayClient.swift line 30
self.clientInfo = clientInfo ?? .init(id: "openclaw-macos", version: "1.0", platform: "macos", mode: clientMode)
```

On `develop`, this was a platform-conditional (`#if os(iOS)` / `#elseif os(macOS)`). Phase1 replaces it with a hardcoded macOS identity. If BeeChat Mobile (iOS) shares this library target — which it must, since BeeChatSyncBridge and BeeChatGateway are shared — iOS will identify itself as `openclaw-macos` with `platform: "macos"`. The gateway may reject it, mis-route events, or refuse pairing.

Similarly, `DeviceCrypto.signChallenge` default parameters changed from platform-conditional to hardcoded `"macos"` / `"desktop"`.

And `userAgent` is hardcoded: `"BeeChat/1.0 (macOS)"`.

**Fix needed:** Restore the `#if os(iOS)` / `#elseif os(macOS)` guards in `GatewayClient.Configuration`, `DeviceCrypto.signChallenge`, and `userAgent`.

### A2. `processChatDelta` lost the `replace` parameter

**VERDICT: BLOCKER**

Phase1 changes the signature from:
```swift
func processChatDelta(sessionKey: String, text: String, replace: Bool = true) async
```
to:
```swift
func processChatDelta(sessionKey: String, text: String) async
```

The implementation always does replacement (`streamingBuffer[sessionKey] = text`). The old code had append logic for incremental delta streaming (`+= text` when `replace == false`).

EventRouter was simplified to always call `processChatDelta(sessionKey:, text:)` with just `messageText`. The `deltaText` + `replace` path (v4 incremental deltas) is gone entirely.

If the gateway ever sends incremental `deltaText` with `replace: false`, those deltas will be silently lost — the last chunk overwrites everything.

This works fine if the gateway always sends cumulative `messageText`, but if iOS and macOS connect to different gateway protocol versions, one device's streaming may break.

### A3. `aborted` event handling removed from EventRouter

**VERDICT: WARNING**

Phase1 removes the `case "aborted"` handler:
```diff
-        case "aborted":
-            try await syncBridge.processChatError(sessionKey: sessionKey, errorMessage: chatEvent.stopReason ?? "Aborted")
```

If the gateway sends an `aborted` state event, it falls through to `default:` which just logs `"Unknown event received: aborted"`. The streaming session won't be terminated — the UI may show a spinner forever.

### A4. `reconcileAllTopicState` fires on every reconnect

**VERDICT: WARNING**

Phase1 calls `reconcileAllTopicState()` on initial connect AND on every reconnection. It spawns `Task.detached` with a `TaskGroup` of up to 5 concurrent publishes.

If reconnects are frequent (unstable network), this creates bursts of `sessions.patch` + `sessions.pluginPatch` RPC calls. The gateway may rate-limit, and some publishes will silently fail (fire-and-forget with `print` only).

More concerning: `reconcileAllTopicState` calls `TopicRepository(dbManager: DatabaseManager.shared)` from a detached task — it's not using the `config.persistenceStore` that SyncBridge was initialised with. This is a different code path for persistence access that may not match the DB state if there's concurrent access.

### A5. `handleSessionsChanged` calls `MainActor.run` from SyncBridge actor

**VERDICT: WARNING**

EventRouter's `handleSessionsChanged` does:
```swift
let delegate = await syncBridge.delegate
await MainActor.run {
    delegate?.syncBridgeSessionsChanged(syncBridge)
}
```

This crosses from the `SyncBridge` actor's executor to `MainActor`. If `syncBridge.delegate` is nonisolated or accessed from a different isolation context, this could cause a data race. The `SyncBridgeDelegate` protocol methods are `nonisolated` in the default extension, so this should be safe — but it's fragile.

---

## B. Regression Risks

### B1. SyncBridge rewrite: +446/-681 lines — macOS-only behavior changes

**VERDICT: WARNING**

The SyncBridge diff is massive. Key behavioral changes for macOS-only operation:

| Old Behavior | New Behavior | Risk |
|---|---|---|
| `sendMessage(text:, topic:)` | `sendMessage(text:)` — no topic param | **BLOCKER** (see B2) |
| Manual reset returns `Bool` | Manual reset returns `Void` (throws) | API break |
| `pendingResetContext` stored context for next send | Summary is injected immediately via `chatInject` | **BLOCKER** (see B3) |
| Auto-reset at 80% threshold | Auto-reset at `redDotThreshold` (50%) | Behavioral change |
| `formatCombinedContext` = raw message dump | `formatSessionSummary` = AI summary | Content change |
| `clearPendingResetContext(except:)` | Removed entirely | **BLOCKER** (see B5) |
| `contextInjectedKeys` for topic headers | Removed | Feature removed |

### B2. `sendMessage` lost the `topic` parameter — unified branch still uses it

**VERDICT: BLOCKER**

Phase1 changes `sendMessage` to:
```swift
public func sendMessage(sessionKey: String, text: String, thinking: String? = nil, attachments: [ChatAttachment]? = nil) async throws -> String
```

The unified branch retains the OLD signature with `topic: Topic? = nil`.

`MainWindow.swift` in phase1 was updated to call `sendMessage(sessionKey:, text:, thinking:)` without `topic`. But `MessageViewModel.swift` in phase1 was also updated to remove the `topic` parameter.

**When these two branches merge**, the unified branch's `SyncBridge.sendMessage` will still have the `topic` parameter, and its callers (which may not be updated in the unified branch) will either conflict or — worse — silently compile with a different signature than phase1 expects.

### B3. Reset flow: immediate `chatInject` replaces deferred context injection

**VERDICT: BLOCKER**

Old flow (develop):
1. User resets → store `pendingResetContext[sessionKey]`
2. Next `sendMessage` → prepend context to user's message
3. Context consumed and cleared

New flow (phase1):
1. User resets → immediately call `rpcClient.chatInject(sessionKey:, message:, label:)` 
2. Summary injected into new session via separate RPC
3. User's next `sendMessage` is just the user's text

This requires the `chat.inject` RPC endpoint to exist on the gateway. If it doesn't (or if it has a different signature), the entire reset flow fails silently after retry.

The `chatInject` method was added to `RPCClient` in phase1. If the gateway doesn't support `chat.inject`, all resets will fail — and the user gets a toast (new delegate method `syncBridgeDidFailSummaryInjection`), but the session is still reset with NO context carried forward.

### B4. `Topic.pendingGatewaySync` property removed

**VERDICT: WARNING**

The `pendingGatewaySync` column was removed from the `Topic` model and from `upsertColumns`. This is a schema change — existing databases will have a `pendingGatewaySync` column that's no longer referenced.

`markSynced()` no longer clears the flag (it just updates `updatedAt`). If a migration doesn't drop the column, there's a ghost column. If a migration DOES drop the column, the schema change is fine.

But `fetchPendingSyncTopics()` was reimplemented to filter on `sessionKey != nil` instead of `pendingGatewaySync == true`. This changes semantics: it now returns ALL non-archived topics with a session key, not just those pending sync.

### B5. `clearPendingResetContext(except:)` removed — MainWindow called it

**VERDICT: BLOCKER**

The phase1 diff shows this call removed from `MainWindow.swift`:
```swift
// OLD — removed in phase1
.onChange(of: messageViewModel.selectedTopicId) { _, _ in
    if let bridge = appState.syncBridge {
        Task {
            await bridge.clearPendingResetContext(except: messageViewModel.selectedTopic?.sessionKey)
        }
    }
}
```

This is correct for phase1 because `pendingResetContext` no longer exists. BUT the unified branch still has `pendingResetContext` and the old `sendMessage` flow. If the unified branch's `MainWindow` still calls `clearPendingResetContext`, the merge will either conflict or leave a dangling call to a removed method.

### B6. `manualReset` return type changed from `Bool` to `Void`

**VERDICT: WARNING**

Old: `public func manualReset(sessionKey: String) async throws -> Bool`
New: `public func manualReset(sessionKey: String) async throws`

`MainWindow.swift` in phase1 was updated:
```swift
try await bridge.manualReset(sessionKey: sessionKey)
// OLD had: _ = try await bridge.manualReset(...) and checked the Bool
```

But any other callers (tests, other code paths) that depend on the `Bool` return value will break at compile time.

---

## C. Architecture Risks

### C1. Gateway-is-truth pattern — reconciliation fires too eagerly

**VERDICT: WARNING**

Phase1 calls `reconcileAllTopicState()` on initial connect BEFORE the first event stream starts. This means topics are published to the gateway immediately, potentially before the gateway has finished processing the connection handshake.

The `verifyAdminScope()` call happens synchronously in `start()`. If the handshake hasn't completed yet (the `_helloResponse` is set during handshake processing), `grantedScopes()` returns empty and logs a warning — but continues. This means topic publishing may fire without confirmed admin scope, leading to silent 403 errors on `sessions.pluginPatch`.

### C2. TopicPublishQueue is shared, not Mac-only

**VERDICT: PASS**

`TopicPublishQueue` is in the `BeeChatSyncBridge` target, which is shared. However, it's only used by `SyncBridge.publishTopicState()`, which is only called from macOS's `MainWindow` (topic creation/deletion). The iPhone doesn't call `publishTopicState`.

The queue itself is harmlessly additive — if iOS creates a SyncBridge, the queue exists but is never used.

### C3. RPCClient new methods — additive, not replacing

**VERDICT: PASS**

The new RPCClient methods (`sessionsPatch`, `sessionsPluginPatch`, `chatInject`) are additive to the `RPCClientProtocol`. They don't replace or modify existing methods. The protocol is extended, not changed.

### C4. BeeChatTopicMetadata and GatewaySessionInfo — additive

**VERDICT: PASS**

Both are new structs in `BeeChatPersistence/Models/`. They're pure data carriers, no side effects. `BeeChatTopicMetadata` is `Codable, Sendable, Equatable` — clean.

### C5. `SessionInfo.pluginExtensions` addition

**VERDICT: PASS**

The `pluginExtensions` field is optional (`nil` when not present). The `beechatMetadata` computed property safely extracts from it with optional chaining. Backwards compatible.

---

## D. Deletion Audit

### D1. BeeBoard* files deleted

**VERDICT: PASS**

All BeeBoard UI components, view models, models, repositories, and services were deleted. `BeeBoard` target was removed from `Package.swift`. `import BeeBoard` was removed from `AppRootView.swift`. `BeeBoardMigrator.migrate()` call was removed from `AppState`.

The `showBeeBoard` state, BeeBoard toolbar button, and BeeBoard sheet were all removed from `MainWindow.swift`.

This is a clean deletion — no dangling references found.

### D2. ChatField vendor deleted — replaced by SPM dependency

**VERDICT: WARNING**

The vendored `Vendors/ChatField/` was deleted and replaced with:
```swift
.package(url: "https://github.com/kevinhermawan/ChatField", from: "3.0.4")
```

The `Composer.swift` component wraps ChatField with `#if canImport(AppKit)` guards for macOS-specific Option+Return behavior. If the SPM version 3.0.4 has a different API than the vendored version, this could break compilation or runtime behavior.

**The vendored version's API is no longer available for comparison.** This is a risk.

### D3. FileLinkText deleted — replaced by plain Text

**VERDICT: WARNING**

`FileLinkText` and `FilePathParser` were deleted. `MessageContent` now uses plain `Text(content)` instead. Clickable file path links in assistant messages are gone.

This is a user-visible regression for macOS users who relied on clickable file paths in AI responses. Not a compilation issue, but a feature loss.

`FilePathParserTests.swift` was also deleted (no test coverage for the path parsing that's been removed).

### D4. SessionKeyNormalizer moved to BeeChatPersistence

**VERDICT: PASS**

Moved from `Sources/BeeChatSyncBridge/Utilities/SessionKeyNormalizer.swift` to `Sources/BeeChatPersistence/Utilities/SessionKeyNormalizer.swift`. The implementation is identical (just Foundation import, no BeeChatPersistence dependency — the old version imported BeeChatPersistence unnecessarily).

All callers (`MainWindow`, `SyncBridgeObserver`, `SyncBridge`) access it through their existing target dependencies. BeeChatSyncBridge depends on BeeChatPersistence, so it's available. Clean move.

### D5. GatewayEventPayloads.swift lost 30 lines

**VERDICT: WARNING**

The v4 streaming fields were removed from `ChatEventPayload`:
- `runId`, `seq`, `spawnedBy`, `deltaText`, `replace`, `stopReason`, `errorKind`

These are no longer parsed from gateway events. If the gateway sends these fields, they're silently ignored. The `deltaText` removal is the most concerning — it's tied to the incremental streaming protocol (see A2).

### D6. MessageListObserver diff guard removed

**VERDICT: WARNING**

`messagesDiffer()` was removed from `MessageListObserver`. The old code had a diff guard to prevent SwiftUI churn from GRDB's reference-only yields. Without it, `setAllMessages` always calls `applyWindow()` even when data hasn't changed.

This may cause unnecessary UI recomputation but won't break functionality.

---

## E. Merge Conflict Forecast

**These areas will definitely conflict when merging phase1 + unified → develop:**

| File | Conflict Area |
|---|---|
| `SyncBridge.swift` | `sendMessage` signature, reset flow, context injection, `processChatDelta` |
| `Topic.swift` | `pendingGatewaySync` removal (phase1) vs `projectPath` addition (unified) |
| `TopicRepository.swift` | Both branches rewrite extensively — overlapping changes |
| `MainWindow.swift` | Reset alert removal (phase1) vs topic-project UI (unified) |
| `GatewayClient.swift` | macOS hardcoding (phase1) vs potential iOS changes (unified) |
| `Package.swift` | BeeBoard removal + ChatField SPM (phase1) vs unified additions |
| `ConnectParams.swift` | ClientInfo simplification (phase1) vs unified |
| `SyncBridgeDelegate.swift` | New delegate methods (phase1) vs unified |

---

## Summary

| Rating | Count | Items |
|---|---|---|
| **BLOCKER** | 6 | A1, A2, B2, B3, B5, (A4 partially) |
| **WARNING** | 11 | A3, A4, B1, B4, B6, D2, D3, D5, D6, C1 |
| **PASS** | 5 | C2, C3, C4, C5, D1, D4 |

### Must Fix Before Merge:

1. **A1** — Restore platform conditionals in GatewayClient. iOS MUST not identify as macOS.
2. **A2** — Verify the gateway's streaming protocol. If it sends incremental deltas, the append logic is needed.
3. **B2** — Resolve `sendMessage` signature conflict between branches. Unified has `topic`, phase1 doesn't.
4. **B3** — Verify `chat.inject` RPC endpoint exists on the gateway before relying on it for resets.
5. **B5** — Ensure `clearPendingResetContext` calls are removed from ALL branches.

### Should Fix Before Merge:

6. **A3** — Restore `aborted` event handling in EventRouter.
7. **D2** — Verify ChatField SPM 3.0.4 API matches the vendored version.
8. **D3** — Consider whether losing clickable file links is acceptable for macOS users.
9. **C1** — Add a delay or confirmation gate before `reconcileAllTopicState` fires on connect.
