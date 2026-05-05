# Composer Overhaul: ChatField Input Replacement

**Priority:** Medium  
**Status:** Spec — updated with Bee review findings (2026-05-05)  
**Author:** Bee (Coordinator), Kieran (Reviewer)  
**Date:** 2026-05-02 (updated 2026-05-05)

## Problem

The current chat input uses a 205-line AppKit bridge (`MacTextView.swift`) wrapping `NSTextView`. This causes:

1. **Wrong keyboard convention:** Cmd+Enter sends, plain Enter inserts a newline. Every macOS chat app (Telegram, Slack, Discord, iMessage) uses Enter to send and Shift+Enter for newlines. This is the #1 UX complaint.
2. **Shift+Enter not handled:** No way to insert a newline while also having Enter send. The two behaviours are mutually exclusive in the current implementation.
3. **AppKit complexity:** 205 lines of NSTextView/NSScrollView/ComposerContainer plumbing for something SwiftUI can do natively since macOS 14 (Sonoma).
4. **Fragile height calculation:** Manual `layoutManager.usedRect()` calls and intrinsic content size overrides.

## Safety Net: MacTextView Key Fix (ALREADY APPLIED)

Before the ChatField replacement, we've fixed the current MacTextView as a safety net. This is committed and builds:

```swift
// BEFORE (broken convention — Cmd+Enter sends):
if event.modifierFlags.contains(.command) {
    onSend?()
    return
}

// AFTER (correct convention — Enter sends, Shift+Enter = newline):
if !event.modifierFlags.contains(.shift) {
    onSend?()
    return
}
// Shift+Return falls through to super.keyDown → inserts newline
```

This 1-line fix gives us correct Enter/Shift+Enter behaviour in the existing AppKit bridge right now. If ChatField replacement has any issues, we can roll back to this.

## Current Architecture

```
Composer.swift (93 lines) — SwiftUI shell
  └── MacTextView.swift (205 lines) — NSViewRepresentable + NSTextView + NSScrollView + ComposerContainer
  └── ComposerViewModel.swift (44 lines) — state + send logic

MainWindow.swift references:
  - @State composerViewModel
  - Composer(viewModel:onSend:)
  - composerViewModel.configure(syncBridge:messageViewModel:)
  - composerViewModel.onMessageSent callback
```

**Interface contract** (what any replacement must provide):

| Contract | Type | Notes |
|---|---|---|
| Text binding | `@Binding var text: String` | Two-way binding to ComposerViewModel.inputText |
| Send callback | `onSend: () -> Void` | Triggered on Enter (NOT Cmd+Enter) |
| Auto-expand | Layout | 36px min height, ~160px max (~6 lines), grows with content |
| Placeholder | Visual | "Type a message..." |
| Keyboard | Input | Enter → send, Shift+Enter → newline, Option+Return → newline |
| Theme | Visual | ThemeManager colours, radius, fonts |
| Focus | State | Keyboard focus stays in input after sending |

## Proposed Architecture

```
Composer.swift — SwiftUI shell (restructured)
  └── ChatField (replaces MacTextView + flat HStack)
       ├── leadingAccessory: + button
       ├── BaseTextField (ChatField internal — native SwiftUI TextField)
       └── trailingAccessory: mic button + send button
  └── ComposerViewModel.swift (unchanged)

DELETED: MacTextView.swift (205 lines)
```

## Implementation

### Add ChatField SPM dependency

Add to `Package.swift`:
```swift
.package(url: "https://github.com/kevinhermawan/ChatField", from: "3.0.4")
// And to the BeeChatApp target:
.product(name: "ChatField", package: "ChatField")
```

**Note:** Spec previously said `from: "2.0.0"` — that's wrong. Latest is v3.0.4 and the API changed between v2 and v3. Always use v3.0.4+.

### ChatField Verified Behaviour

From source analysis of ChatField v3.0.4 (`BaseTextField.swift`, macOS branch):

```swift
// ChatField's macOS key handling — verified in source:
private func macOS_action() {
    if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
        text.appendNewLine()  // Shift+Enter → newline at cursor
    } else {
        action()              // Enter → send
    }
}
```

- Uses `SwiftUIIntrospect` to intercept Enter at NSTextView level
- Checks `NSApp.currentEvent?.modifierFlags` for `.shift`
- `text.appendNewLine()` — custom String extension, appends newline
- Platform: macOS 13+ (we target macOS 14 ✅)
- Depends on: `SwiftUIIntrospect` 1.3.0+ (no conflicts with our GRDB 7.0.0)

### Custom Theme Style — BeeChatChatFieldStyle

**CRITICAL:** ChatField's built-in `.chatFieldStyle(.roundedBorder)` gives system-default styling, NOT our dark theme. We must create a custom style.

ChatField v3 has a `Styles/` directory with style protocol. We need to define:

```swift
import ChatField

struct BeeChatChatFieldStyle: ChatFieldStyle {
    // Map ThemeManager tokens to ChatField style properties
    // Exact protocol requirements TBD — inspect ChatFieldStyle protocol 
    // after SPM resolve to see what properties are configurable
    //
    // Key tokens to map:
    //   bgPanel       → text field background
    //   accentPrimary → send button colour
    //   textPrimary    → input text colour
    //   textSecondary  → placeholder colour
    //   radius(.md)    → corner radius
}
```

**Build step 1:** After adding ChatField to Package.swift, resolve packages, then inspect `ChatFieldStyle` protocol to determine exact requirements. Write `BeeChatChatFieldStyle` to match.

### Composer.swift Changes — Restructured Layout

The current Composer uses a flat HStack. ChatField has built-in `leadingAccessory`/`trailingAccessory` slots. We restructure to use them:

```swift
import ChatField

// BEFORE (flat HStack):
HStack(alignment: .bottom, spacing: 12) {
    Button(action: { showAttachmentPicker = true }) { ... }  // +
    MacTextView(text: $viewModel.inputText, onSend: { ... })  // text field
    Button(action: toggleRecording) { ... }                   // mic
    Button(action: { onSend() }) { ... }                      // send
}

// AFTER (ChatField with accessories):
ChatField("Type a message...", text: $viewModel.inputText) {
    if viewModel.canSend {
        onSend()
    }
} leadingAccessory: {
    Button(action: { showAttachmentPicker = true }) {
        Image(systemName: "plus.circle")
            .font(themeManager.font(.display))
            .foregroundColor(themeManager.color(.textSecondary))
    }
    .buttonStyle(.borderless)
    .frame(width: 40, height: 40)
    .confirmationDialog("Attach", isPresented: $showAttachmentPicker) {
        Button("Photo") { /* Phase 4B */ }
        Button("File") { /* Phase 4B */ }
        Button("Voice Note") { viewModel.startRecording() }
    }
    .accessibilityLabel("Attach file")
} trailingAccessory: {
    HStack(spacing: 8) {
        Button(action: toggleRecording) {
            Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                .font(themeManager.font(.heading))
                .foregroundColor(viewModel.isRecording ? themeManager.color(.error) : themeManager.color(.textSecondary))
        }
        .buttonStyle(.borderless)
        .frame(width: 40, height: 40)
        .background(
            Circle()
                .fill(viewModel.isRecording ? themeManager.color(.error).opacity(0.1) : Color.clear)
        )
        .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Start recording")

        Button(action: { onSend() }) {
            Image(systemName: "paperplane.fill")
                .font(themeManager.font(.heading))
                .foregroundColor(
                    viewModel.canSend
                        ? themeManager.color(.textOnAccent)
                        : themeManager.color(.textSecondary)
                )
        }
        .buttonStyle(.borderless)
        .frame(width: 40, height: 40)
        .background(
            Circle()
                .fill(
                    viewModel.canSend
                        ? themeManager.color(.accentPrimary)
                        : themeManager.color(.bgPanel)
                )
        )
        .disabled(!viewModel.canSend)
        .help("Send message")
        .accessibilityLabel("Send message")
    }
}
.chatFieldStyle(BeeChatChatFieldStyle())  // Custom theme — NOT .roundedBorder
.frame(maxWidth: .infinity)
.fixedSize(horizontal: false, vertical: true)
```

**Key difference from original spec:** Buttons move INTO ChatField's accessory slots instead of staying in the outer HStack. This is a structural change, not a drop-in replacement.

### Focus Management — @FocusState

After sending, the text field must keep keyboard focus. Add to Composer:

```swift
@FocusState private var isTextFieldFocused: Bool

// In body, apply to ChatField:
ChatField("Type a message...", text: $viewModel.inputText) { ... }
    .focused($isTextFieldFocused)

// In onSend callback:
if viewModel.canSend {
    onSend()
    isTextFieldFocused = true  // Re-focus after send
}
```

### Option+Return Handling

ChatField v3.0.4 does NOT handle Option+Return (it only checks for `.shift`). We need to add this. Two options:

**Option A (preferred):** Check if ChatField's macOS action can be overridden or if we can add a `.onKeyPress` modifier to the ChatField view that fires before ChatField's internal handler. Test this during build.

**Option B (fallback):** If ChatField's handler consumes the event before our modifier, we may need to fork/extend ChatField's `BaseTextField`. This is a small change — just add `.option` to the modifier check alongside `.shift`.

**Build step:** After ChatField is integrated, test Option+Return. If it doesn't insert a newline, add a local extension or wrapper.

### Height Behaviour — Needs Verification

ChatField's `BaseTextField` uses `TextField(axis: .vertical).lineLimit(5)`. Our current MacTextView uses 36px min, 160px max (~6 lines). 

**Verification needed:** After ChatField is integrated, test whether `.frame(minHeight: 36, maxHeight: 160)` on the outer `ChatField` view correctly constrains the inner `TextField`. ChatField manages its own height via `lineLimit`, so the frame modifiers may or may not take effect as expected.

If the outer frame doesn't constrain properly, we may need to adjust ChatField's `lineLimit` (from 5 to 6) or accept ChatField's default expansion behaviour.

### MacTextView.swift

**Delete entirely.** No replacement file needed.

**Verified:** `MacTextView`, `ComposerContainer`, and `ComposerTextView` are only referenced in:
- `MacTextView.swift` (definitions)
- `Composer.swift` (line 29, single usage)

No other file imports or references these types. Safe to delete.

### ComposerViewModel.swift

**No changes.** The ViewModel holds `inputText`, `canSend`, `send()`, and `onMessageSent`. All remain the same. ChatField's `action` closure maps directly to our `onSend`.

### MainWindow.swift

**No changes.** The Composer view interface (`viewModel:onSend:`) is unchanged.

## Keyboard Behaviour — Reference

| Key combo | Behaviour | Handled by |
|-----------|-----------|------------|
| Enter | Send message | ChatField internal (macOS `macOS_action`) |
| Shift+Enter | Insert newline | ChatField internal (`text.appendNewLine()`) |
| Option+Return | Insert newline | ⚠️ Needs local fix (ChatField doesn't handle) |
| Cmd+Enter | No action | Passes through (not intercepted) |
| Ctrl+Enter | No action | Passes through (not intercepted) |
| CJK IME confirm | Insert character | System default (ChatField uses native TextField) |

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| ChatField v3.0.4 API differs from spec examples | Low | Verified source for v3.0.4 — `leadingAccessory`/`trailingAccessory` confirmed |
| SwiftUIIntrospect conflicts | Low | No existing SwiftUIIntrospect dependency. GRDB is separate. |
| Custom theme style doesn't match | Medium | Must inspect `ChatFieldStyle` protocol after SPM resolve. May need iteration. |
| Focus lost after send | Medium | `@FocusState` mitigation defined above. Must test. |
| Option+Return doesn't insert newline | Medium | Local wrapper/extension defined above. Must test. |
| Height doesn't match 36–160px range | Low | ChatField uses `lineLimit(5)`, test `.frame()` constraints. May need adjustment. |
| Accessory buttons layout regression | Low | Move into ChatField accessory slots — explicit layout, not implicit. |
| ChatField abandoned | Very Low | Safety net: MacTextView key fix already committed. `git revert` back to it. |

## Rollback Plan

Two levels of rollback:

1. **ChatField fails:** `git revert` the ChatField commit. MacTextView with key fix (already committed) remains as the working fallback.
2. **Total failure:** `git revert` both commits. Original Cmd+Enter behaviour restored (but we know how to fix it in 1 line).

Total: 2–3 files, fully reversible at each stage.

## Fallback

If ChatField causes integration issues (SPM conflicts, styling mismatches, macOS version problems), we have two fallback options:

1. **Keep current MacTextView with key handling fix** — Already applied. Enter sends, Shift+Enter inserts newline. 205 lines of AppKit remain but it works. This is the safest fallback.
2. **Native SwiftUI TextField + custom key handling** — Requires wrapping to handle Shift+Enter at cursor position. Essentially reinventing what ChatField does. Not recommended unless ChatField is truly broken.

**Recommendation:** ChatField first. Safety net (MacTextView fix) already in place. If ChatField fails, we already have a working fallback committed.

## Validation Criteria

Before committing, verify ALL of the following:

1. ✅ `swift build` passes
2. ✅ `swift test` passes (70 tests, 0 failures)
3. ✅ Enter key sends the message
4. ✅ Shift+Enter inserts a newline at cursor position (not at end of text)
5. ✅ Text field auto-expands from 1 line to ~6 lines
6. ✅ Text scrolls when content exceeds max height (no invisible truncation)
7. ✅ Placeholder text "Type a message..." appears when empty
8. ✅ Send button still works (clicking paperplane)
9. ✅ Thinking bee indicator still fires on send
10. ✅ Message still appears in conversation after send
11. ✅ Theme colours and radius match existing style (via BeeChatChatFieldStyle, NOT .roundedBorder)
12. ✅ Attachment button (+) still visible and functional (now in leadingAccessory)
13. ✅ Mic button still visible and functional (now in trailingAccessory)
14. ✅ No regression in message scrolling behaviour
15. ✅ Option+Return inserts newline (test after integration, add local fix if needed)
16. ✅ Focus ring appearance matches or improves on current AppKit version
17. ✅ ChatField package resolves and builds without conflicts
18. ✅ Deleting MacTextView.swift doesn't break any other file
19. ✅ Keyboard focus stays in text field after sending a message (@FocusState)
20. ✅ CJK input method works (test with Japanese/Chinese keyboard)

## Out of Scope

- Rich text / markdown input (future consideration)
- Message editing / reply quoting
- Voice input improvements (Phase 2 of voice roadmap)
- ViewModel refactoring (SyncBridge coupling is separate concern)
- Any changes to MessageCanvas, message bubbles, or sidebar

## Pre-Build Checklist

- [x] MacTextView key fix committed as safety net (Enter=send, Shift+Enter=newline)
- [x] ChatField v3.0.4 source verified — Enter/Shift+Enter handling confirmed
- [x] MacTextView references verified — safe to delete (only in Composer.swift)
- [ ] Spec approved by Adam
- [ ] Add ChatField to Package.swift, resolve, inspect `ChatFieldStyle` protocol
- [ ] Write `BeeChatChatFieldStyle` mapping ThemeManager tokens
- [ ] Test Option+Return behaviour, add local fix if needed
- [ ] Test focus persistence after send
- [ ] Test height behaviour (.frame constraints vs ChatField lineLimit)
- [ ] Current `v5-stable-2026-05-05` tag confirmed as rollback point