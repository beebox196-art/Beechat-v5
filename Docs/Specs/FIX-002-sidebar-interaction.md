# FIX-002: Sidebar Interaction — Standard macOS Patterns

**Priority:** P0 — Core functionality broken (cannot create or delete topics)
**Status:** PLAN
**Author:** Bee (coordinator)
**Date:** 2026-04-19
**Blocks:** FIX-001 (delete context menu — superseded by this fix)

## Problem Statement

After REFACTOR-001, two core interactions are broken:

1. **Cannot create topics** — the "+" toolbar button is invisible because `.toolbar` with `.primaryAction` placement puts it in the detail pane toolbar, and `.windowStyle(.hiddenTitleBar)` in AppRootView may suppress it entirely
2. **Cannot delete topics via keyboard** — `.onDeleteCommand` is a known SwiftUI bug; it doesn't fire inside `NavigationSplitView` on macOS (reported since Ventura, still unfixed)
3. **Right-click delete works** but is not discoverable — users expect visible controls
4. **New topic alert uses iOS pattern** — `.alert` with `TextField` is not native macOS UX

## Root Causes

### RC-1: Toolbar placement
`.primaryAction` places toolbar items in the detail column's toolbar area on macOS, NOT in the sidebar. Apple's own apps (Notes, Messages, Finder) put creation buttons at the bottom of the sidebar, not in the window toolbar.

### RC-2: onDeleteCommand broken in NavigationSplitView
Confirmed SwiftUI bug: `onDeleteCommand` does not fire when a `List` is inside `NavigationSplitView` on macOS. The Delete key and Edit → Delete menu are broken through this path.

### RC-3: No visible delete affordance
The context menu works but users can't discover it. macOS convention provides visible delete buttons (trash icon in sidebar bottom bar, or toolbar).

## Fix Plan

### Step 1: Sidebar bottom bar (like Finder/Notes)

Replace the current sidebar `List` with a `VStack` containing the List and a bottom action bar:

```swift
NavigationSplitView {
    VStack(spacing: 0) {
        List(selection: $messageViewModel.selectedTopicId) {
            ForEach(messageViewModel.topics) { topic in
                NavigationLink(value: topic.id) {
                    SessionRow(topic: topic)
                }
                .contextMenu {
                    Button("Delete Topic", role: .destructive) {
                        deleteTopic(topic.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)

        Divider()

        HStack(spacing: 12) {
            Button(action: { showNewTopicDialog = true }) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .help("New Topic")

            Spacer()

            if messageViewModel.selectedTopicId != nil {
                Button(action: {
                    if let id = messageViewModel.selectedTopicId {
                        deleteTopic(id)
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Delete Selected Topic")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: messageViewModel.selectedTopicId)
    }
} detail: {
    // ... existing detail pane
}
```

**Why this works:**
- Matches macOS convention (Finder, Notes, Messages all have bottom sidebar bars)
- "+" is always visible and accessible
- Trash icon appears when a topic is selected, disappears when none selected
- No toolbar quirks — it's just a VStack with buttons

### Step 2: Replace onDeleteCommand with dual delete path

Remove `.onDeleteCommand` and replace with TWO delete paths:

**Path A — `.onKeyPress(.delete)` on the sidebar VStack:**
```swift
.onKeyPress(.delete) {
    if let id = messageViewModel.selectedTopicId {
        deleteTopic(id)
        return .handled
    }
    return .ignored
}
```
Apply this to the **VStack** wrapping the sidebar, not just the List. This gives the key event a broader catchment area.

**Path B — `CommandGroup` in AppRootView for Edit → Delete menu:**
```swift
// In AppRootView.swift, add to the WindowGroup:
.commands {
    CommandGroup(after: .delete) {
        Button("Delete Topic") {
            NotificationCenter.default.post(name: .deleteSelectedTopic, object: nil)
        }
        .keyboardShortcut(.delete, modifiers: [])
    }
}
```

In MainWindow, observe the notification:
```swift
.onReceive(NotificationCenter.default.publisher(for: .deleteSelectedTopic)) { _ in
    if let id = messageViewModel.selectedTopicId {
        deleteTopic(id)
    }
}
```

And define the notification name:
```swift
extension Notification.Name {
    static let deleteSelectedTopic = Notification.Name("deleteSelectedTopic")
}
```

**Why two paths:** `.onKeyPress` can be consumed by the detail pane's focus system when a text field is focused. The menu command path works regardless of focus state. Both paths call the same `deleteTopic()` function.

### Step 3: Replace .alert with .sheet for new topic creation

Replace the current `.alert("New Topic"...)` with a proper sheet. **Attach the `.sheet` to the `NavigationSplitView`** (not the sidebar VStack) to avoid a known macOS focus bug.

Add `@FocusState` for auto-focusing the text field:
```swift
@FocusState private var isNewTopicFieldFocused: Bool
```

```swift
// On the NavigationSplitView:
.sheet(isPresented: $showNewTopicDialog) {
    VStack(spacing: 16) {
        Text("New Topic")
            .font(.headline)
        TextField("Topic name", text: $newTopicTitle)
            .textFieldStyle(.roundedBorder)
            .frame(width: 240)
            .focused($isNewTopicFieldFocused)
        HStack(spacing: 12) {
            Button("Cancel") {
                newTopicTitle = ""
                showNewTopicDialog = false
            }
            .keyboardShortcut(.cancelAction)

            Button("Create") {
                createNewTopic()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(newTopicTitle.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
    .padding(24)
    .onAppear {
        isNewTopicFieldFocused = true
    }
}
```

**Why:** Sheets are the standard macOS pattern for creation dialogs. Alerts with TextFields are iOS patterns. `@FocusState` auto-focuses the text field when the sheet opens — without it the user must click manually. Sheets provide better keyboard handling (Enter to confirm, Escape to cancel) and feel native.

### Step 4: Remove the .toolbar modifier from sidebar List

The `.toolbar { ToolbarItem(placement: .primaryAction) { ... } }` on the sidebar List should be removed entirely — it's replaced by the bottom bar buttons.

## Files Changed

| File | Action |
|------|--------|
| `MainWindow.swift` | VStack sidebar layout, onKeyPress, sheet, bottom bar, remove toolbar, notification observer |
| `AppRootView.swift` | Add `.commands` with Delete Topic menu item |
| New: `Notification.Name` extension | `deleteSelectedTopic` notification name |

## Validation

1. "+" button visible at bottom of sidebar → opens new topic sheet
2. Sheet has text field, Cancel/Create buttons, Enter/Escape keyboard shortcuts
3. Select a topic → trash icon appears in sidebar bottom bar
4. Click trash icon → deletes selected topic
5. Right-click topic → context menu with "Delete Topic" works
6. Press Delete key with topic selected → deletes it
7. No topic selected → trash icon hidden
8. Empty topic name → Create button disabled

## What We're NOT Changing

- Database layer (BeeChatPersistence) — untouched
- SyncBridge — untouched
- GatewayClient — untouched
- MessageViewModel logic — only view binding changes
- The dual observation fix from REFACTOR-001 Step 5 — stays
- The .onDisappear lifecycle fix from REFACTOR-001 Step 4 — stays