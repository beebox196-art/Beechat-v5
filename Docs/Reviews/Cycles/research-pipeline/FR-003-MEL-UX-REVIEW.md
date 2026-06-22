# FR-003 UX Review — Research Panel

**Reviewer:** Mel (UI/UX specialist)
**Date:** 2025-06-28
**Spec:** FR-003-RESEARCH-PIPELINE.md
**Scope:** BeeChat research panel UI — the Swift-side entry point for the research pipeline

---

## 1. Panel Design: Sheet Over the Chat Area

**Recommendation: Sheet (`.sheet`) presented from the detail area, not the sidebar.**

### Why not the alternatives

| Option | Problem |
|---|---|
| Slide-out from sidebar | Sidebar is already 180–320px wide and packed (topic list, action buttons, health dots, unread badges, project icons, reset dots). Adding a research panel there means either (a) the text field is unusably narrow, or (b) it pushes the sidebar to an awkward width. Research needs a multi-line text field — that wants width. |
| Replace chat area temporarily | Violates user expectation. The chat is the primary surface. Replacing it with a form breaks the "I'm still in my conversation" mental model. If the user has a half-read streaming response they'd lose visual context. |
| Inline composer expansion | The Composer uses `ChatField` with a 160px max height and `leadingAccessory`/`trailingAccessory` buttons already (attach, mic, send). Stacking a depth selector + tags field on top of that makes the composer area too heavy. The composer is for freeform chat; research is a distinct action. Confusing the two increases cognitive load. |

### Why a sheet works

- **BeeChat already uses sheets extensively.** `ThemePicker`, `FolderPicker`, `AgentActivityPanel`, `BeeBoardSheet`, `EditTopicSheet`, and `NewTopicDialog` are all sheets. The pattern is established and familiar.
- **Width:** A sheet can be 460–520px wide — plenty for a multi-line text field and three depth buttons.
- **Context:** The user clicked a button in the sidebar toolbar (or used a keyboard shortcut) while looking at their topic. The sheet overlays the chat but doesn't destroy it. When the sheet closes, they're back in the conversation.
- **Focus management:** `@FocusState` on the text field auto-focuses on appear (same pattern as `isNewTopicFieldFocused` in `MainWindow`). One less click.
- **Dismissal:** `Cmd+W` or Escape closes the sheet. Done button in top-right. Standard macOS.

### Sheet structure

```
┌─────────────────────────────────────────────────┐
│  🔍 Research                          [Done]  │
│─────────────────────────────────────────────────│
│                                                 │
│  ┌─────────────────────────────────────────┐   │
│  │ Paste a link, topic, or idea...        │   │
│  │                                         │   │
│  │                                         │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
│  Depth:                                         │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐       │
│  │ ⚡ Quick  │ │ Standard │ │ 🔬 Deep  │       │
│  └──────────┘ └──────────┘ └──────────┘       │
│                                                 │
│  Tags (optional):                               │
│  ┌─────────────────────────────────────────┐   │
│  │ topcon, competitor                       │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
│  ┌─────────────────────────────────────────┐   │
│  │              Start Research ▶            │   │
│  └─────────────────────────────────────────┘   │
│                                                 │
└─────────────────────────────────────────────────┘
```

### Trigger

Add a button to the **sidebar toolbar row** (the `HStack` at the bottom of the sidebar, alongside `plus.circle`, `folder.badge.plus`, `person.3`, etc.):

```swift
Button(action: { showResearchPanel = true }) {
    Image(systemName: "magnifyingglass")
        .font(themeManager.font(.body))
        .foregroundColor(themeManager.color(.textSecondary))
}
.buttonStyle(.plain)
.help("Research")
.accessibilityLabel("Research")
.accessibilityHint("Open research panel")
```

This adds exactly 1 icon to the existing toolbar. The magnifying glass is the universal macOS symbol for search/research. It's visually distinct from `plus.circle`, `folder.badge.plus`, `person.3`, `pin.square`, and `paintpalette` already present.

### Keyboard shortcut

`Cmd+Shift+R` to open the research panel. `Cmd+R` is already common for "Run" in Xcode and many macOS apps; the Shift modifier avoids collision. The shortcut should be added to `MainWindow`'s keyboard handling.

---

## 2. Depth Selector: Segmented Control with Icons

**Recommendation: `Picker` with `.segmented` style, with emoji prefixes.**

### Why segmented control

- **macOS native pattern.** Segmented controls are the standard macOS pattern for 2–4 mutually exclusive options. They appear in Finder toolbar, Mail, Safari, System Preferences everywhere.
- **One tap, no dropdown.** Dropdown/picker requires click → scan → click. Segmented control requires one click. That's the difference between 4 actions total and 5 actions total. Adam's friction requirement is 4 actions max.
- **Visual at-a-glance.** The user can see which depth is selected without opening anything. The currently selected segment has a filled background. No ambiguity.
- **Default visible.** "Standard" is pre-selected (the spec's default). The user sees this immediately.

### Implementation

```swift
enum ResearchDepth: String, CaseIterable {
    case quick = "quick"
    case standard = "standard"
    case deep = "deep"

    var displayName: String {
        switch self {
        case .quick: return "⚡ Quick"
        case .standard: return "Standard"
        case .deep: return "🔬 Deep"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .quick: return "Quick Scan — 2-3 minutes, chat brief"
        case .standard: return "Standard — 8-12 minutes, HTML report"
        case .deep: return "Deep Dive — 15-25 minutes, comprehensive HTML report"
        }
    }
}

@State private var selectedDepth: ResearchDepth = .standard
```

In the view:

```swift
Picker("Depth", selection: $selectedDepth) {
    ForEach(ResearchDepth.allCases, id: \.self) { depth in
        Text(depth.displayName).tag(depth)
    }
}
.pickerStyle(.segmented)
.accessibilityLabel("Research depth")
// Custom accessibility for each segment requires an accessibility modifier
// on the Picker; VoiceOver will read the segment text.
```

### Why NOT three individual buttons

Three individual `Button` views in an `HStack` would work, but:
- They need custom selected/unselected state styling (fill, border, text colour) — more code, more inconsistency risk.
- Segmented control gives you that for free, matching macOS HIG.
- The spec says ~60 lines. A segmented `Picker` is 8 lines. Three custom buttons with state management is 25+ lines.

### Why NOT a dropdown/picker

- Two clicks instead of one.
- Hides the options. The user has to remember "what were the three depths again?"
- The whole point of the panel is to avoid having to remember things.

### Emoji prefixes rationale

- ⚡ Quick — conveys speed
- Standard — no emoji needed, this is the default, clean label
- 🔬 Deep — conveys thorough examination

The emojis serve as visual anchors so the user doesn't have to read the full label each time. They also help VoiceOver users who have "emoji descriptions" enabled.

---

## 3. Submit Flow: Send and Close, Then Stream in Chat

**Recommendation: Sheet closes on submit. Research output appears as messages in the current topic.**

### The flow

1. User clicks **Start Research** (or presses `Cmd+Return` / `Return` when the text field is focused — see keyboard shortcuts below).
2. The panel constructs the `/research` payload string: `/research --depth standard "topic text" --tags tag1,tag2`
3. The panel sends this through the existing `SyncBridge.sendMessage()` — exactly like typing the slash command manually.
4. The sheet dismisses automatically.
5. The user is back in their current topic.
6. The ThinkingBee indicator appears (`.thinking` state), then transitions to `.streaming` when the pipeline starts returning content.
7. Research output appears as chat messages in the current topic — same as any other response.

### Why not keep the panel open for progress

- Research takes 2–25 minutes. Keeping a sheet open that long is hostile. macOS sheets are modal — they block interaction with the main window. The user can't scroll chat, switch topics, or do anything else.
- The progress indication should be **in the chat**, not in the panel. The ThinkingBee animation already exists. It already shows when the agent is working. The first message from the pipeline is a progress message ("Researching: [topic] — Depth: [level] — Est. [time]") which appears as a system-style message in chat.
- The panel is a form. Forms should be transient — fill in, submit, done. They are not dashboards.

### Why not create a new topic

- The spec says no shared package changes and no new message types. Creating a new topic would require `TopicRepository` interaction and session key management that's unnecessary complexity for MVP.
- The user is in their topic. They typed `/research` there. The response should appear there. If Adam wants to find it later, the research index and KB entries handle that.
- Future polish (Phase 5) can add a "Research History" view in the sidebar that reads `research-index.json`. For MVP, the chat summary + HTML link in the current topic is sufficient.

### How the progress message should look in chat

The pipeline sends a system message at the start of research. This should render as a **system bubble** — already supported by `MessageBubble.systemBubble`:

```
Researching: Topcon positioning market share — Depth: standard — Est. 8-12 min
```

Italic text, centred, `.caption` font, `textSecondary` colour. Exactly the pattern used for system messages already.

When the pipeline finishes, it sends the chat summary as an assistant message (with `agentId: "gav"` so it gets the "🔍 Gav" badge). The HTML report link is included in the message text.

### Keyboard shortcut for submit

`Cmd+Return` to submit from the research panel. This matches the macOS convention for "send/submit in a dialog with a multi-line text field" (where bare `Return` inserts a newline).

---

## 4. Visual Consistency: Matching BeeChat's Design Language

The research panel must use the same tokens, patterns, and spacing as existing components. Here's the exact mapping:

### ThemeManager tokens

| Element | Token | Reference |
|---|---|---|
| Sheet background | `bgSurface` | AgentActivityPanel, MainWindow |
| Text field background | `bgPanel` | Composer |
| Text field border | `borderSubtle` | Consistent across app |
| Primary text | `textPrimary` | Headers, labels |
| Secondary text | `textSecondary` | Hints, descriptions |
| Accent / submit button | `accentPrimary` | Composer send button, sidebar accent states |
| Selected segment | System segmented control (automatic) | macOS standard |
| Error state | `error` | Validation errors |

### Typography

| Element | Token | Size/Weight |
|---|---|---|
| "Research" title | `.heading` | 20pt semibold |
| "Depth:" label | `.subheading` | 16pt medium |
| "Tags (optional):" label | `.subheading` | 16pt medium |
| Text field content | `.body` | 14pt regular |
| Depth descriptions (if shown) | `.caption` | 12pt regular |
| Submit button text | `.subheading` | 16pt medium |

### Spacing

| Context | Token | Value |
|---|---|---|
| Horizontal padding | `.xl` | 24pt |
| Vertical section gaps | `.lg` | 16pt |
| Between label and control | `.sm` | 8pt |
| Inner text field padding | `.md` | 12pt |
| Sheet top/bottom padding | `.xl` | 24pt |

### Radius

| Element | Token | Value |
|---|---|---|
| Text field, tags field | `.md` | 8pt (matches Composer's `BeeChatChatFieldStyle`) |
| Submit button | `.md` | 8pt (matches send button's clip shape) |

### Sheet sizing

```swift
.frame(minWidth: 460, ideal: 480, minHeight: 340)
```

This matches `AgentActivityPanel`'s `minWidth: 360, minHeight: 280` but slightly wider to accommodate the segmented control comfortably.

### Header pattern

Match `AgentActivityPanel` exactly:

```swift
HStack {
    Text("Research")
        .font(themeManager.font(.heading))
        .foregroundColor(themeManager.color(.textPrimary))
    Spacer()
    Button("Done") { dismiss() }
        .font(themeManager.font(.subheading))
        .foregroundColor(themeManager.color(.accentPrimary))
}
.padding(.horizontal, themeManager.spacing(.xl))
.padding(.vertical, themeManager.spacing(.lg))

Divider()
    .background(themeManager.color(.borderSubtle))
```

### Submit button

Match the Composer's send button pattern but as a full-width button:

```swift
Button(action: submitResearch) {
    Text("Start Research")
        .font(themeManager.font(.subheading))
        .foregroundColor(themeManager.color(.textOnAccent))
        .frame(maxWidth: .infinity)
        .padding(.vertical, themeManager.spacing(.md))
        .background(
            RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
                .fill(canSubmit
                    ? themeManager.color(.accentPrimary)
                    : themeManager.color(.textSecondary).opacity(0.3))
        )
}
.disabled(!canSubmit)
.accessibilityLabel("Start research")
.accessibilityHint(canSubmit
    ? "Submit research request with selected depth"
    : "Enter a topic to enable research")
```

The disabled state uses the same pattern as Composer's send button — muted fill colour, disabled interaction.

---

## 5. Accessibility

### VoiceOver

Every element needs a label and hint:

| Element | Label | Hint |
|---|---|---|
| Open button (sidebar) | "Research" | "Open research panel" |
| Sheet title | "Research" | — |
| Text field | "Topic or link" | "Enter a topic, link, or idea to research" |
| Depth picker | "Research depth" | Each segment: "Quick Scan, 2-3 minutes" / "Standard, 8-12 minutes" / "Deep Dive, 15-25 minutes" |
| Tags field | "Tags" | "Optional comma-separated tags, for example: topcon, competitor" |
| Submit button | "Start research" | "Submit research request" (or disabled variant) |
| Done button | "Close" | "Close research panel without submitting" |

### Keyboard navigation

- **Tab order:** Text field → Depth picker → Tags field → Submit button → Done button
- **`Escape`:** Close sheet (macOS standard for sheets)
- **`Cmd+Return`:** Submit research (macOS convention for multi-line fields)
- **`Cmd+Shift+R`:** Open research panel from anywhere (global keyboard shortcut)
- **Depth picker:** Left/Right arrows switch segments (standard `Picker` behaviour)
- **Focus ring:** SwiftUI's default focus ring is sufficient — no custom ring needed

### Dynamic type

The text field and tags field should respect Dynamic Type. The `.body` and `.subheading` tokens scale appropriately. The segmented control uses system sizing by default. No fixed heights — use `.fixedSize(horizontal: false, vertical: true)` on the text field, same as Composer.

### Reduced motion

The sheet presentation and dismissal should respect `UIAccessibility.isReduceMotionEnabled`. SwiftUI handles this automatically for standard `.sheet` transitions. No custom animations needed.

### High contrast

All colour tokens already have sufficient contrast in all themes. The segmented control uses system rendering which adapts to high-contrast mode. The submit button's disabled state uses `textSecondary.opacity(0.3)` which may need adjustment for high-contrast — use `@Environment(\.colorSchemeContrast)` to increase opacity in high-contrast mode:

```swift
@Environment(\.colorSchemeContrast) var colorSchemeContrast

var disabledFillOpacity: Double {
    colorSchemeContrast == .increased ? 0.5 : 0.3
}
```

---

## 6. Friction Analysis: 4 Actions, No Syntax

Adam's requirement: **4 actions maximum** from "I have a topic" to "research is running."

### The flow

| Step | Action | Detail |
|---|---|---|
| 1 | Open panel | Click `magnifyingglass` icon in sidebar toolbar, or `Cmd+Shift+R` |
| 2 | Paste/type topic | Text field auto-focused on sheet appear. Paste from clipboard. |
| 3 | Select depth (optional) | Standard is pre-selected. Only change if you want Quick or Deep. |
| 4 | Submit | Click "Start Research" or press `Cmd+Return` |

**If the user wants Standard depth (the default), that's 3 actions.** Step 3 is only needed for non-default depths.

### What makes this low-friction

- **Auto-focus:** `@FocusState` on the text field means the cursor is ready immediately. No clicking into the field.
- **Paste-ready:** Multi-line text field. If Adam copies a URL or paragraph, one paste fills it.
- **Pre-selected default:** Standard depth is the right default for 80%+ of research. Most users skip the depth selector entirely.
- **Optional tags:** The tags field is clearly labelled "(optional)" and sits below the fold visually. It doesn't interrupt the main flow.
- **No confirmation dialog:** Submit sends immediately. The pipeline handles errors gracefully (dead links, no results). A confirmation step would be a 5th action.

### Comparison with slash command

| Approach | Actions | Syntax required |
|---|---|---|
| Research panel (default depth) | 3 (open, paste, submit) | No |
| Research panel (non-default) | 4 (open, paste, select depth, submit) | No |
| Slash command | 1 (type + enter) | Yes — must remember `/research --depth deep "topic"` |

The panel wins for anyone who doesn't have the syntax memorised. The slash command wins for power users who do. Both produce the same payload. This is exactly right.

---

## 7. Progress Indication: In Chat, Not in the Panel

### The problem

Research takes 2–25 minutes. The user needs to know:
1. That the research started
2. That it's still running
3. When it's done

### The solution (using existing UI)

| Signal | Where | How |
|---|---|---|
| Research started | Chat (system bubble) | Pipeline sends: *"Researching: [topic] — Depth: [level] — Est. [time]"* |
| Research in progress | ThinkingBee indicator | The existing `.thinking` → `.streaming` animation already shows this |
| Research complete | Chat (assistant message) | Gav's summary message appears with "🔍 Gav" badge |
| HTML report available | Chat (in the summary message) | The message includes: *"📄 Full report: [filename.html](file:///path/)"* — clickable link to desktop file |

### No additional UI needed for MVP

- No progress bar in the panel (the panel is closed by then).
- No spinner in the sidebar (the ThinkingBee animation + system bubble already convey "working").
- No separate "Research History" view (Phase 5 per the spec).
- No notification/badge (the unread dot on the topic already handles this when the user is in a different topic).

### Future enhancement (post-MVP)

If the pipeline could send progress updates (e.g., "Stage 2/4: Collection"), those could appear as system bubbles in the chat. But this requires a new message type or streaming metadata, which is explicitly out of scope for MVP. The ThinkingBee animation + initial system message is sufficient.

---

## 8. Integration with Chat: Current Topic, Not a New One

**Recommendation: Research output appears in the current topic.**

### Why not a new topic

| Factor | Current topic | New topic |
|---|---|---|
| Complexity | Zero — just send a message via existing bridge | Requires Topic creation, session key, topic switch |
| Shared package changes | None (spec requirement) | Would need changes to persistence |
| User expectation | "I'm researching this here" | "Where did my research go?" |
| Follow-up conversation | Natural — reply in the same topic | Have to switch back to discuss results |
| Finding later | Chat search + research index | Topic list + research index |
| Spec compliance | ✅ Matches "no shared package changes" | ❌ Would violate MVP scope |

### How the HTML report link appears

The research pipeline returns a chat summary that includes the report path. This renders as a regular assistant message in the current topic:

```
🔍 Gav

Here's what I found on "Topcon positioning market share":

• Topcon holds ~15% of the precision agriculture market
• Main competitors: Trimble, John Deere, AgJunction
• Growth driven by automation in construction and agriculture
• Market expected to reach $12B by 2028

📄 Full report: 2026-06-19-topcon-positioning.html
⏱ Research took 8 min · 11 sources · Standard depth
```

The `📄` link is a `file://` URL to `/Users/openclaw/Desktop/Research Reports/`. On macOS, clicking it opens in the default browser. No custom URL handler needed.

### What happens if no topic is selected

The research panel should only be available when a topic is selected. If `messageViewModel.selectedTopicId` is nil, the sidebar research button should be disabled (greyed out, same as the delete button disappears when no topic is selected). The button's accessibility hint should change to "Select a topic first to start research."

Alternatively, we could auto-create a new topic called "Research: [topic text]" — but that's more complexity and it's not in the spec. Disable the button when no topic is selected. Simple.

---

## 9. Spec Concerns and Recommendations

### 9.1 Tags field placement

The spec lists tags as optional. In the panel layout, tags should be **below the depth selector**, not above it. The depth selector affects the cost and time significantly; tags are a minor metadata addition. Visual hierarchy should reflect importance:

1. Text field (primary input — biggest, most prominent)
2. Depth selector (affects cost and time — second most important)
3. Tags (optional metadata — smallest, least prominent)
4. Submit button (action — full width, accent colour)

### 9.2 Tags field format

The spec says "free text, comma-separated." Use a standard `TextField` with a placeholder showing the format:

```swift
TextField("topcon, competitor, market", text: $tagsText)
    .font(themeManager.font(.body))
    .textFieldStyle(.plain)
    .padding(.horizontal, themeManager.spacing(.md))
    .padding(.vertical, themeManager.spacing(.sm))
    .background(
        RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
            .fill(themeManager.color(.bgPanel))
    )
    .overlay(
        RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
            .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
    )
```

No tokenised tag input for MVP. That's Phase 5 polish. A plain text field with comma separation is simple, works, and matches the slash command format exactly.

### 9.3 Multi-line text field

The topic field MUST be multi-line. Research topics are often URLs, multi-word concepts, or even short paragraphs. Use `TextEditor` wrapped in a styled container, or a multi-line `NSTextView` via `UIViewRepresentable`/`NSViewRepresentable` for proper macOS text handling.

**However**, `TextEditor` in SwiftUI doesn't support placeholder text natively. Use a `ZStack` overlay pattern:

```swift
ZStack(alignment: .topLeading) {
    if topicText.isEmpty {
        Text("Paste a link, topic, or idea...")
            .font(themeManager.font(.body))
            .foregroundColor(themeManager.color(.textSecondary))
            .padding(.horizontal, themeManager.spacing(.md) + 4)
            .padding(.vertical, themeManager.spacing(.sm) + 4)
            .allowsHitTesting(false)
    }
    TextEditor(text: $topicText)
        .font(themeManager.font(.body))
        .foregroundColor(themeManager.color(.textPrimary))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, themeManager.spacing(.md))
        .padding(.vertical, themeManager.spacing(.sm))
}
.frame(minHeight: 80, maxHeight: 160)
.background(
    RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
        .fill(themeManager.color(.bgPanel))
)
.overlay(
    RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
        .stroke(topicText.isEmpty
            ? themeManager.color(.borderSubtle)
            : themeManager.color(.accentPrimary),
            lineWidth: 1)
)
```

The border changes from `borderSubtle` to `accentPrimary` when the field has content, giving a subtle focus indicator that matches the Composer's visual behaviour.

### 9.4 Character limit

No character limit on the topic field. URLs can be long. Research topics can be paragraphs. If the user pastes something huge, the `maxHeight: 160` on the TextEditor provides a natural scroll boundary. The payload is sent as a WebSocket message — there's no practical size limit.

### 9.5 Sheet detent (macOS)

On macOS, sheets are typically fixed-size (no detent support like iOS). Use `.frame(minWidth: 460, ideal: 480, minHeight: 340)` on the sheet content. The `TextEditor` handles scrolling within its fixed bounds.

### 9.6 Validation

The only validation needed: **topic text must not be empty.** The submit button is disabled when `topicText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`. No other validation — depth always has a value (pre-selected), tags are optional, and the pipeline handles edge cases like short/ambiguous input.

### 9.7 Error handling in the panel

The panel itself has no error states. All errors (dead link, no results, pipeline crash) are handled server-side and returned as chat messages. The panel is a pure input form — it sends the payload and closes. If the topic text is empty, the submit button is disabled. That's the only client-side validation.

---

## 10. Implementation Notes for Q

### File structure

```
Sources/App/UI/ResearchPanel.swift    — New file (~80-100 lines, not 60 — see below)
Sources/App/UI/MainWindow.swift      — Add @State, .sheet, button (5-8 lines)
```

The spec estimates 60 lines. Realistically, with accessibility, theme tokens, and the placeholder overlay, expect 80-100 lines. That's still well within reason for a single SwiftUI view.

### State management

All state is `@State` — no `@EnvironmentObject`, no `AppState` changes, no shared package changes:

```swift
@State private var topicText: String = ""
@State private var selectedDepth: ResearchDepth = .standard
@State private var tagsText: String = ""
@FocusState private var isTopicFieldFocused: Bool
```

### Sending the message

The panel needs access to the `SyncBridge` and the current `topic` to send. Pass these as parameters or use `@Environment(AppState.self)`:

```swift
struct ResearchPanel: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(AppState.self) var appState
    @Environment(\.dismiss) private var dismiss
    let sessionKey: String
    let topic: Topic  // For context injection
    // ...
}
```

On submit:

```swift
private func submitResearch() {
    let depthFlag = "--depth \(selectedDepth.rawValue)"
    let tagsFlag = tagsText.isEmpty ? "" : " --tags \(tagsText)"
    let payload = "/research \(depthFlag) \"\(topicText)\"\(tagsFlag)"

    Task {
        guard let bridge = appState.syncBridge else { return }
        _ = try await bridge.sendMessage(
            sessionKey: sessionKey,
            text: payload,
            thinking: nil,
            topic: topic
        )
    }
    dismiss()
}
```

### MainWindow integration

Add to `MainWindow`:

```swift
@State private var showResearchPanel = false
```

In the sidebar `HStack` (after the theme picker button, before the delete button):

```swift
Button(action: { showResearchPanel = true }) {
    Image(systemName: "magnifyingglass")
        .font(themeManager.font(.body))
        .foregroundColor(themeManager.color(.textSecondary))
}
.buttonStyle(.plain)
.help("Research")
.accessibilityLabel("Research")
.accessibilityHint("Open research panel")
.disabled(messageViewModel.selectedTopicId == nil)
```

And the sheet modifier:

```swift
.sheet(isPresented: $showResearchPanel) {
    if let topicId = messageViewModel.selectedTopicId,
       let topic = messageViewModel.selectedTopic,
       let sessionKey = topic.sessionKey {
        ResearchPanel(sessionKey: sessionKey, topic: topic)
            .environment(themeManager)
            .environment(appState)
    }
}
```

### What NOT to change

- **No changes to `BeeChatSyncBridge`** — the panel sends through existing `sendMessage()`.
- **No changes to `BeeChatPersistence`** — no new models, no new tables.
- **No new message types** — the `/research` payload is a plain text message, same as any other user message.
- **No changes to `AppState`** — all state is local to `ResearchPanel`.

---

## 11. Summary of Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Panel type | Sheet (`.sheet`) | Matches existing pattern, preserves chat context, adequate width |
| Trigger | Sidebar toolbar button + `Cmd+Shift+R` | Consistent with other tools, discoverable |
| Depth selector | Segmented `Picker` | macOS standard, one-click, visual default, minimal code |
| Submit action | Close sheet, send via existing bridge | No new message types, no modal wait, uses ThinkingBee |
| Output location | Current topic (chat messages) | Simplest, no new topic creation, follow-up conversation is natural |
| Progress | System bubble + ThinkingBee indicator | Existing UI, no new components, sufficient for MVP |
| Tags field | Plain `TextField`, comma-separated | Matches slash command format, no tokeniser complexity |
| Topic field | `TextEditor` with placeholder overlay | Multi-line support, matches Composer styling |
| Validation | Topic not empty → enable submit | All other validation is server-side |
| Accessibility | Full VoiceOver labels + keyboard navigation | Matches GatewayStatusBar pattern |
| Friction | 3-4 actions (open, paste, optionally select depth, submit) | Meets Adam's "no syntax to remember" requirement |

---

## 12. Open Questions for Adam

1. **Should the research button be disabled when no topic is selected?** I recommend yes — the pipeline needs a session to send through. Alternative: auto-create a "Research" topic.

2. **Should the sheet have a "Cancel" confirmation if the user has typed text?** Standard macOS behaviour is to discard without confirmation for sheets, but research text might be effortful. I recommend no confirmation for MVP (the text isn't persisted anyway), but flag it for Phase 5.

3. **Topic field height:** I've specified `minHeight: 80, maxHeight: 160` for the TextEditor. Does that feel right, or should it be taller/shorter?

4. **Should the depth selector show estimated time inline?** E.g., "⚡ Quick · 2m" / "Standard · 10m" / "🔬 Deep · 20m". I recommend keeping it clean for the segmented control and putting estimates in the accessibility labels only. The system bubble message will contain the estimate anyway.

---

*Mel — UX review complete. Ready for Q to implement.*