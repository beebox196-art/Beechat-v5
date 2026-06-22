# REFACTOR-001: Adopt Standard macOS SwiftUI Patterns

**Priority:** P1 — Foundation fix
**Status:** PLAN
**Author:** Bee (coordinator)
**Date:** 2026-04-19

## Lesson Learned

We built custom UI components instead of using Apple's standard SwiftUI patterns. This caused a P1 bug (delete topic doesn't work) because we used `@Observable class` for list items inside `ForEach`, which breaks view identity when the array is replaced. Standard Apple patterns use structs for list items and `@Observable` only on the store.

**Principle:** Use Apple's standard, battle-tested patterns as the foundation. Build unique UI on top, not instead of, these patterns.

## Current State (What We Built)

- Custom `TopicBar` — horizontal pill bar in a `ScrollView`
- Custom `TopicPill` — `Button`-based pill component
- `TopicViewModel` — `@Observable class` (reference type, breaks ForEach identity)
- `MainWindow` — single VStack layout, no NavigationSplitView
- Delete via `.contextMenu` on Button inside ScrollView (broken due to class identity)
- Selection via manual `@Binding` passthrough
- GRDB `ValueObservation` → `updateTopics()` replaces entire topics array each time

## Target State (Standard Apple Pattern)

- `NavigationSplitView` — sidebar + detail (standard macOS layout)
- `List(selection:)` — built-in selection tracking
- `SessionRow` — simple row view for List (struct-based data)
- Struct-based model for list items
- `@Observable` only on the store (`MessageViewModel` or new `SessionStore`)
- Delete via `.onDeleteCommand` + `.contextMenu` + toolbar button (all three)
- GRDB `ValueObservation` updates store, SwiftUI diffs struct arrays correctly

## Refactor Steps

### Step 0: Fix P0 crash in MacTextView.swift (CRITICAL — do first)

**File:** `Sources/App/UI/Components/MacTextView.swift`

**Problem:** Force unwrap `textContainer!` in `intrinsicContentSize` can crash during teardown.

**Fix:** Replace:
```swift
let usedRect = layoutManager?.usedRect(for: textContainer!)
```

With:
```swift
guard let textContainer = textContainer else {
    return NSSize(width: NSView.noIntrinsicMetric, height: minHeight)
}
let usedRect = layoutManager?.usedRect(for: textContainer)
```

**Why first:** This is a P0 crash risk. Fix before any other changes.

---

### Step 1: Convert TopicViewModel to struct

**File:** `Sources/App/UI/ViewModels/TopicViewModel.swift`

- Remove `@Observable` and `final class` — make it a `struct`
- Add `Hashable` conformance (needed for `List(selection:)`)
- Remove `update(from:)` method — structs are replaced, not mutated
- Keep `sorted(from:)` as a static factory method

```swift
struct TopicViewModel: Identifiable, Hashable {
    let id: String
    var title: String
    var icon: String?
    var lastMessageAt: Date?
    var unreadCount: Int
    
    static func sorted(from sessions: [Session]) -> [TopicViewModel] {
        sessions
            .map { TopicViewModel(from: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}
```

### Step 2: Replace TopicBar with NavigationSplitView sidebar

**File:** `Sources/App/UI/MainWindow.swift`

Replace the current VStack layout:
```
VStack {
    TopicBar(topics, selectedTopicId, ...)
    MessageCanvas(messages)
    Composer(onSend)
}
```

With NavigationSplitView:
```
NavigationSplitView {
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
    .onDeleteCommand { deleteSelectedTopic() }
    .toolbar {
        ToolbarItem {
            Button(action: createNewTopic) {
                Label("New Topic", systemImage: "plus.circle")
            }
        }
    }
} detail: {
    VStack(spacing: 0) {
        MessageCanvas(messages, isStreaming)
        Divider()
        Composer(viewModel, onSend)
    }
}
```

### Step 3: Create SessionRow view

**New file:** `Sources/App/UI/Components/SessionRow.swift`

Simple row view for the sidebar List:
```swift
struct SessionRow: View {
    let topic: TopicViewModel
    
    var body: some View {
        HStack {
            Text(topic.title)
                .lineLimit(1)
            Spacer()
            if topic.unreadCount > 0 {
                Text("\(topic.unreadCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
```

### Step 4: Remove custom components

- Delete `Sources/App/UI/Components/TopicBar.swift`
- Delete `Sources/App/UI/Components/TopicPill.swift`
- Remove `TopicBar`-related state from `MainWindow`
- Remove `onDeleteTopic` closure passthrough

### Step 5: Add delete via .onDeleteCommand

**File:** `Sources/App/UI/MainWindow.swift`

```swift
.onDeleteCommand {
    if let id = messageViewModel.selectedTopicId {
        deleteTopic(id)
    }
}
```

### Step 7: Fix dual observation race condition

**File:** `Sources/App/UI/MainWindow.swift`

**Problem:** Two independent paths both call `updateTopics()`:
1. Local GRDB `ValueObservation` in `startLocalSessionObservation()`
2. Gateway `sessionListStream()` in `rewireForGateway()`

These can race, causing rapid array replacement and potential state corruption.

**Fix:** Use ONLY the local GRDB `ValueObservation` for topic list updates. The gateway path should ONLY update message content, not the session list. Remove the `sessionListStream()` loop in `rewireForGateway()`.

**Rationale:** GRDB `ValueObservation` watches the sessions table directly. Whether sessions come from local creation or gateway sync, they're persisted to the DB first, so the observation fires correctly. The gateway stream is redundant for session list updates.

### Step 8: Properly cancel ValueObservation on view disappear

**File:** `Sources/App/UI/MainWindow.swift`

**Problem:** `localSessionCancellable` is stored but never explicitly cancelled.

**Fix:** Add `.onDisappear` to `MainWindow` body:
```swift
.onDisappear {
    localSessionCancellable?.cancel()
    localSessionCancellable = nil
}
```

**Why:** Prevents database connection leaks when the view is destroyed.

- `selectedTopicId` stays as-is (will be bound to `List(selection:)`)
- `removeTopic(id:)` stays — needed for the delete action
- `updateTopics(from:)` stays — but now works correctly with struct array diffing

## Validation

1. App launches with sidebar showing topics
2. Click a topic → selects it, shows messages in detail pane
3. Right-click → Delete → topic removed from sidebar and DB
4. Edit → Delete menu → deletes selected topic
5. Delete key → deletes selected topic
6. + button → creates new topic
7. Relaunch → topics persist
8. No crashes on rapid selection changes

## Files Changed

| File | Action |
|------|--------|
| `TopicViewModel.swift` | Convert class → struct |
| `MainWindow.swift` | NavigationSplitView layout |
| `SessionRow.swift` | New file |
| `TopicBar.swift` | Delete |
| `TopicPill.swift` | Delete |

## Constraints

- All existing tests must pass
- DB layer (BeeChatPersistence) unchanged
- SyncBridge layer unchanged
- Only UI layer changes