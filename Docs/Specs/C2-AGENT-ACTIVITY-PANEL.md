# C2: Agent Activity Panel

**Priority:** Medium  
**Status:** Spec — awaiting Kieran review  
**Author:** Bee (Coordinator)  
**Date:** 2026-05-02

## Problem

When Bee delegates to subagents (Q, Gav, Mel, Kieran), Adam has no visibility into what's happening. The bee spins, but there's no indication of *which* agents are working, *what* they're doing, or *whether* something has failed. The only feedback is the final response arriving — or not.

## Solution

A small status panel that shows real-time agent activity, following the same sidebar button + sheet pattern already used for Folders and Themes.

## UI Design

### Entry Point: Sidebar Bottom Bar

Add a single icon button in the bottom bar, between the existing buttons. Consistent with the Folders and Themes pattern.

**Current bottom bar layout:**
```
[+ New] [📁 Folders]  ←spacer→  [🎨 Themes] [🗑 Delete]
```

**With C2 added:**
```
[+ New] [📁 Folders] [👥 Team]  ←spacer→  [🎨 Themes] [🗑 Delete]
```

**Button spec:**
- Icon: `person.3` (SF Symbol — standard macOS "team/group" icon)
- Font: `.body` (same as Themes button)
- Colour: `textSecondary` (same as Themes and Folders)
- When agents are active: badge the icon with a small dot or change colour to `accentPrimary` to indicate activity
- Help text: "Team Activity"
- Accessibility label: "Team Activity"
- Accessibility hint: "Show which agents are currently working"

### Panel: Agent Activity Sheet

Presented as a `.sheet()` — same pattern as ThemePicker and FolderPicker.

```
┌─────────────────────────────────┐
│  Team Activity              [✕] │
├─────────────────────────────────┤
│                                 │
│  🐝 Bee        ● Idle     2m   │
│  🛠 Q          ● Working  Now  │
│  🔍 Gav        ● Working  30s  │
│  🎨 Mel        ○ Idle     1h   │
│  📋 Kieran     ○ Idle     3h   │
│                                 │
│  ─── Recent ───                 │
│                                 │
│  🛠 Q completed 2m ago         │
│  🛠 Q completed 5m ago         │
│  🔍 Gav errored 8m ago        │
│                                 │
└─────────────────────────────────┘
```

**Agent row layout:**
```
[emoji] [name]  [status dot] [status label]  [time]
```

**Status states:**

| State | Dot colour | Label | Meaning |
|-------|-----------|-------|---------|
| Working | `accentPrimary` (solid) | "Working" | Agent has an active session |
| Idle | `textSecondary` (dimmed) | "Idle" | No active session |
| Error | `error` (solid) | "Error" | Last session ended with error |

**Time display:**
- Working: "Now" or "30s" (elapsed since session started)
- Idle: "2m", "1h", "3h" (time since last activity)
- Error: time since error occurred

**Recent activity section:**
- Shows last 5 completed/errored sessions
- Format: `[emoji] [name] [completed/errored] [time ago]`
- Oldest drops off when new one arrives
- Ephemeral — cleared when BeeChat restarts

### Agent Emoji Mapping

Reuse the same mapping from A1 (MessageBubble agent badges):

| Agent ID | Emoji | Display Name |
|----------|-------|-------------|
| main (Bee) | 🐝 | Bee |
| q | 🛠 | Q |
| mel | 🎨 | Mel |
| kieran | 📋 | Kieran |
| gav | 🔍 | Gav |
| unknown | 🤖 | {agentId} |

## Data Source

**Two existing event sources, no new infrastructure:**

### Primary: `didStartStreaming` / `didStopStreaming` delegate events

These are the most reliable signals. When an agent starts generating output, `didStartStreaming` fires with the session key. When it finishes, `didStopStreaming` fires. We extract the `agentId` from the session key and track it.

### Secondary: `sessions.changed` gateway event

Fires when the session index updates. We call `fetchSessions()` to get the latest session list, which gives us agent IDs and last-activity timestamps. This catches agents that may not have streamed (e.g. quick tool-only sessions) and provides the "recent activity" data.

**Key finding:** The gateway's `SessionInfo` does NOT include a `status` or `endedAt` field, so we can't determine running state directly from the session list. Instead, we infer it from streaming events (primary) and use the session list for agent discovery and timestamps (secondary).

**No new gateway subscription needed.** No new RPC calls. No database tables. Pure UI layer watching events we already receive.

### How it works:

1. `AgentActivityTracker` (new `@Observable` class) maintains an in-memory dictionary of agent activity:
   ```swift
   struct AgentActivity: Sendable {
       let agentId: String
       var status: AgentStatus  // .working, .idle, .error
       var lastActivityAt: Date
       var sessionKey: String?   // nil when idle
   }
   enum AgentStatus { case working, idle, error }
   ```

2. On `didStartStreaming(sessionKey:)` — extract agentId, set status to `.working`
3. On `didStopStreaming(sessionKey:)` — extract agentId, set status to `.idle`, add to recent activity
4. On `didEncounterError` — extract agentId, set status to `.error`, add to recent activity
5. On `sessions.changed` → `fetchSessions()` — discover all known agents (including idle ones), update `lastActivityAt` from `lastMessageAt`
6. SwiftUI observes `AgentActivityTracker` → UI updates in real-time

### Session key patterns:

| Session Key | Agent ID |
|-------------|----------|
| `agent:main:UUID` | main (Bee) |
| `agent:q:main:subagent:UUID` | q |
| `agent:gav:main:subagent:UUID` | gav |
| `agent:main:cron:UUID:run:UUID` | main (Bee — cron job) |

### What about the main session?

Bee's main session (`agent:main:UUID`) is always present. Show as "Idle" unless `didStartStreaming` fires for it, which means Bee is actively generating a response. When `didStopStreaming` fires, back to "Idle".

### What about cron sessions?

Cron sessions (`agent:main:cron:...`) are Bee running scheduled tasks. Show these as Bee "Working" when `didStartStreaming` fires for a cron session key. They'll appear and disappear naturally.

### Multiple sessions for the same agent

If Q has two subagent sessions running simultaneously, the tracker shows Q as "Working". The status is per-agent, not per-session. When ALL sessions for Q stop, Q goes to "Idle". Track this with a `Set<String>` of active session keys per agent — add on `didStartStreaming`, remove on `didStopStreaming`. When the set is empty, agent is idle.

## Architecture

### New Files

```
Sources/App/UI/Components/AgentActivityPanel.swift  — Sheet view (agent list + recent)
Sources/App/UI/Observers/AgentActivityTracker.swift — In-memory activity state
```

### Modified Files

```
Sources/App/UI/MainWindow.swift          — Add button to bottom bar, add .sheet()
Sources/App/UI/Observers/SyncBridgeObserver.swift — Wire AgentActivityTracker updates from streaming events
```

### Integration Points

1. **SyncBridgeObserver.didStartStreaming** — Add session key to agent's active set, set status to "Working"
2. **SyncBridgeObserver.didStopStreaming** — Remove session key from agent's active set, if empty set status to "Idle", add to recent activity
3. **SyncBridgeObserver.didEncounterError** — Set status to "Error", add to recent activity
4. **SyncBridge.handleSessionsChanged / fetchSessions** — Feed session list to tracker for agent discovery and last-activity timestamps (catches idle agents that aren't streaming)
5. **MainWindow bottom bar** — Button toggles `showAgentActivity` state, `.sheet()` presents panel

### What Does NOT Change

- No changes to SyncBridge, EventRouter, or BeeChatGateway
- No new database tables or migrations
- No new RPC calls or gateway subscriptions
- No changes to message rendering or streaming

### Activity Badge on Button

When any agent is "Working", the sidebar button gets a visual indicator:
- Option A: Small coloured dot overlaid on the icon (like macOS notification badges)
- Option B: Change icon colour from `textSecondary` to `accentPrimary`
- **Recommendation:** Option B — simpler, consistent with how macOS indicates active states. No custom badge overlay code needed.

## Rollback Plan

To remove this feature:
1. Delete `AgentActivityPanel.swift` and `AgentActivityTracker.swift`
2. Remove button from MainWindow bottom bar (1 line)
3. Remove `.sheet(isPresented: $showAgentActivity)` (1 line)
4. Remove tracker wiring from SyncBridgeObserver (~5 lines)

Total: ~5 lines removed from 2 existing files + 2 new files deleted.

## Validation Criteria

1. Build passes
2. Tests pass (existing + any new for AgentActivityTracker logic)
3. Sheet opens when button clicked
4. Agent statuses update in real-time when subagents spawn/complete
5. Recent activity shows last 5 completions
6. Badge indicator on button when agents are working
7. Theme-aware — uses theme tokens, no hardcoded colours
8. Accessible — VoiceOver reads agent names and statuses
9. Ephemeral — state resets on app restart (no stale data)

## Out of Scope

- Token counts / cost tracking (that's C1)
- Per-session detail or timeline (that's C1b)
- Agent configuration or management
- Kill/steer actions from the panel (future consideration)
- Persistent activity history