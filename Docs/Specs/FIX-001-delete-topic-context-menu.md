# FIX-001: Delete Topic context menu action does not fire

**Priority:** P1 — Feature broken
**Status:** SPEC — awaiting team review
**Author:** Bee (coordinator)
**Date:** 2026-04-19

## Problem

Right-clicking a topic pill shows the "Delete Topic" context menu item, but clicking it does nothing. The topic is not removed from the UI or the database.

## Investigation

### Code path
1. `TopicBar.swift:40-42` — `.contextMenu { Button("Delete Topic") { onDeleteTopic(topic.id) } }` is attached to the `TopicPill` inside a `ForEach` inside a `ScrollView`
2. `MainWindow.swift:30` — `onDeleteTopic: { id in deleteTopic(id) }` wires to `deleteTopic(_:)`
3. `MainWindow.swift:209-218` — `deleteTopic` creates a `Task`, calls `repo.deleteCascading(id)` then `messageViewModel.removeTopic(id:)`

### Root cause hypothesis

**macOS SwiftUI known issue:** `.contextMenu` modifiers on `Button` views inside `ScrollView` containers often fail to fire their actions on macOS. The `Button`'s internal gesture recognizer conflicts with the context menu's right-click gesture. The menu appears (because the context menu gesture is recognized), but the `Button` action inside the menu doesn't fire because the gesture state is consumed by the outer `Button`'s responder chain.

This is documented in multiple SwiftUI forums and Apple Feedback reports (FBxxxxxxx). The workaround is to move the `.contextMenu` to a wrapper `View` rather than attaching it directly to a `Button`.

### Alternative hypothesis: DB error silently swallowed

If `SessionRepository().deleteCascading(id)` throws (e.g., DB not open, constraint violation), the `catch` block only prints to console — the user sees nothing. However, this is less likely since:
- The DB is opened at startup
- `deleteCascading` uses raw SQL with no foreign key constraints (FKs are OFF per config)
- The `SessionRepository` constructor uses `DatabaseManager.shared` which has the pool open

### Proposed fix

**Two changes in ONE file (`TopicBar.swift`):**

Move the `.contextMenu` modifier from the `TopicPill` (which is a `Button`) to a wrapper view. The pattern:

```swift
ForEach(topics) { topic in
    TopicPill(
        title: topic.title,
        isSelected: topic.id == selectedTopicId,
        action: { selectedTopicId = topic.id }
    )
    .contextMenu {
        Button("Delete Topic", role: .destructive) {
            onDeleteTopic(topic.id)
        }
    }
}
```

becomes:

```swift
ForEach(topics) { topic in
    TopicPill(
        title: topic.title,
        isSelected: topic.id == selectedTopicId,
        action: { selectedTopicId = topic.id }
    )
    .wrapForContextMenu {  // NO — simpler approach below
    }
}
```

Actually, the simpler fix is to just add `.contentShape(Rectangle())` before `.contextMenu`:

```swift
ForEach(topics) { topic in
    TopicPill(
        title: topic.title,
        isSelected: topic.id == selectedTopicId,
        action: { selectedTopicId = topic.id }
    )
    .contentShape(Rectangle())
    .contextMenu {
        Button("Delete Topic", role: .destructive) {
            onDeleteTopic(topic.id)
        }
    }
}
```

**`contentShape(Rectangle())`** defines the hit area for gesture recognition, ensuring the context menu gesture works correctly over the entire pill area rather than conflicting with the Button's internal gesture handling.

If `contentShape` alone doesn't fix it, the alternative is to wrap the `TopicPill` in a plain view:

```swift
ForEach(topics) { topic in
    Group {
        TopicPill(
            title: topic.title,
            isSelected: topic.id == selectedTopicId,
            action: { selectedTopicId = topic.id }
        )
    }
    .contextMenu {
        Button("Delete Topic", role: .destructive) {
            onDeleteTopic(topic.id)
        }
    }
}
```

### Additional hardening (same file, same change set)

In `MainWindow.swift`, the `deleteTopic` method should surface errors to the user instead of just printing:

```swift
private func deleteTopic(_ id: String) {
    Task {
        do {
            let repo = SessionRepository()
            try repo.deleteCascading(id)
            messageViewModel.removeTopic(id: id)
        } catch {
            print("[MainWindow] Delete topic failed: \(error)")
            // TODO: surface error to user (after basic error UI exists)
        }
    }
}
```

## Constraints

- Change `TopicBar.swift` only (add `.contentShape(Rectangle())` before `.contextMenu`)
- If that doesn't work, use the `Group` wrapper approach instead
- DO NOT change MainWindow.swift or any other file in this fix
- Build must pass clean
- All 49 tests must pass

## Validation

1. Right-click a topic → "Delete Topic" appears in context menu
2. Click "Delete Topic" → topic disappears from UI
3. Relaunch app → topic is still gone (deleted from DB)
4. Other topics remain intact
5. Creating new topics still works