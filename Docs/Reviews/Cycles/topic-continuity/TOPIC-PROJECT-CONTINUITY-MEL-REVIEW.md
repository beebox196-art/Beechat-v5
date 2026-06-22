# Mel Review: TOPIC-PROJECT-CONTINUITY.md

**Reviewed:** 2026-05-30T18:55:00+01:00  
**Reviewer:** Mel (UI/UX + frontend architecture)  
**Scope:** SwiftUI state/reactivity, message rendering/scrolling, EditTopicSheet UX, cross-platform project file provider, sidebar performance  
**Verdict:** ⚠️ APPROVE-WITH-CHANGES

Note: I reviewed with the active Codex/GPT-5 runtime available in this session. I do not have a separate callable `openai-codex/gpt-5.5` selector in this subagent environment.

---

## Findings

### 🚨 Critical

#### CRITICAL-1: The spec's cross-platform story can mislead iOS users into thinking real project context was injected

The spec says the provider abstraction makes this work on both macOS and iOS, but the proposed `StubProjectFileProvider` returns only:

```swift
[Project: \(name) — files read by Mac gateway and injected into session]
```

That is not actual project context. Unless there is a Mac-side gateway injection path that intercepts iOS `chat.send` and replaces this stub with file contents, an iOS send from a project-bound topic will still reach the agent without `STATUS.md`, `README.md`, `decisions.md`, or `corrections.md`.

**UI/UX impact:** the topic can look bound while the agent behaves as if no useful project memory exists. That is worse than no UI because it creates false confidence.

**Required change:** define the iOS data path explicitly before implementation:

- If iOS cannot inject real files, show project binding as "Linked on Mac" or "Context unavailable on this device" and do not present the same success state as macOS.
- If the Mac gateway will inject real content, specify the bridge point and add a manual iOS verification case that proves the agent receives actual file text, not a placeholder.
- The provider protocol should return a result with capability/status, not just `String`, so UI can surface degraded context accurately.

#### CRITICAL-2: Project context file reads must not run on the main actor or inside sidebar refresh paths

The current UI observation path is main-actor scheduled: `MainWindow.startLocalTopicObservation()` receives topic updates and calls `MessageViewModel.updateTopics(from:)`, which rebuilds `TopicViewModel.sorted(from:)`. The spec only adds `projectPath` passthrough here, which is fine. But any future attempt to preview file contents in `TopicViewModel`, `SessionRow`, or the topic observation callback would put synchronous file I/O on the main actor and degrade sidebar scrolling/selection.

**Evidence checked:** `TopicViewModel` currently only maps lightweight fields (`id`, `name`, `sessionKey`, counts). `SessionRow` renders those values only. `ProjectContextReader.read()` is proposed for `SyncBridge.buildContextHeader`, not the list row path.

**Required change:** add a non-negotiable implementation note: project files are read only during send/context building, never during `TopicViewModel` init, topic list observation, `SessionRow.body`, or `EditTopicSheet.body`. If a preview is added, it must be async/cached and cancellable.

### ⚠️ Warning

#### WARNING-1: Adding `projectPath` to `TopicViewModel` should not affect current SwiftUI list identity, but the explicit `Hashable` fix is still required

I found no current SwiftUI view that uses `TopicViewModel` equality directly for animations, transitions, or row identity. The sidebar uses:

- `ForEach(messageViewModel.topics) { topic in ... }`, which relies on `Identifiable.id`.
- `List(selection:)` with `.tag(topic.id as String?)`.
- Animations are keyed off `selectedTopicId`, not the whole view model.

So adding `projectPath` should not directly perturb the existing list diffing or selection behavior. However, `TopicViewModel` currently has synthesized `Hashable`; adding a stored property silently changes equality/hash semantics. Kieran's identity-only `Hashable` requirement is valid and should stay in the spec.

#### WARNING-2: Reconstructing `Topic` in `MessageViewModel.sendMessage()` should not disturb message rendering, but do not change local message insertion order

`MessageViewModel.sendMessage()` inserts the user's local message before calling `bridge.sendMessage`. `MessageCanvas` renders database-observed `messages` by `Message.id`, while topic scrolling is keyed by `topicId`, not the reconstructed `Topic`. The spec's reconstruction change should not directly affect scroll bounce as long as it only changes the `topic` parameter passed to the bridge.

**Guardrail:** keep the local user-message insert before the bridge call. If file reads happen before local insertion, a slow project read would make the composer appear to eat input before the message appears.

#### WARNING-3: Context injection needs a small visible status, not a large new panel in Phase 1

The spec rejects a full Project Context Panel for Phase 1, which I agree with. The app already has a dense chat surface and a sidebar. But there should be a subtle, inspectable state so Adam can tell whether project context is active.

Recommended Phase 1 UI:

- Add a small folder/context indicator to `SessionRow` for project-bound topics, with tooltip/accessibility text such as "Project context linked: BeeChat-v5".
- During the first send after binding/requeue, show a compact transient status near the existing reset indicator: "Adding project context..." then "Project context added".
- If injection fails or files are missing, show a non-blocking warning state: "Project context unavailable" with the reason in tooltip/details.

Avoid dumping context into the chat transcript. It would shift message layout and risk reintroducing perceived scroll jump.

#### WARNING-4: EditTopicSheet should expose file inclusion status, not raw full previews

The user should not need to guess what binding a project means. `EditTopicSheet` currently shows only the bound folder name. With this spec, that binding has a much stronger consequence: BeeChat will inject project files into agent context.

Recommended sheet additions:

- Show a compact "Context files" section after a project is selected.
- List `STATUS.md`, `README.md`, `decisions.md`, `corrections.md` with found/missing/truncated status and approximate size.
- Include a "Preview" disclosure for a short capped preview, not an always-visible full text dump.
- Make missing required `STATUS.md` visible before Save if it materially weakens context.

This keeps the UX transparent without turning the edit sheet into a document viewer.

#### WARNING-5: The provider protocol should return structured metadata for UI and tests

`ProjectFileProvider.readContextFiles(projectPath:) -> String` is too thin for frontend needs. The UI needs to know whether context was read, skipped, truncated, missing, or unavailable on this device.

Prefer:

```swift
struct ProjectContextReadResult {
    var text: String
    var files: [ProjectContextFileStatus]
    var totalBytes: Int
    var truncated: Bool
    var unavailableReason: String?
}
```

This also makes the EditTopicSheet and status indicator testable without parsing prompt text.

#### WARNING-6: Synchronous actor I/O may not freeze SwiftUI, but it can delay perceived send start

Because `sendMessage` is async and the local message is inserted first, the main UI should keep rendering. Still, `SyncBridge` is an actor; synchronous file reads block other bridge work while they run. If the selected project is on a slow disk, the user may see the local message appear but no thinking/streaming state for longer than expected.

Mitigation: keep the 16KB cap, read only fixed filenames, and emit a bridge/UI event when context injection starts if reads become noticeable. If preview/status is added, use cached metadata rather than rereading files in UI.

### ℹ️ Observation

#### OBSERVATION-1: MessageCanvas scroll bounce should not regress from the proposed data-flow fix alone

`MessageCanvas` scroll behavior depends on `messages`, `isStreaming`, `streamingContent`, and `topicId`. The spec changes the hidden prompt sent to the gateway, not the local rendered `Message` content. The injected context is stored in delivery ledger/effective send text, not inserted as a visible message. That should not create extra rows, resize visible bubbles, or trip the topic-switch scroll handler.

The main regression risk is indirect: larger first prompts could delay the first assistant stream, making the thinking indicator sit longer. That is a perceived responsiveness issue, not the previous scroll bounce mechanism.

#### OBSERVATION-2: A sidebar project indicator would also help diagnose the original bug

If a project-bound topic has a folder glyph/status in `SessionRow`, QA can immediately verify whether metadata survived the `Topic -> TopicViewModel` hop. It is a low-cost visual check for the exact class of regression this spec fixes.

#### OBSERVATION-3: Kieran's security findings have UX implications

Kieran's path validation and symlink findings are not only backend concerns. If a project binding later gets rejected at send time, the UI must not silently behave as normal. A rejected path should surface as "Project context not added" somewhere lightweight, otherwise users will blame agent quality rather than the binding state.

---

## Answers To Requested Checks

1. **TopicViewModel equality/reactivity:** current views do not appear to depend on whole-`TopicViewModel` equality for animations, transitions, or list identity. Keep explicit identity-only `Hashable` anyway.

2. **MessageViewModel reconstruction and scroll:** safe if reconstruction only affects the hidden `topic` parameter and local message insertion remains before bridge send. No direct `MessageCanvas` bounce regression expected.

3. **ProjectFileProvider UI implications:** the protocol must provide structured status/capability, especially for iOS and failure/truncation states. A raw string is insufficient for UX.

4. **EditTopicSheet UX:** yes, the user should see which files will be injected. Use file status and a capped preview disclosure, not a full always-visible context preview.

5. **Sidebar performance:** safe only if file reads stay out of `TopicViewModel`, `SessionRow`, and topic observation. Add that as an implementation constraint.

6. **User-visible injection:** show subtle status/indicator for linked, injecting, added, unavailable, and truncated context. Do not inject visible prompt text into the chat transcript.

---

## Verdict

⚠️ **APPROVE-WITH-CHANGES**

The root fix is sound from a UI architecture standpoint: pass project metadata through the view model, reconstruct the `Topic` with metadata intact, and keep prompt injection out of the rendered message list. Before implementation, the spec needs a precise cross-platform capability model, explicit "no file reads in SwiftUI/list paths" guidance, and a small UX surface for project context status and file inclusion visibility.
