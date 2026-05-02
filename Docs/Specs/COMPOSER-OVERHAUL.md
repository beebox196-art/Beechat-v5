# Composer Overhaul: ChatField Input Replacement

**Priority:** Medium  
**Status:** Spec — updated with Kieran review findings  
**Author:** Bee (Coordinator), Kieran (Reviewer)  
**Date:** 2026-05-02

## Problem

The current chat input uses a 205-line AppKit bridge (`MacTextView.swift`) wrapping `NSTextView`. This causes:

1. **Wrong keyboard convention:** Cmd+Enter sends, plain Enter inserts a newline. Every macOS chat app (Telegram, Slack, Discord, iMessage) uses Enter to send and Shift+Enter for newlines. This is the #1 UX complaint.
2. **Shift+Enter not handled:** No way to insert a newline while also having Enter send. The two behaviours are mutually exclusive in the current implementation.
3. **AppKit complexity:** 205 lines of NSTextView/NSScrollView/ComposerContainer plumbing for something SwiftUI can do natively since macOS 14 (Sonoma).
4. **Fragile height calculation:** Manual `layoutManager.usedRect()` calls and intrinsic content size overrides.

## Solution

Replace the `MacTextView` NSViewRepresentable with a native SwiftUI `TextField(text:axis:.vertical)`. This gives us correct Enter/Shift+Enter behaviour for free, eliminates the AppKit bridge, and reduces code by ~200 lines.

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
| Keyboard | Input | Enter → send, Shift+Enter → newline |
| Theme | Visual | ThemeManager colours, radius, fonts |

## Proposed Architecture

```
Composer.swift — SwiftUI shell (modified)
  └── Native SwiftUI TextField(text:axis:.vertical) — replaces MacTextView
  └── ComposerViewModel.swift (unchanged)

DELETED: MacTextView.swift (205 lines)
```

## Implementation

### Add ChatField SPM dependency

Add to `Package.swift`:
```swift
.package(url: "https://github.com/kevinhermawan/ChatField", from: "2.0.0")
// And to the target:
.product(name: "ChatField", package: "ChatField")
```

### Composer.swift Changes

Replace the `MacTextView` usage with ChatField:

```swift
import ChatField

// BEFORE:
MacTextView(
    text: $viewModel.inputText,
    onSend: {
        if viewModel.canSend {
            onSend()
        }
    }
)
.frame(maxWidth: .infinity)
.frame(minHeight: 36, maxHeight: 160)
.fixedSize(horizontal: false, vertical: true)
.background(themeManager.color(.bgPanel))
.clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous))

// AFTER:
ChatField("Type a message...", text: $viewModel.inputText) {
    if viewModel.canSend {
        onSend()
    }
}
.chatFieldStyle(.roundedBorder)
.frame(maxWidth: .infinity)
.fixedSize(horizontal: false, vertical: true)
.background(themeManager.color(.bgPanel))
.clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous))
```

### MacTextView.swift

**Delete entirely.** No replacement file needed.

### ComposerViewModel.swift

**No changes.** The ViewModel holds `inputText`, `canSend`, `send()`, and `onMessageSent`. All remain the same.

### MainWindow.swift

**No changes.** The Composer view interface (`viewModel:onSend:`) is unchanged.

## Keyboard Behaviour — CRITICAL UPDATE

**The original spec assumption was wrong.** Native `TextField(axis: .vertical)` with `.onSubmit` does NOT give us Shift+Enter for newlines on macOS.

| Key | Actual macOS behaviour | Original spec claimed |
|-----|----------------------|---------------------|
| Enter | Fires `.onSubmit` ✅ | Fires `.onSubmit` ✅ |
| Shift+Enter | **Also fires `.onSubmit`** ❌ | Inserts newline ❌ |

**Shift+Enter fires `.onSubmit` too** — there is no built-in SwiftUI mechanism to distinguish plain Enter from Shift+Enter in `.onSubmit`. The chat app convention (Enter=send, Shift+Enter=newline) requires custom key handling.

### Revised approach: `.onKeyPress` with cursor-safe insertion

We use `.onKeyPress(.return)` (available macOS 13.3+) to intercept Enter/Shift+Enter and handle them differently:

```swift
TextField("Type a message...", text: $viewModel.inputText, axis: .vertical)
    .lineLimit(1...6)
    .onKeyPress(.return) { press in
        if press.modifiers.contains(.shift) {
            // Insert newline at cursor position using NSTextView
            // (can't just append — that puts it at the end)
            return .ignored  // Let the default newline insertion happen
        } else {
            onSend()
            return .handled  // Consume the Enter keypress
        }
    }
```

**BUT** — `.onKeyPress` returning `.ignored` for Shift+Enter on a vertical TextField does NOT automatically insert a newline. The TextField's default behaviour on Enter is `.onSubmit`, not newline insertion. So we need a hybrid approach.

### Final approach: ChatField (primary)

Given the complexity of getting Enter/Shift+Enter right with native SwiftUI, **ChatField** becomes the primary approach. It's purpose-built for this exact use case:

- Explicit macOS keyboard handling (Enter → send, Shift+Enter → newline)
- Cursor-position-aware newline insertion
- Auto-expanding height
- One SPM dependency (SwiftUIIntrospect)
- v2.0.0, actively maintained

```swift
// Replace MacTextView in Composer.swift with:
import ChatField

ChatField("Type a message...", text: $viewModel.inputText) {
    if viewModel.canSend {
        onSend()
    }
}
.chatFieldStyle(.roundedBorder)
.frame(maxWidth: .infinity)
.fixedSize(horizontal: false, vertical: true)
```

### Native SwiftUI (fallback only)

If ChatField causes integration issues, the native approach requires a **custom NSViewRepresentable wrapper** (similar to current MacTextView but with correct key handling). This is essentially what ChatField does internally — so we'd be reinventing it. Not recommended.

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| ChatField dependency breaks or is abandoned | Low | ChatField v2.0.0 is stable. If it breaks, revert to MacTextView via git revert. |
| SwiftUIIntrospect conflicts with existing packages | Low | Single lightweight dependency, well-maintained. |
| ChatField styling doesn't match theme tokens | Medium | ChatField supports `.chatFieldStyle()` and standard SwiftUI modifiers. May need custom style. |
| Enter sends but cursor-position-aware newline fails | Very Low | ChatField handles this explicitly for macOS — it's their core feature. |
| Text doesn't auto-expand correctly | Very Low | ChatField uses `TextField(axis: .vertical).lineLimit()` internally — proven pattern. |
| Focus ring / accessibility regression | Low | ChatField uses native TextField, accessibility labels preserved. |
| Placeholder colour contrast | Low | Standard SwiftUI placeholder styling. |

## Rollback Plan

The change is a single-file edit in Composer.swift + deleting MacTextView.swift. To rollback:

1. `git revert` the commit
2. Re-add `MacTextView.swift`
3. Revert Composer.swift to use `MacTextView`

Total: 2 files, fully reversible.

## Fallback

If ChatField causes integration issues (SPM conflicts, styling mismatches, macOS version problems), we have two fallback options:

1. **Native SwiftUI TextField + `.onKeyPress` custom handler** — Requires wrapping to handle Shift+Enter at cursor position. Essentially reinventing what ChatField does. Higher risk, more code.
2. **Keep current MacTextView with key handling fix** — Fix the Cmd+Enter → Enter send logic in the existing `ComposerTextView.keyDown()` method. Minimal change but retains 205 lines of AppKit bridge code.

**Recommendation:** ChatField first. If it fails, option 2 (fix current MacTextView key handling) is the safest fallback.

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
11. ✅ Theme colours and radius match existing style
12. ✅ Attachment button (+) still visible and functional
13. ✅ Mic button still visible and functional
14. ✅ No regression in message scrolling behaviour
15. ✅ Option+Return also inserts newline (macOS convention)
16. ✅ Focus ring appearance matches or improves on current AppKit version
17. ✅ ChatField package resolves and builds without conflicts
18. ✅ Deleting MacTextView.swift doesn't break any other file

## Out of Scope

- Rich text / markdown input (future consideration)
- Message editing / reply quoting
- Voice input improvements (Phase 2 of voice roadmap)
- ViewModel refactoring (SyncBridge coupling is separate concern)
- Any changes to MessageCanvas, message bubbles, or sidebar

## Pre-Build Checklist

- [ ] Spec approved by Adam
- [ ] Native TextField `.onSubmit` tested: does it fire on Shift+Enter? (If yes, need custom wrapper)
- [ ] Native TextField auto-expand tested: does `.lineLimit(1...6)` match current 36px–160px range?
- [ ] Kieran sign-off on risk assessment
- [ ] Current `v5-stable-2026-05-02` tag confirmed as rollback point