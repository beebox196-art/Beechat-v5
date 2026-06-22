# FR-003 Research Pipeline — Kieran UI Review (Cycle 3)

**Date:** 2026-06-19
**Reviewer:** Kieran (adversarial)
**Spec:** `Docs/Specs/Active/FR-003-RESEARCH-PIPELINE.md` (updated with BeeChat research panel)
**Prior reviews:**
- `Docs/Specs/Active/FR-003-RESEARCH-ENTRY-KIERAN-REVIEW.md` (original — recommended slash command over UI)
- `Docs/Reviews/Cycles/research-pipeline/FR-003-KIERAN-REVIEW.md` (spec review — approved with conditions, all applied)
**Verdict:** **Approve with four conditions.** The UI integration is architecturally sound and lower-risk than I expected. Four issues need spec clarification before implementation. No blockers.

---

## Context

Adam pushed back on remembering slash command syntax. The spec now includes a minimal `ResearchPanel.swift` (~60 lines) as the primary entry point: text field + depth selector + tags + submit. It constructs the same `/research` payload and sends it through the existing WebSocket. My original review recommended against a UI panel; Adam's preference for a friendlier entry point is a legitimate product decision. This review verifies the integration is safe.

I read the actual codebase to answer each question. Findings below are evidence-based, not speculative.

---

## 1. ResearchPanel.swift Placement

**Question:** Is `Sources/App/UI/` the right location? Should it be in `Components/` or its own folder?

**Finding:** `Sources/App/UI/Components/` is the correct location. Every existing UI component lives there:

```
Sources/App/UI/Components/
├── AgentActivityPanel.swift    (221 lines)
├── BeeBoardCanvasView.swift
├── BeeBoardPinCard.swift
├── BeeBoardPinDetailView.swift
├── BeeBoardSheet.swift
├── Composer.swift              (117 lines)
├── EditTopicSheet.swift
├── FileLinkText.swift
├── FolderPicker.swift          (202 lines)
├── GatewayStatusBar.swift      (84 lines)
├── MessageBubble.swift
├── MessageCanvas.swift
├── MessageContent.swift
├── SessionRow.swift
├── StreamingBubble.swift
├── ThemePicker.swift            (121 lines)
├── ThinkingBee/
└── TypingIndicator.swift
```

`ResearchPanel.swift` at ~60 lines is smaller than most components here. It's a single-purpose panel, not complex enough to warrant its own folder. The spec says `Sources/App/UI/` — it should be `Sources/App/UI/Components/ResearchPanel.swift` to match the established pattern. Every presentable SwiftUI view in the app lives in `Components/`.

**Verdict:** Spec should say `Sources/App/UI/Components/ResearchPanel.swift`. Minor correction, not a blocker.

---

## 2. How Does the Panel Send Through the WebSocket?

**Question:** Does ResearchPanel need to call the same path? Does it need access to AppState? Does it need its own message-sending method or can it reuse the existing one?

**Finding — the actual message-sending path:**

1. `Composer` calls `onSend` closure → `MainWindow.composerSend()` → `composerViewModel.send()`
2. `ComposerViewModel.send()` calls `messageViewModel?.sendMessage(text: text)`
3. `MessageViewModel.sendMessage(text:)` does the real work:
   - Resolves the selected topic ID to a session key
   - Writes the user message to local SQLite
   - Calls `bridge.sendMessage(sessionKey:text:topic:)` on `SyncBridge`
   - `SyncBridge.sendMessage()` calls `rpcClient.chatSend()` — the actual WebSocket RPC

**The critical chain is:** `ComposerViewModel` → `MessageViewModel.sendMessage(text:)` → `SyncBridge.sendMessage()` → `RPCClient.chatSend()`.

**What ResearchPanel needs:**

ResearchPanel must produce a text string (e.g. `/research --depth standard "topic" --tags topcon`) and get it into `MessageViewModel.sendMessage(text:)`. There are two viable approaches:

### Approach A: Reuse ComposerViewModel.send() (recommended)

ResearchPanel calls the same `composerSend()` path. The panel sets `composerViewModel.inputText` to the constructed payload, then calls `composerViewModel.send()`. This is the cleanest path because:
- `ComposerViewModel.send()` already handles the send flow: trim, clear input, fire `onMessageSent` (triggers thinking indicator), call `messageViewModel.sendMessage(text:)`.
- The thinking indicator (`syncBridgeObserver.thinkingState = .thinking`) fires via `onMessageSent`, so the user sees feedback immediately.
- No code duplication.

**Risk:** Setting `composerViewModel.inputText` programmatically is a side-channel. If `ComposerViewModel.send()` is refactored to read `inputText` differently (e.g. async validation), this could break. Low risk, but worth noting.

### Approach B: Call MessageViewModel.sendMessage(text:) directly (cleaner but bypasses thinking indicator)

ResearchPanel calls `messageViewModel.sendMessage(text: payload)` directly. This sends the message but skips `onMessageSent`, so the thinking indicator doesn't fire. The user submits research and sees no visual feedback until streaming starts. This is a UX regression.

**My recommendation:** The spec should specify Approach A. ResearchPanel needs:
- Access to `ComposerViewModel` (to set inputText and call send) OR a dedicated method on ComposerViewModel that accepts a pre-constructed payload
- Access to `AppState` is NOT needed — the panel doesn't need to know about the WebSocket, SyncBridge, or connection state. It just needs to get text into the send pipeline.

**Condition C1:** The spec must specify how ResearchPanel accesses the send pipeline. The cleanest approach: add a `func sendPayload(_ text: String)` method to `ComposerViewModel` that wraps `inputText = text; send()`. ResearchPanel calls this via the same `onSend` closure mechanism. This avoids programmatically setting `inputText` (which is fragile) and keeps the thinking indicator working.

**Does ResearchPanel need AppState?** No. `AppState` manages the WebSocket connection, startup, and reconnection. ResearchPanel doesn't touch any of that. It constructs a text payload and hands it to the existing send chain. The spec's claim "no AppState changes" is correct and verifiable.

---

## 3. Sidebar/Toolbar Button — Where Should the "Research" Button Go?

**Finding:** The sidebar toolbar in `MainWindow.swift` has a button bar at the bottom of the sidebar `VStack`:

```swift
HStack(spacing: 12) {
    Button(action: { showNewTopicDialog = true }) { ... }    // New Topic
    Button(action: { showFolderPicker = true }) { ... }      // Folders
    Button(action: { showAgentActivity = true }) { ... }     // Team Activity
    Button(action: { showBeeBoard = true }) { ... }           // BeeBoard
    Button(action: { showThemePicker = true }) { ... }       // Appearance
    if messageViewModel.selectedTopicId != nil {
        Button(action: { deleteTopic(id) }) { ... }          // Delete (conditional)
    }
}
```

This is a 5-button HStack (6th button appears conditionally when a topic is selected). Adding a 6th permanent button makes it a 6-button HStack (7th conditional). With `spacing: 12` and icon size `.body`/`.subheading`, this fits within the sidebar width (min 180, ideal 240, max 320).

**Risk assessment:**

At 240px ideal width with 6 permanent buttons: 6 icons × ~20px + 5 gaps × 12px = ~180px. This fits, but it's getting tight. At 180px (minimum), it would be cramped. The delete button appears conditionally, making it 7 buttons at minimum width.

**Recommendation:** Use a system icon that's visually distinct (e.g. `magnifyingglass.circle` or `safari` for research) and add it between BeeBoard and Appearance. The existing pattern is identical for every button — copy it. The layout risk is real but manageable at ideal width.

**Alternative:** Consider a toolbar button in the detail view header (above GatewayStatusBar) instead of the sidebar. This avoids sidebar crowding and is where "action on the current view" buttons typically go in macOS apps. However, the spec says "sidebar or a toolbar button" — either is acceptable. The sidebar is simpler because it follows the exact same pattern as the other 5 buttons.

**Verdict:** Sidebar button is acceptable. Spec should note the width constraint risk at minimum sidebar width (180px).

---

## 4. State Management — Is "local @State, no AppState changes" Actually Possible?

**Finding:** Yes, this is verifiably possible.

The spec says ResearchPanel uses local `@State` for:
- `researchText: String` (text field content)
- `selectedDepth: Depth` (depth selector — quick/standard/deep)
- `tags: String` (tags field)

Looking at the existing pattern: `GatewayStatusBar` is a good parallel. It takes `connectionState` and `detailText` as parameters, reads `AppState` from `@Environment` for display logic, but doesn't modify AppState. `ThemePicker`, `FolderPicker`, `BeeBoardSheet`, and `AgentActivityPanel` are all presented as sheets with purely local state.

**Does the panel need to trigger a new session/topic?** No. The spec says the payload goes through the existing WebSocket to the current topic. The response comes back as a message in the current topic's chat view. No new topic creation needed.

**Does the research output come back as a message in the current topic?** Yes — this is the key design decision. The `/research` payload is just text sent through `SyncBridge.sendMessage()`. The gateway treats it as a normal user message. Bee parses the `/research` prefix server-side and routes to Gav. The response comes back through the normal streaming pipeline (`SyncBridgeObserver.didStartStreaming` → `didStopStreaming`), renders in the current topic's `MessageCanvas`, and is persisted to the same session key.

This means:
- No new session creation
- No topic switching
- No session key management
- No AppState mutation
- No environment object additions

**Verdict:** The "local @State only" claim is accurate. The panel is a text constructor — it builds a payload and hands it to the existing send chain. Everything after that is existing infrastructure.

---

## 5. Message Flow — Where Does the Response Go?

**Finding:** The response goes into the **current topic's chat view**. This is the only sensible option given the architecture, and the spec is correct to use it.

**The full flow:**

1. User opens ResearchPanel (sheet or popover from sidebar button)
2. User enters topic, selects depth, optional tags
3. Panel constructs payload: `/research --depth standard "topic" --tags tag1,tag2`
4. Panel sends payload via existing `ComposerViewModel` → `MessageViewModel.sendMessage(text:)`
5. `MessageViewModel` writes user message to SQLite, calls `SyncBridge.sendMessage()`
6. `SyncBridge` sends via WebSocket RPC (`chatSend`)
7. Gateway receives message, Bee parses `/research`, dispatches to Gav
8. Gav runs pipeline, sends progress message + final summary back through gateway
9. Gateway streams response back → `SyncBridge` processes deltas → `SyncBridgeObserver` receives streaming events
10. Streaming content renders in the current topic's `MessageCanvas`
11. On completion, `SyncBridge.fetchHistory()` persists the final message to SQLite

**UX consideration:** The research response appears in the chat as a normal assistant message. The user sees:
- Their own message: `/research --depth standard "topic" --tags tag1,tag2` (visible in chat)
- Progress message: "Researching: topic — Depth: standard — Est. 8 min"
- Final summary: 3-5 bullet points + link to HTML report

**Risk:** If the user submits research and then switches topics, the response will stream into the original topic (not the one they switched to). The existing `SyncBridgeObserver` handles this correctly — it tracks `streamingSessionKey` and only shows streaming content when the matching topic is selected. Background streaming is handled by the `isStreamingSession()` check. This is existing, tested behaviour (see Phase 2 streaming work).

**Verdict:** Message flow is correct and uses existing infrastructure. No new routing needed.

---

## 6. Cross-Stream Risk — Does This Touch Shared Packages?

**Finding:** No. Verified against `Package.swift`:

```
Sources/App/                    → BeeChatApp target (executable)
Sources/BeeChatPersistence/    → BeeChatPersistence library
Sources/BeeChatGateway/         → BeeChatGateway library
Sources/BeeChatSyncBridge/      → BeeChatSyncBridge library
Sources/BeeBoard/               → BeeBoard library
```

The spec adds:
- `Sources/App/UI/Components/ResearchPanel.swift` — new file in the **App** target only
- Small modification to `Sources/App/UI/MainWindow.swift` — App target only

None of these are in shared packages. `BeeChatSyncBridge`, `BeeChatPersistence`, `BeeChatGateway`, and `BeeBoard` are untouched. The iOS app (BeeChat-Mobile) depends on the shared packages, not on the App target — so it's unaffected.

**Verdict:** No cross-stream risk. Confirmed.

---

## 7. Impact on Existing Features

### Composer
**No impact.** ResearchPanel is a separate view that feeds into the same `ComposerViewModel.send()` path. The Composer itself (`Composer.swift`) is not modified. The panel doesn't change how the composer works, doesn't interfere with its input, and doesn't share state with it (beyond using `ComposerViewModel` as the send mechanism).

### Topic Management
**No impact.** No new topics are created. No topic switching occurs. The research payload goes to the currently selected topic's session. The existing `sidebarSelection` binding, `messageViewModel.selectTopic()`, and topic observation pipeline are untouched.

### Session Handling
**No impact.** `SyncBridge.sendMessage()` is called with the existing session key. No new sessions are created. The auto-reset logic in `SyncBridge` applies normally (if usage is at 80%, it will auto-reset before sending — this is correct behaviour, not a side effect).

**One thing to note:** The auto-reset context injection will fire for `/research` messages just like any other message. If a session is at 80% usage and the user submits a research request, the session will auto-reset, and the research payload will be preceded by `[SESSION-CONTEXT]` with the last 30 messages. This is correct — the research request should carry context like any other message. But it means the `/research` prefix will be preceded by context text. Bee's parsing needs to handle this (look for `/research` anywhere in the message, not just at the start). This is a server-side concern, not a BeeChat concern, but worth flagging.

### Streaming/Thinking Indicator
**No impact** if using Approach A (reuse ComposerViewModel). The `onMessageSent` callback fires, setting `thinkingState = .thinking`. The thinking bee appears, and the user sees feedback. When streaming starts, `didStartStreaming` transitions to `.streaming`. Normal flow.

**Impact** if using Approach B (call MessageViewModel directly): The thinking indicator won't fire. User sees no feedback until streaming starts (which could be 30+ seconds for research). This is why Approach A is required.

### Existing Sheets
**No impact.** The spec adds one more `.sheet(isPresented:)` modifier. SwiftUI handles multiple sheets via `.sheet()` modifiers — only one sheet can be presented at a time. Adding a `.sheet(isPresented: $showResearchPanel)` alongside the existing 5 sheets follows the exact same pattern. No conflict.

### Keyboard Shortcuts
**No impact.** The spec doesn't mention keyboard shortcuts. If one is desired later (e.g. ⌘R for research), it would go in the `CommandMenu("Chat")` group in `BeeChatApp`. Not needed for MVP.

---

## 8. Build/Test Impact

### Build
**No new targets needed.** `ResearchPanel.swift` goes into the existing `BeeChatApp` executable target (path: `Sources/App`). The `Package.swift` doesn't need changes — the target already compiles all `.swift` files in `Sources/App/`.

### Tests
**No new test targets needed.** The existing `BeeChatAppTests` target (path: `Tests/BeeChatAppTests`) can hold tests for ResearchPanel if needed. However, since ResearchPanel is a pure UI view with no logic beyond constructing a text payload, unit testing the payload construction would be appropriate:

```swift
func testResearchPayloadConstruction() {
    // Verify /research --depth standard "topic" --tags tag1,tag2
}
```

**Existing tests:** No risk of breaking existing tests. `TopicViewModelTests` and `FilePathParserTests` test view models and parsers, not UI views. Adding a new SwiftUI view doesn't affect them.

**Build verification:** The project builds with `swift build`. Adding a ~60-line SwiftUI file to `Sources/App/UI/Components/` will compile cleanly as long as it uses existing imports (`SwiftUI`, `BeeChatSyncBridge` if needed). No new dependencies required.

---

## Conditions (fix before implementation)

### C1: Specify the send pipeline connection

The spec says "sends it through the existing WebSocket" but doesn't specify how ResearchPanel accesses the send pipeline. The spec should state:

> ResearchPanel calls a dedicated `sendPayload(_ text: String)` method on `ComposerViewModel`, which wraps `inputText = text; send()`. This reuses the existing send chain and preserves the thinking indicator. ResearchPanel receives `ComposerViewModel` as a parameter, the same way `Composer` does.

This prevents the implementer from choosing Approach B (direct `MessageViewModel` call) which would break the thinking indicator.

### C2: Correct the file path

Spec says `Sources/App/UI/ResearchPanel.swift`. Should be `Sources/App/UI/Components/ResearchPanel.swift`. Every presentable SwiftUI component in the app lives in `Components/`.

### C3: Note the auto-reset context interaction

The spec should add a one-liner in the implementation notes:

> If the current session is at 80% usage, auto-reset will fire before the research message. The `/research` payload will be preceded by `[SESSION-CONTEXT]`. Bee's command parsing must handle this — search for `/research` in the message body, not just at position 0.

This is a server-side concern, but flagging it here prevents a "why isn't `/research` being recognised?" debugging session later.

### C4: Note sidebar width constraint

The spec should note:

> The sidebar toolbar currently has 5 permanent buttons. Adding a 6th is within the HStack's fit at ideal width (240px) but will be cramped at minimum width (180px). Use a compact icon (`.body` size) and verify layout at minimum sidebar width.

---

## Non-Blocking Recommendations

1. **Sheet vs. popover:** Consider a popover anchored to the research button rather than a sheet. A sheet takes over the window; a popover is lighter and lets the user see the chat while composing the research request. SwiftUI's `.popover()` is well-suited for this. If a sheet is preferred, keep it small (no full-window takeover).

2. **Empty topic guard:** If no topic is selected (`messageViewModel.selectedTopicId == nil`), the research button should be disabled or show a prompt to create a topic first. `MessageViewModel.sendMessage()` silently returns if there's no selected topic — the user would see nothing happen.

3. **Payload visibility:** The user's chat will show `/research --depth standard "topic" --tags tag1,tag2` as their message. Consider whether this is desirable UX (it shows what was requested) or whether it should be hidden/summarised. My recommendation: show it. Transparency is better than magic. The user can see exactly what was sent.

4. **Dedicated `sendPayload` method:** Rather than setting `inputText` and calling `send()`, add a clean method to `ComposerViewModel`:
   ```swift
   func sendPayload(_ text: String) async {
       guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
       onMessageSent?()
       do {
           try await messageViewModel?.sendMessage(text: text)
       } catch {
           BeeChatLogger.log("[ResearchPanel] Send failed: \(error)")
       }
   }
   ```
   This avoids touching `inputText` (which is bound to the composer's text field) and is a cleaner contract. The existing `send()` method stays unchanged for the composer.

---

## Summary

| Question | Answer | Evidence |
|---|---|---|
| 1. ResearchPanel placement | `Sources/App/UI/Components/` — matches all existing components | Directory listing confirms pattern |
| 2. WebSocket send path | Reuse `ComposerViewModel` → `MessageViewModel.sendMessage()` → `SyncBridge.sendMessage()` → `RPCClient.chatSend()` | Full call chain verified in source |
| 3. Sidebar button | Add to existing HStack button bar in sidebar. 6 buttons fit at ideal width. | `MainWindow.swift` lines 67-120 |
| 4. Local @State possible? | Yes. Panel constructs text, hands to existing send chain. No AppState, no session creation. | `GatewayStatusBar`, `ThemePicker` follow same pattern |
| 5. Message flow | Response goes to current topic's chat view via existing streaming pipeline. | `SyncBridgeObserver` + `MessageCanvas` flow verified |
| 6. Cross-stream risk? | None. Only `Sources/App/` modified. Shared packages untouched. | `Package.swift` target paths confirmed |
| 7. Impact on existing features | None. Composer, topics, sessions, streaming all untouched. Auto-reset fires normally. | Source analysis of all affected paths |
| 8. Build/test impact | No new targets. No test breakage. Compiles into existing `BeeChatApp` target. | `Package.swift` target structure verified |

---

## Verdict

**Approve with four conditions (C1–C4).** All are spec clarifications, not design changes. The architecture is sound:

- ResearchPanel is a text constructor, not a new communication path
- It reuses the entire existing send + streaming pipeline
- No shared package changes
- No AppState mutation
- No new session/topic creation
- No impact on composer, topic management, or session handling

The panel is the right size (~60 lines) for what it does: build a text payload and hand it to the existing infrastructure. The thinking indicator, streaming, message persistence, and error handling all work because they're inherited from the existing send chain.

This is a clean integration. Address C1–C4 in the spec and proceed to implementation.

---

*Kieran — 2026-06-19*