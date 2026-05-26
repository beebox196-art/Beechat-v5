# Mel's UI/UX Review — Topic Context Persistence

**Spec:** `topic-context-persistence.md`  
**Reviewer:** Mel (UI/UX)  
**Date:** 2026-05-08  
**Verdict:** ✅ Approve with reservations — Phase 1 is solid, Phase 2 needs UX rethink

---

## 1. User Experience — Natural Flow?

### The "Project Folder" Field

**It's fine — but only if it stays optional and out of the way.**

The current new-topic sheet is a bare-bones dialog: a text field and two buttons. Adding an optional "Project Folder" field as a secondary expandable section (or a small "Advanced" toggle) keeps the happy path clean. Topics like "General" or "Optimisation" don't need one, and that's OK.

**Concern:** A raw text field for paths is error-prone. Users will typo `/Users/openclaw/Projects/` as `/User/openclaw/...` or forget trailing slashes. The spec mentions a "path picker or text field" — I'd push hard for a native `NSOpenPanel` folder picker. It's one click, zero typos, and feels native on macOS. If we must support manual entry, validate the path on blur and show a clear red error.

**Topics without project folders:** The spec handles this correctly — they get a minimal header with just the topic name. The UX implication is that the folder icon 📁 only appears next to topics that have one, which is a nice visual signal without being intrusive.

### Active Focus Field

**This is the most likely field to become stale and misleading.** Users will set it once and forget. After three conversations, "paper trading fee-free markets" might be completely irrelevant.

**Recommendation:** Don't show it as a permanent field in topic settings. Instead, make it a "note to self" — a freeform text area that's clearly labelled as optional context for the agent, not a status indicator. The agent can update it contextually, and the user can ignore it without anything looking broken.

### Resume Button

**Good instinct to make it manual rather than automatic.** The spec correctly identifies that auto-resume on topic selection could feel jarring. A "📍 Pick up where we left off" button is the right pattern.

**But:** The button should only appear when there's something meaningful to resume — i.e., after a session reset, on first open, or when the agent's context is genuinely blank. If the session is active and flowing, the button should be hidden. Showing a "Resume" button in a healthy, mid-conversation topic is confusing.

---

## 2. Simplest Path — Are We Over-Engineering the UI?

**Phase 1 could ship with ZERO new UI controls.** Here's the argument:

The context header only needs the topic name and optionally a project path. The topic name already exists. The project path could default to a convention: `/Users/openclaw/Projects/<topic-name>/` — auto-derived from the topic name, but overridable later.

**Minimal Phase 1 UI changes:**
- **None.** The context injection happens entirely in `SyncBridge.sendMessage`. The user sees no new fields, no new buttons, no new sheets. They create a topic, send a message, and the agent just... knows what they're talking about. Magic.

**Then Phase 1.5 adds:**
- Optional "Project Folder" field in the new-topic sheet (as an expandable "Optional" section)
- Folder icon 📁 in the sidebar row for topics with a project path

**Phase 2 adds:**
- Resume button on the message canvas (detail view, not sidebar)

This keeps Phase 1 as a **pure backend change with visible results** — which is the best kind of feature.

---

## 3. Future Problems

### Active Focus Staleness
Covered above. High risk. Mitigation: make it optional, don't display it prominently, let the agent manage it contextually.

### UI Clutter in Sidebar
The current `SessionRow` already has: health dot, title, unread dot, reset red dot. Adding a folder icon is the 4th indicator. That's getting crowded at 8px dot size.

**Recommendation:** The folder icon should be subtle — maybe a small 📁 emoji or SF Symbol `folder` at 0.6 opacity next to the title text, not another dot. Dots are for state; the folder is metadata.

### Resume Button Placement
The spec says "show a Resume button" but doesn't specify where. In the current `MainWindow` layout, the detail view is:

```
┌─────────────────────────┐
│ GatewayStatusBar        │
├─────────────────────────┤
│ MessageCanvas           │
│  (scrollable messages)  │
├─────────────────────────┤
│ Composer                │
└─────────────────────────┤
```

The Resume button should go **above the MessageCanvas** when no messages exist (empty topic after reset), or **as a floating pill** in the top-right of the MessageCanvas area. Not in the sidebar — the sidebar is for navigation, not actions.

### Session Reset Double-Injection
The spec addresses this well with `justAutoReset` tracking and `contextInjected` flags. Low risk if implemented correctly.

---

## 4. Visual Design — Where Things Go

### Current Layout (NavigationSplitView)

```
┌─── Sidebar (180-320px) ───┬─── Detail View ───────────┐
│                            │                            │
│  ● Revenue Generation 📁   │  GatewayStatusBar          │
│  ● BeeChat Dev             │  ───────────────────────── │
│  ● General                 │                            │
│  ● Polymarket              │  MessageCanvas             │
│  ● Optimisation            │  (messages here)           │
│                            │                            │
│  ───────────────────────   │  ───────────────────────── │
│  [+] [📁+] [👥] [📌] [🎨]  │  Composer                  │
│                            │                            │
└────────────────────────────┴────────────────────────────┘
```

### Phase 1 Changes
- **Sidebar:** Add 📁 icon next to topic names that have a `projectPath`. Small, low-opacity, inline with the title text.
- **New Topic Sheet:** Add an optional "Project Folder" field below the topic name. Use `NSOpenPanel` via a small folder button, or a text field with validation. Label it "Optional — links this topic to a project folder".
- **Topic Context Menu (right-click):** Add "Edit Project Folder..." and "Edit Active Focus..." as secondary items.

### Phase 2 Changes
- **Detail View (empty state):** When a topic is selected but has no messages (or just reset), show a centered card:
  ```
  ┌──────────────────────────────┐
  │   📍 Pick up where we left   │
  │        off on "Revenue       │
  │       Generation"?           │
  │                              │
  │   [ Resume Context ]         │
  └──────────────────────────────┘
  ```
  This replaces the blank canvas. Once the agent responds, it flows into the normal message stream.

- **Detail View (populated):** No Resume button visible. The context is already there.

### Interaction Flow

```
User creates topic "Revenue Generation"
  → Sheet shows: [Topic name] + [Optional: Project Folder 📁]
  → User picks folder or skips
  → Topic appears in sidebar with 📁 if folder set

User selects topic
  → If session is fresh/reset and has context metadata:
    → Empty state card appears: "Pick up where we left off?"
    → [Resume Context] button
  → If session is active:
    → Normal message canvas

User clicks Resume
  → Loading spinner
  → Agent responds with orientation summary
  → Summary appears as first message in stream
  → Normal conversation continues
```

---

## 5. Error States

| Error | What Happens | UX Response |
|-------|-------------|-------------|
| **Invalid project path** | User types/ selects a path that doesn't exist | Validate on save. Show inline red error: "Folder not found — please select a valid folder". Don't save the topic until path is valid (or allow saving without it since it's optional). |
| **Agent resume response is slow** | `sendResumeContext` takes 5-15s | Show a subtle loading indicator (spinner + "Reading project context..."). Timeout after 30s with "Context loading timed out — you can still start chatting." |
| **Context injection fails** | `buildContextHeader` throws or returns empty | Graceful degradation — just send the user's message without the header. No error toast needed; it's invisible to the user. |
| **Gateway offline during resume** | No connection to send resume context | Disable Resume button, show "Offline — connect to gateway to resume context". |
| **Migration fails on launch** | GRDB migration throws | App shouldn't crash. Catch, show alert: "Database migration failed — topics may not load correctly. Restart the app." |

---

## 6. Minimal Viable — What's the Absolute Minimum for Phase 1?

**Zero new UI controls.**

Phase 1 is entirely a backend change:
1. Add `projectPath` column to Topics table (migration)
2. Modify `SyncBridge.sendMessage` to prepend `[SESSION-CONTEXT]` header when appropriate
3. That's it.

The user experience improvement is **invisible but real**: the agent just knows what topic they're in. No new buttons, no new fields, no learning curve.

**Then Phase 1.5** adds the optional project folder UI (new-topic sheet extension + sidebar icon). This is where the user *sees* the feature.

**Phase 2** adds the Resume button and empty-state card.

This ordering matters because Phase 1 alone delivers 80% of the value with 20% of the UI risk. Ship the invisible improvement first, validate it works, then add the UI chrome.

---

## Summary

| Area | Rating | Notes |
|------|--------|-------|
| Problem statement | ✅ Clear | The blank-slate problem is real and well-described |
| Phase 1 approach | ✅ Solid | Context injection via message header is the right call. App-level is correct for now. |
| Phase 2 approach | ⚠️ Rethink UX | Resume button is right, but placement and visibility rules need specificity |
| UI complexity | ⚠️ Moderate | Phase 1 can be zero-UI. Don't over-build the sheet. |
| Error handling | ⚠️ Under-specified | Needs the table I provided above |
| Migration safety | ✅ Good | Additive-only migration, no data loss |
| Topics without folders | ✅ Handled | Minimal header is the right approach |

**Recommendation:** Approve Phase 1 as a backend-only change. Add the UI chrome (folder picker, sidebar icon, topic settings) as Phase 1.5 after validating the injection works in practice. Rethink Phase 2 resume UX with the empty-state card pattern described above.

— Mel 🎨
