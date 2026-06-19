# P2 Polish Spec

**Date:** 2026-04-23
**Author:** Bee (Coordinator)
**Builder:** Q
**Reviewer:** Kieran

## Goal
Make BeeChat v5 feel like a proper macOS app — polished, accessible, and comfortable to use daily.

## Scope (4 items)

### 1. Keyboard Shortcuts
**Current state:** Cmd+N, Cmd+←, Cmd+→ exist in menu but are stubs (TODO comments). Cmd+Delete exists but only in sidebar context.

**Required:**
| Shortcut | Action | Implementation |
|---|---|---|
| `Cmd+N` | New Topic — open the new topic dialog | Wire existing menu button to `showNewTopicDialog = true` |
| `Cmd+Delete` | Delete selected topic | Already wired via `Notification.Name.deleteSelectedTopic` — verify it works |
| `Cmd+W` | Close window | Standard macOS — should work by default with `.windowStyle(.hiddenTitleBar)` — verify |

**Implementation notes:**
- In `AppRootView.swift`, the `CommandMenu("Chat")` has stub buttons. Replace with actual actions using `@Environment` or `NotificationCenter`.
- Best approach: Use `NotificationCenter` pattern already established for delete. Create `Notification.Name.newTopic` and post from menu.
- Verify Cmd+W closes window (it should with standard WindowGroup).

### 2. Window Sizing & Positioning
**Current state:** `.defaultSize(width: 800, height: 600)` — small, doesn't remember position. **⚠️ `.windowResizability(.contentSize)` prevents free window resizing** — must be changed.

**Required:**
- Default size: `1100 x 700` (better for chat apps)
- Window must allow free resizing (not locked to content size)
- Window should remember position/size between launches
- Sidebar should have reasonable min/max width

**Implementation:**
- Change `.defaultSize(width: 1100, height: 700)` in `AppRootView.swift`
- **Replace `.windowResizability(.contentSize)` with `.windowResizability(.contentMinSize)`** — this sets minimum size but allows free resizing beyond it
- For position persistence: Use `WindowGroup` with `.defaultPosition(.center)` or store frame in UserDefaults
- Sidebar: Change `.navigationSplitViewColumnWidth(220)` to `.navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 320)` in `MainWindow.swift`

### 3. VoiceOver Accessibility
**Current state:** ThemePicker cards have VoiceOver labels. Everything else does not.

**Required — add accessibility labels to:**
| Element | Label | Hint |
|---|---|---|
| New Topic button | "New Topic" | "Create a new conversation topic" |
| Theme Picker button | "Appearance" | "Change app theme" |
| Delete Topic button | "Delete Topic" | "Remove selected topic" |
| Attachment button (plus.circle in Composer) | "Attach file" | "Add an attachment" |
| Message input field | "Message input" | "Type your message here" |
| Send button | "Send message" | "Send your message to the AI" |
| Message bubbles | "Message from [User/Assistant]" | Read content |
| Gateway status bar | "Gateway status" | `.accessibilityValue(Text(statusText))` for dynamic state reading |
| Streaming indicator | "AI is typing" | Content being generated |
| Sidebar topic rows (SessionRow) | Topic name | "Select conversation" + selected state |

**Implementation:**
- Use `.accessibilityLabel()` and `.accessibilityHint()` modifiers
- For dynamic content (gateway status, streaming), use `.accessibilityValue()`
- Message bubbles: Use `.accessibilityElement()` and `.accessibilityLabel()` on the bubble container

### 4. Startup Gateway Status Fix
**Current state:** GatewayStatusBar briefly shows "No gateway connection" on startup before handshake completes.

**Required:**
- Show a neutral "Connecting..." or "Starting..." state during initialisation
- Only show "Disconnected" after a genuine disconnect (not during startup)

**Implementation:**
- In `AppState.swift`, set initial `connectionState` to a new `.connecting` state (or handle it differently)
- Add `.connecting` to `ConnectionState` enum in Gateway package if needed
- Update `GatewayStatusBar.swift` to render the connecting state with an amber/orange indicator
- Alternative (simpler): Add a `isStartupComplete` flag to AppState. StatusBar only shows status after startup is complete. During startup, show "Initialising..."

**Recommended approach:** Add `isStartupComplete: Bool` to AppState (default false). **⚠️ Must be set AFTER `bridge.start()` completes (success or error), NOT at the same point as `isReady`.** `isReady` is set before the connection attempt — using the same point would recreate the flash problem. Set `isStartupComplete = true` at the end of the connection attempt block (both success and error paths). StatusBar checks this flag first — if false, show "Initialising..." regardless of `connectionState`.

## Acceptance Criteria
1. Cmd+N opens new topic dialog
2. Cmd+Delete deletes selected topic (with confirmation or alert on error)
3. Cmd+W closes window
4. Window launches at 1100x700 minimum
5. Sidebar width is adjustable with reasonable bounds
6. VoiceOver reads all interactive elements with appropriate labels
7. No "No gateway connection" flash on startup

## Files to Modify
- `Sources/App/AppRootView.swift` — shortcuts, window size, sidebar constraints
- `Sources/App/UI/MainWindow.swift` — accessibility labels, sidebar width
- `Sources/App/UI/Components/Composer.swift` — accessibility labels
- `Sources/App/UI/Components/GatewayStatusBar.swift` — startup state handling
- `Sources/App/UI/Components/MessageBubble.swift` — accessibility labels
- `Sources/App/UI/Components/StreamingBubble.swift` — accessibility labels

## Out of Scope
- Emoji picker
- File attachments
- Reactions
- iOS adaptation
- Any new features
- Cmd+←/→ (Next/Previous Topic) — stubs remain as TODOs, not in this phase

## Process
1. **Spec** → This document (updated with Kieran review conditions)
2. **Review** → Kieran PASS with conditions ✅ (conditions incorporated above)
3. **Build** → Q implements all 4 items
4. **Tech Validation** → Kieran reviews code
5. **UX Validation** → Bee launches app, tests visually
6. **Commit** → After all gates pass
