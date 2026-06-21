# FR-004 URGENT: Topic Delete Confirmation Gate

**Date:** 2026-06-21
**Author:** Bee (coordinator)
**Status:** DRAFT — for Kieran review
**Branch:** `fix/urgent-delete-confirm` (worktree at `/Users/openclaw/Projects/BeeChat-v5-fix-urgent-delete`)
**Source of truth:** derived from `TOPIC-DELETE-SAFETY.md` (Apr 27 draft, never built)
**Target release:** v0.9.3

---

## 1. Problem

**Recurrence.** On 2026-06-21, the "AIAI" topic was hard-deleted from BeeChat. This is the second time the same bug has cost a topic — the first was "OpenClaw/Platform" on 2026-04-27. Both were lost via the same three unconfirmed delete paths:

1. Trash icon in the sidebar toolbar (`MainWindow.swift:131`)
2. `Delete` keyboard shortcut on the sidebar (`MainWindow.swift:154`)
3. `.deleteSelectedTopic` notification handler (`MainWindow.swift:161`)

All three call `deleteTopic(_:)` → `TopicRepository.deleteCascading(_:)` with **no confirmation, no undo, and no archive**. The existing `TOPIC-DELETE-SAFETY.md` spec covers the full soft-delete + archive recovery design, but was never implemented. This FR-004 covers **only** the urgent confirm-gate that prevents further accidents while the full archive UI is scoped and reviewed separately for v0.9.4.

### Why this is urgent

- It has now caused two irrecoverable data losses for Adam (Platform, AIAI).
- The fix is a pure UX gate with zero schema or migration risk.
- The pattern is already proven — `ResetSessionAlertModifier` exists and ships in v0.9.2.
- Estimated build: 30 min. Estimated review: 15 min.

### What is OUT of scope for FR-004

- Soft delete (`isArchived = true` instead of `deleteCascading`) — v0.9.4
- "Archived Topics" recovery UI — v0.9.4
- Permanent-delete flow with double confirmation — v0.9.4
- DB backup / snapshot mechanism — separate workstream
- The Apr 27 spec's full `archiveTopic()` / `restoreTopic()` / `fetchArchived()` methods — v0.9.4

---

## 2. Behaviour

When the user triggers any of the three delete paths, show a native SwiftUI confirmation alert **before** calling `deleteTopic(_:)`. Only on explicit "Delete" confirmation does the existing hard-delete proceed.

### Alert content

- **Title:** `Delete [topic name]?`
- **Message:** `This topic has [N] messages. This cannot be undone.`
  - `N` is the topic's `messageCount`. If `N == 1`, the message reads "This topic has 1 message. This cannot be undone."
  - If `N == 0`, the message reads "This topic is empty. This cannot be undone."
- **Buttons:**
  - `Cancel` (default, role `.cancel`) — dismisses alert, no action
  - `Delete` (role `.destructive`) — proceeds with hard delete

### Why hard-delete is preserved (not changed to soft delete)

The full v0.9.4 spec will replace `deleteTopic()` with `archiveTopic()`. Doing both at once would be a much larger change requiring schema validation, UI for archive recovery, and Kieran review of the full archive flow. This FR-004 is a **safety stop** between now and v0.9.4. When v0.9.4 ships, the alert text changes to "Archive" and behaviour changes to soft delete. For now, the alert just gates the existing hard delete.

### Affordances retained

- The existing `deleteErrorMsg` / `showDeleteAlert` state for **error reporting** is preserved as a separate concern. The new confirm state has a different name (`pendingDeleteTopicId`, `showDeleteConfirmAlert`) to avoid collision with the error path.
- The accessibility hint on the trash button ("Remove selected topic") stays. The confirmation alert itself is a native VoiceOver-focusable dialog with `Button("Delete", role: .destructive)`, which macOS reads as a destructive action — no extra accessibility work needed beyond the existing alert pattern.

---

## 3. Files Changed

| File | Change |
|------|--------|
| `Sources/App/UI/MainWindow.swift` | Add `pendingDeleteTopicId: String?` and `showDeleteConfirmAlert: Bool` `@State`. Replace the 3 direct `deleteTopic(id)` call sites with a `requestDeleteTopic(id:)` helper that sets the state. Add a new `DeleteTopicConfirmAlertModifier` (sibling to `ResetSessionAlertModifier`). Wire the modifier onto the view. |
| `Docs/Specs/Active/INDEX.md` | Add row for `FR-004-URGENT-DELETE-CONFIRM.md`, mark `TOPIC-DELETE-SAFETY.md` as superseded-by-FR-004 for the urgent fix portion. |
| `RELEASES.md` | Add v0.9.3 entry on release. |
| `STATUS.md` | Note the v0.9.3 change in the "Last Updated" section. |

**No persistence layer changes. No schema changes. No migration. No new tests required** (the change is a UX gate, not a logic change — the existing `BeeChatPersistenceTests` for `deleteCascading` still cover the underlying behaviour).

---

## 4. Implementation Detail (for Q)

### 4.1 New state (top of `MainWindow` struct, near line 18)

```swift
@State private var pendingDeleteTopicId: String? = nil
@State private var showDeleteConfirmAlert: Bool = false
```

Do **not** repurpose the existing `showDeleteAlert` (line 18) — that's wired to the post-delete error path. Use new state to keep error and confirm flows independent.

### 4.2 New helper method (private, near existing `deleteTopic`)

```swift
private func requestDeleteTopic(_ id: String) {
    pendingDeleteTopicId = id
    showDeleteConfirmAlert = true
}
```

### 4.3 Replace the three call sites

- `MainWindow.swift:131` (trash button) — change `deleteTopic(id)` to `requestDeleteTopic(id)`
- `MainWindow.swift:154` (`.onKeyPress(.delete)`) — change `deleteTopic(id)` to `requestDeleteTopic(id)`
- `MainWindow.swift:161` (`.deleteSelectedTopic` notification) — change `deleteTopic(id)` to `requestDeleteTopic(id)`

### 4.4 New alert modifier (after `ResetSessionAlertModifier`, around line 700)

```swift
// MARK: - Delete Topic Confirm Modifier

struct DeleteTopicConfirmAlertModifier: ViewModifier {
    @Binding var isPresented: Bool
    let topicId: String?
    let topicName: String?
    let messageCount: Int
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.alert("Delete \(topicName ?? "topic")?", isPresented: $isPresented) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onConfirm()
            }
        } message: {
            if messageCount == 0 {
                Text("This topic is empty. This cannot be undone.")
            } else if messageCount == 1 {
                Text("This topic has 1 message. This cannot be undone.")
            } else {
                Text("This topic has \(messageCount) messages. This cannot be undone.")
            }
        }
    }
}

extension View {
    func deleteTopicConfirmAlert(
        isPresented: Binding<Bool>,
        topicId: String?,
        topicName: String?,
        messageCount: Int,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(DeleteTopicConfirmAlertModifier(
            isPresented: isPresented,
            topicId: topicId,
            topicName: topicName,
            messageCount: messageCount,
            onConfirm: onConfirm
        ))
    }
}
```

### 4.5 Wire the modifier onto the view (alongside `resetSessionAlert` around line 271)

```swift
.deleteTopicConfirmAlert(
    isPresented: $showDeleteConfirmAlert,
    topicId: pendingDeleteTopicId,
    topicName: messageViewModel.selectedTopic?.name,
    messageCount: messageViewModel.selectedTopic?.messageCount ?? 0,
    onConfirm: {
        if let id = pendingDeleteTopicId {
            deleteTopic(id)
            pendingDeleteTopicId = nil
        }
    }
)
```

Note: `pendingDeleteTopicId` is captured for the `onConfirm` closure. After confirm, it's reset to nil so a second confirm doesn't double-fire.

### 4.6 Edge case: race between select and confirm

If Adam selects Topic A, hits Delete (state set with A), then selects Topic B before tapping "Delete" in the alert, the alert still confirms A — which is the **correct** behaviour (he initiated the delete against A, not B). The `pendingDeleteTopicId` is the source of truth for what's being deleted, not the current selection.

If the topic disappears from the DB for any reason between request and confirm (e.g. another path archived it), `deleteTopic` will already throw a "topic not found" error and the existing error alert handles it. No extra guard needed.

---

## 5. Test Plan

### 5.1 Build verification (Q)

- [ ] `swift build` clean — no new warnings, no compile errors
- [ ] `swift test` passes — no regression in existing 7+ persistence tests, 26 gateway tests, 48 sync bridge tests, or other suites
- [ ] No new `BeeChatAppTests` strictly required (UX gate, not logic). If Q wants belt-and-braces, add a `TopicViewModelTests` case for the new state plumbing — optional.

### 5.2 Code review (Kieran)

Kieran reviews the diff via `scripts/review/code-review.sh` (or equivalent — see `.review/review-20260531T210852Z.txt` for output format precedent). Required checks:

- [ ] All three call sites are gated, not just the trash icon
- [ ] The `onConfirm` closure actually invokes `deleteTopic(id)` — not the request helper (would be infinite loop)
- [ ] `pendingDeleteTopicId` is reset to nil after confirm (prevents stale-fire if alert is shown twice in a row)
- [ ] No new persistence-layer writes introduced
- [ ] Accessibility: the destructive role is set, alert title includes topic name, message includes count

### 5.3 Adam's manual test (after Kieran PASS, before merge to main)

Steps (run on a test topic, not a real one):

1. Open BeeChat from the worktree-built app
2. Create a test topic "Delete Confirm Test" with 2-3 messages
3. **Test 1 (trash icon):** select topic → click trash button → expect alert with "Delete Delete Confirm Test?" and "3 messages. This cannot be undone." → tap Cancel → topic still exists. Tap trash again → tap Delete → topic gone.
4. **Test 2 (keyboard):** re-create topic, select it, press `Delete` key → expect same alert flow.
5. **Test 3 (notification):** right-click a topic → "Delete Topic" → expect same alert flow. (Or trigger via whatever the notification path is — confirm with Q if unclear.)
6. **Test 4 (false cancel):** select topic, click trash, tap Cancel, repeat 5 times. Topic still exists, no state corruption. Check that no `pendingDeleteTopicId` leaks by closing/reopening the window.
7. **Test 5 (existing flow not broken):** verify session reset, topic creation, message send, and gateway reconnect all still work. Confirm-gate must not block any other interaction.

Only after all five tests pass on develop does Adam give the green light to merge to main and run `scripts/release.sh 0.9.3 2026.06.21 "FR-004 urgent delete confirm gate"`.

---

## 6. Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Alert blocks user from rapid topic cleanup | Low | Only fires on delete intent, not on selection. Cancel is default. macOS `Esc` cancels. |
| `pendingDeleteTopicId` is captured stale after topic switch | Low | Confirmed correct behaviour — see 4.6. The pending ID is the *deletion target*, not the *current selection*. |
| Alert doesn't render on a future macOS | Negligible | Native SwiftUI `.alert` is GA since macOS 12, project builds on macOS 14+ (per STATUS.md). |
| Adam finds the alert annoying after 50 uses | Low | This is exactly the trade-off. v0.9.4 will replace it with archive flow which feels different ("Archive" instead of "Delete"). For now, we accept the friction in exchange for safety. |
| Kieran finds the implementation is more than a UX gate | Low | The change is intentionally narrow: state, helper, three call-site swaps, one new modifier, one new view modifier wiring. No persistence changes. |
| Existing `deleteErrorMsg` flow collides with new state | Negligible | They use different `@State` variables and are independent paths (error fires after a *failed* delete; confirm fires *before* a delete). |
| `TOPIC-DELETE-SAFETY.md` becomes stale | Low | This FR-004 explicitly marks that doc as superseded-for-the-urgent-portion. The archive portion of the old spec is still the v0.9.4 source. |

---

## 7. Release & Rollout

1. Q implements on `fix/urgent-delete-confirm` branch (worktree at `/Users/openclaw/Projects/BeeChat-v5-fix-urgent-delete`).
2. Q runs `swift build` + `swift test` — must be clean.
3. Kieran runs the diff review — must be PASS or PASS-with-conditions.
4. Q addresses any Kieran findings.
5. Adam opens the worktree-built app and runs the 5-step manual test plan.
6. Adam confirms green light in the Beechat topic (this Telegram thread).
7. Q merges `fix/urgent-delete-confirm` → `develop` (no direct-to-main).
8. Q runs `scripts/release.sh 0.9.3 2026.06.21 "FR-004 urgent delete confirm gate"`. This:
   - Bumps VERSION to `0.9.3`
   - Updates `BeeChatApp.app/Contents/Info.plist`
   - Builds the release binary
   - Copies to `BeeChatApp.app/Contents/MacOS/`
   - Commits the version bump
   - Tags `v0.9.3-release` and `v0.9.3`
   - Merges `develop` → `main`
9. Adam restarts BeeChat from the v0.9.3 build, verifies it's running v0.9.3 (Cmd+, → About), and pushes to origin: `git push origin main --tags`.
10. v0.9.3 is live. v0.9.4 (archive flow) planning starts.

### Rollback

If a regression surfaces after release: revert the merge commit on main, retag as `v0.9.2-hotfix`, and re-push. The change is so narrow (one modifier + three call-site swaps) that the revert is a single `git revert` and a fresh `scripts/release.sh` call. No data migration rollback needed because no schema changed.

---

## 8. Open Questions

None for the urgent fix. The v0.9.4 spec (archive flow) will have its own open questions about UI placement, archive retention, and how to handle the migration of already-deleted topics from the Apr 27 / Jun 21 incidents.

---

## 9. Pre-flight Checklist (before sending to Q)

- [x] Behaviour defined — see §2
- [x] Files listed — see §3
- [x] Implementation detail — see §4
- [x] Test plan — see §5
- [x] Risks assessed — see §6
- [x] Rollout plan — see §7
- [x] Worktree created at `/Users/openclaw/Projects/BeeChat-v5-fix-urgent-delete` on branch `fix/urgent-delete-confirm`
- [ ] Kieran review scheduled
- [ ] Adam's manual test environment confirmed (worktree-built `.app`)
