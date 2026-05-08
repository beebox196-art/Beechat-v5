Updated: 2026-05-08T14:21:00Z
From/To: Q → Team
Task: Implement BC5-SPEC-004 Topic Context Injection (Phase 1)
State: Complete — all changes built, tested, committed
Next: Manual QA — create a topic, send a message, verify the [TOPIC-CONTEXT] header appears in the gateway; send a second message and verify no header; reset session and verify header re-injects
Blockers: None
Files: Sources/BeeChatSyncBridge/SyncBridge.swift, Sources/App/UI/ViewModels/MessageViewModel.swift, Sources/App/UI/MainWindow.swift, Tests/BeeChatSyncBridgeTests/Sources/SyncBridgeTests.swift

## What was done

All 10 checklist items from BC5-SPEC-004 v3 implemented:

1. **`contextInjectedKeys: Set<String>`** — added to `SyncBridge` as private instance variable
2. **`buildContextHeader(topic:)`** — returns `[TOPIC-CONTEXT]\nTopic: {name}`
3. **`topic: Topic? = nil`** parameter on `sendMessage` — default nil, zero call-site breakage
4. **`var didAutoReset = false`** — local flag inside `sendMessage`, set `true` after auto-reset succeeds
5. **Context injection block** — after auto-reset, before ledger creation; if `isTopicContextEnabled && let topic && !contextInjectedKeys.contains(sessionKey)`: if `!didAutoReset` prepend header; always insert key
6. **`contextInjectedKeys.remove(sessionKey)`** in `resetSession()` — context re-injects after manual resets
7. **`[TOPIC-CONTEXT]` filter** in `fetchLocalHistory` — alongside `[SESSION-CONTEXT]` and `[SESSION-RESET]`
8. **`isTopicContextEnabled`** — computed property using `UserDefaults.standard`, defaults `true`
9. **UI wiring** — `MessageViewModel.sendMessage` resolves the current Topic and passes it to `SyncBridge.sendMessage`; `MainWindow.createNewTopic` passes the new Topic on the initial "Start" message
10. **Tests** — 3 new tests: `testBuildContextHeaderReturnsCorrectFormat`, `testBuildContextHeaderWithSpecialCharacters`, `testFetchLocalHistoryFiltersTopicContext` — all pass

## Deviations from spec

None. Implementation follows BC5-SPEC-004 v3 exactly.

## Things to test manually

- Create a new topic, send a message → verify `[TOPIC-CONTEXT]` header in the sent text
- Send a second message in the same topic → verify NO header (key already in set)
- Trigger auto-reset (high usage) → verify only `[SESSION-CONTEXT]`, no `[TOPIC-CONTEXT]`, but key is inserted preventing double-injection on next call
- Manual session reset → verify context re-injects on next send
- Feature flag `feature_topicContextInjection = false` → verify injection skipped entirely