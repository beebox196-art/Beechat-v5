# DIAG-001: Delete Topic — Action Does Not Execute

**Priority:** P1
**Status:** DIAGNOSTIC — needs investigation before any code changes
**Author:** Bee (coordinator)
**Date:** 2026-04-19

## Symptom

Right-clicking a topic pill shows "Delete Topic" in the context menu, but clicking the menu item does nothing. The topic is not removed from the UI or the database.

Additionally, a hover × button was attempted — it appears on hover but clicking it also does nothing.

## What Has Been Tried (and failed)

1. **Context menu with Group wrapper** — menu appears, action doesn't fire
2. **Hover × button** — button appears, action doesn't fire
3. **`.contentShape(Rectangle())`** — not tested (approach changed before testing)

**Key observation:** Both approaches show the UI element (menu item / × button) but neither triggers the `onDeleteTopic` closure. This suggests the problem is NOT a SwiftUI gesture conflict (which would prevent the UI from showing at all) but rather something about the closure execution or the downstream code.

## Code Path

1. `TopicBar.swift:onDeleteTopic` — closure property `(String) -> Void`
2. `MainWindow.swift:30` — wired as `{ id in deleteTopic(id) }`
3. `MainWindow.swift:deleteTopic(_:)` — creates `Task`, calls `repo.deleteCascading(id)` then `messageViewModel.removeTopic(id:)`
4. `SessionRepository.deleteCascading(_:)` — raw SQL DELETE on attachments, messages, sessions
5. `MessageViewModel.removeTopic(id:)` — removes from in-memory `topics` array

## Diagnostic Questions (for the team)

1. **Is the `onDeleteTopic` closure actually being called?** Add `os_log` or a visible UI side effect (e.g., temporary background color change) to confirm the closure fires. `print()` may not show in Console.app depending on log level.

2. **If the closure fires, does `deleteTopic()` execute?** Same — add visible logging at the start of `deleteTopic()`.

3. **If `deleteTopic()` executes, does `repo.deleteCascading(id)` succeed?** Check if the DB write throws. The `catch` block only prints — easy to miss.

4. **Is there a race condition with ValueObservation?** After `deleteCascading` succeeds, the GRDB `ValueObservation` fires `updateTopics(from:)` which rebuilds the entire topics array. If this fires BEFORE `removeTopic`, the topic list is already correct (deleted topic absent). If it fires AFTER `removeTopic`, `updateTopics` replaces the array. Either way, the topic should be gone. BUT — if `deleteCascading` silently fails (e.g., wrong ID format), the observation would re-add the topic.

5. **Is `topic.id` correct in the closure?** The `ForEach(topics)` rebuilds when `topics` changes. Could the captured `topic.id` be stale? (Unlikely with value-type String, but worth confirming.)

6. **macOS SwiftUI specific:** Does `.contextMenu` on a view inside `ScrollView(.horizontal)` + `ForEach` actually fire actions on macOS? Test with a MINIMAL reproduction — a standalone SwiftUI view with ScrollView + ForEach + contextMenu + Button action that changes a @State var.

## Relevant Files

- `Sources/App/UI/Components/TopicBar.swift` — topic bar with context menu
- `Sources/App/UI/Components/TopicPill.swift` — individual pill (Button)
- `Sources/App/UI/MainWindow.swift` — deleteTopic method, ValueObservation wiring
- `Sources/App/UI/ViewModels/MessageViewModel.swift` — removeTopic, updateTopics
- `Sources/BeeChatPersistence/Repositories/SessionRepository.swift` — deleteCascading

## Constraints

- **Do NOT change any code until the root cause is confirmed.**
- Diagnosis first, fix second.
- Any fix must be verified by the builder (Q), reviewed by Kieran, then deployed.
- Deploy process: build → copy binary → codesign → kill old app → relaunch