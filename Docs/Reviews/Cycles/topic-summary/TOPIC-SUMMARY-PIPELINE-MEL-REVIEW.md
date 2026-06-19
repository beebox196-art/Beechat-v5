# Mel Review: Topic Summary Pipeline

**Reviewed:** 2026-05-31T20:19:00+01:00  
**Reviewer:** Mel  
**Spec:** `TOPIC-SUMMARY-PIPELINE.md`  
**Foundation:** `TOPIC-PROJECT-CONTINUITY.md`

## Summary Verdict

**APPROVE-WITH-CHANGES**

The product direction is right: Phase 2 should feel like a quiet extension of Phase 1, not a new memory product bolted onto the sidebar. The current spec is technically coherent but underspecified at the UI layer. Before build, it needs exact placement, status timing, accessibility behavior, and a clear rule for where summary status appears. The simplest native-feeling version is:

- Add **Save Topic** to the existing topic context menu, directly after **Edit Topic**.
- Use a document/save SF Symbol icon, not another folder glyph.
- Show save progress through the same transient status pattern Phase 1 already uses.
- Add topic-summary status to `EditTopicSheet` inside the existing **Context files** section.
- Avoid permanent new sidebar badges unless there is an error or active save state.

## Critical Issues

### 1. Context menu placement and labeling must be specified

The existing topic row context menu is currently:

1. `Edit Topic`
2. `Reset Session`
3. divider
4. `Delete Topic`

**Save Topic** should sit immediately after **Edit Topic** and before **Reset Session**:

1. `Edit Topic`
2. `Save Topic`
3. `Reset Session`
4. divider
5. `Delete Topic`

This keeps it with non-destructive topic-management actions and away from the destructive section. It also avoids pairing it visually with reset, which could make “save” feel like a session lifecycle action rather than a summary/write action.

Use a `Label`, not plain text:

```swift
Label("Save Topic", systemImage: "doc.badge.plus")
```

If the action is specifically “write current summary file now,” `doc.badge.plus` is more truthful than `square.and.arrow.down`, which reads as export/download. Accessibility label: **"Save topic summary"**. Accessibility hint: **"Writes the latest durable topic state to the project summary file."**

### 2. Transient status feedback is too vague to build consistently

The spec says `Saving...` -> `Topic saved`, but does not define where, duration, failure state, or VoiceOver behavior.

Use the Phase 1 send-time transient pattern, not a new toast system. Recommended placement:

- In the selected topic row, show a trailing inline status while the context menu action is running.
- For the active conversation, mirror the status near the existing reset/project-context transient area if that area already exists on screen.
- Do not create a global toast for this; it is a topic-scoped operation.

States:

- `Saving topic...` with a small progress spinner.
- `Topic saved` for 2 seconds.
- `Could not save topic` for 4 seconds with a subtle amber/red warning and tooltip containing the reason.

VoiceOver:

- Post an announcement on each state transition: **"Saving topic summary"**, **"Topic summary saved"**, or **"Topic summary could not be saved: [reason]"**.
- The row should expose `accessibilityValue` during the transient state, not just visual text.
- The menu item should be disabled while a save for that topic is already in progress and expose **"Save already in progress"** as the accessibility hint/value.

### 3. Topic summary status must be integrated into `EditTopicSheet`

Phase 1 already adds a **Context files** section to `EditTopicSheet` showing `STATUS.md`, `README.md`, `decisions.md`, and `corrections.md`. Phase 2 should extend that section with one additional topic-specific row rather than adding a separate summary panel.

Add a row:

- `Topic summary`
- status: `found`, `missing`, `updating`, `error`, or `stale`
- metadata: last updated time and approximate size when found

Example accessibility label:

**"Topic summary, found, last updated today at 8:12 PM, 2.1 kilobytes."**

For project-bound topics, this row points at:

`projectPath/docs/topics/{topic-id}-summary.md`

For unbound topics:

`workspace/docs/topics/unbound/{topic-id}-summary.md`

Do not show the full summary text by default. If preview is needed, reuse Phase 1’s collapsed preview disclosure pattern and cap it tightly.

### 4. Sidebar visual rules need a clutter guard

Phase 1 already gives project-bound topics a folder glyph and context status color treatment. Phase 2 should not add a second persistent icon for every topic with a summary. The sidebar already carries topic health, unread state, reset state, and project binding. A permanent summary badge would push the row toward indicator clutter.

Recommended rule:

- Project-bound vs unbound: keep Phase 1’s folder glyph as the persistent distinction.
- Summary saved recently: show transient status only.
- Summary exists: expose this in tooltip/help and `EditTopicSheet`, not as a default persistent sidebar badge.
- Summary error or stale write: show a temporary warning state in the row until the next successful save or user dismissal.

If a persistent indicator is later required, combine it into the folder treatment instead of adding another glyph. For example, `folder.fill` for linked, `folder.badge.plus` or a subtle check overlay for summary available. Keep it to one project/topic-context indicator total.

## Warnings

### 1. iOS needs its own wording and confirmation path

On iPhone, “Save Topic” is not a local file write. It delegates to the Mac/gateway. The UI should not imply the phone wrote a file directly.

Recommended iOS wording:

- Context menu / long-press action: **"Save Topic Summary"**
- In-progress: **"Saving on Mac..."**
- Success: **"Topic saved on Mac"**
- Mac unavailable: **"Save queued until Mac is available"** or **"Mac unavailable"**, depending on actual implementation.

Accessibility label:

**"Save topic summary on Mac"**

Accessibility hint:

**"Requests the Mac to write this topic summary to the project files."**

This is consistent with Phase 1’s amber degraded-context language for iOS, where project files are Mac-side resources.

### 2. Visual language should follow Phase 1, not introduce a new status vocabulary

Phase 1 uses:

- folder glyphs for project binding
- green/amber status indicators for context availability
- transient send-time messages
- compact inline file status in `EditTopicSheet`

Phase 2 should reuse those exact conventions:

- Green: summary saved / summary file available.
- Amber: queued, stale, unavailable, or Mac-only degraded state.
- Red only for a real failed write.
- Folder glyph remains project-binding; document glyph represents topic summary.

Avoid new badge colors, new card styles, or a global notification pattern for this feature.

### 3. The action name may be too broad

`Save Topic` is concise but a little ambiguous: it could mean save edits to the topic name, persist the session, export the chat, or save the summary.

Preferred menu label:

**"Save Topic Summary"**

If space or menu simplicity matters, keep the visible text as **"Save Topic"**, but use the accessibility label and tooltip/help text to clarify:

- Help: **"Save durable decisions and current state for this topic."**
- Accessibility label: **"Save topic summary."**

### 4. Manual save should have an empty-result state

The extractor may find nothing durable. The UI should not say **"Topic saved"** if no file was written and nothing changed.

Add a neutral result:

- `No summary changes` for 2 seconds.
- Accessibility announcement: **"No durable topic changes found."**

This prevents Adam from trusting that a useful update was written when the extraction correctly produced an empty result.

### 5. Error feedback needs recovery affordance

If save fails, the row status alone may disappear before Adam can act. For failures, include the reason in `.help` and keep an error state visible until one of:

- the user retries and succeeds
- the user changes topic selection
- the error is dismissed by an explicit lightweight action

Do not add a modal alert for ordinary write failures. This should remain non-blocking.

## Observations

### 1. Minimal UI is the right call

The feature’s value is continuity, not a new dashboard. The ideal UI surface is one menu item, one transient status, and one extra row in `EditTopicSheet`. Anything more risks making the sidebar feel like a monitoring console.

### 2. Summary freshness may matter later

If Adam starts relying on topic summaries heavily, consider a future freshness indicator in `EditTopicSheet`:

- `Updated today`
- `Updated yesterday`
- `Not saved yet`
- `Last save failed`

Do not ship this as a sidebar badge in the first pass.

### 3. Keyboard access should be included

The context menu action should also be reachable from the app’s command/menu system if topic rows already have keyboard-focused management actions. Suggested command title: **"Save Topic Summary"**. Disable it when no topic is selected.

### 4. Native macOS/iOS behavior beats custom decoration here

This is operational UI. It should feel like the rest of BeeChat: compact, calm, and status-rich only when status matters. Resist decorative summary cards, animated badges, or persistent visual noise.

### 5. Verification checklist should add UI-specific cases

Add manual checks:

- Right-click topic row shows `Save Topic` after `Edit Topic` and before `Reset Session`.
- Save action shows `Saving topic...` then `Topic saved` for 2 seconds.
- Empty extraction shows `No summary changes`.
- Failed save exposes a visible reason and VoiceOver announcement.
- `EditTopicSheet` shows the topic summary row with found/missing/stale state.
- iOS says `Saving on Mac...` / `Topic saved on Mac`, not local-save language.
