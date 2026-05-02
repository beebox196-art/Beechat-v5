# Composer Overhaul: Native SwiftUI Input

**Priority:** Medium  
**Status:** Spec — awaiting approval before build  
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

### Composer.swift Changes

Replace the `MacTextView` usage with native TextField:

```swift
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
TextField("Type a message...", text: $viewModel.inputText, axis: .vertical)
    .lineLimit(1...6)
    .onSubmit {
        if viewModel.canSend {
            onSend()
        }
    }
    .frame(maxWidth: .infinity)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(themeManager.color(.bgPanel))
    .clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous))
```

### MacTextView.swift

**Delete entirely.** No replacement file needed.

### ComposerViewModel.swift

**No changes.** The ViewModel holds `inputText`, `canSend`, `send()`, and `onMessageSent`. All remain the same.

### MainWindow.swift

**No changes.** The Composer view interface (`viewModel:onSend:`) is unchanged.

## Keyboard Behaviour

| Key | Current | New | Expected |
|-----|---------|-----|----------|
| Enter | Newline ❌ | Send ✅ | Send |
| Shift+Enter | Newline (same as Enter) ❌ | Newline ✅ | Newline |
| Cmd+Enter | Send ✅ | Unused | N/A |

The native `TextField(axis: .vertical)` with `.onSubmit` provides this behaviour by default on macOS 14+. Enter triggers `onSubmit`, Shift+Enter inserts a newline. No custom key handling code needed.

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| TextField doesn't auto-expand correctly | Low | `.lineLimit(1...6)` + `.fixedSize(horizontal: false, vertical: true)` handles this natively. Test on macOS 14 and 15. |
| Placeholder styling differs | Low | SwiftUI `TextField("placeholder", text:)` renders placeholder text natively. May look slightly different but still functional. |
| Focus management regression | Low | Remove AppKit `becomeFirstResponder`/`resignFirstResponder` overrides. Use SwiftUI `@FocusState` if needed. |
| Height calculation differs | Low | Native TextField uses intrinsic content size. May need `.frame(minHeight:36)` to match current min height. |
| onSubmit fires twice | Very Low | SwiftUI's `.onSubmit` for vertical TextField fires once on Enter. If it fires on Shift+Enter too, we'd need a custom wrapper. **Test this specifically.** |

## Rollback Plan

The change is a single-file edit in Composer.swift + deleting MacTextView.swift. To rollback:

1. `git revert` the commit
2. Re-add `MacTextView.swift`
3. Revert Composer.swift to use `MacTextView`

Total: 2 files, fully reversible.

## Fallback

If native `TextField(axis: .vertical)` doesn't meet our needs (e.g. fine-grained height control, text container insets, onSubmit edge cases), the next option is **ChatField** (https://github.com/kevinhermawan/ChatField):

- Lightweight SwiftUI package (one dependency: SwiftUIIntrospect)
- Explicit macOS keyboard handling (Enter → send, Shift+Enter → newline)
- `ChatField("Type a message...", text: $text) { onSend() }`
- v2.0.0, actively maintained

We do NOT need SwiftyChat (wants to own the entire chat UI) or Exyte/Chat (iOS-only).

## Validation Criteria

Before committing, verify ALL of the following:

1. ✅ `swift build` passes
2. ✅ `swift test` passes (70 tests, 0 failures)
3. ✅ Enter key sends the message
4. ✅ Shift+Enter inserts a newline without sending
5. ✅ Text field auto-expands from 1 line to ~6 lines
6. ✅ Text field scrolls after max height (no infinite growth)
7. ✅ Placeholder text "Type a message..." appears when empty
8. ✅ Send button still works (clicking paperplane)
9. ✅ Thinking bee indicator still fires on send
10. ✅ Message still appears in conversation after send
11. ✅ Theme colours and radius match existing style
12. ✅ Attachment button (+) still visible and functional
13. ✅ Mic button still visible and functional
14. ✅ No regression in message scrolling behaviour

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