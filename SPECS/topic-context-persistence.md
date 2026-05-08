# BeeChat v5: Topic Context Persistence

**Spec ID:** BC5-SPEC-004  
**Date:** 2026-05-08  
**Author:** Bee (coordinator)  
**Status:** DRAFT — Team Review Required  
**Priority:** High (core UX improvement)  

---

## Problem Statement

When a user opens BeeChat (or reconnects after closing the app), they encounter a **blank slate**. The agent wakes up with no context about:

1. **Which topic/conversation** the user is in
2. **What was last discussed** in that topic
3. **What the next step was** before the session ended

In Telegram, this isn't an issue — each forum topic maps to a persistent session key, and sessions accumulate context until they compact. But BeeChat creates or reconnects to sessions without injecting any topic context, so the agent starts every interaction with "Hi, how can I help?" instead of picking up where things left off.

Meanwhile, BeeChat already has:
- **Topics** in the sidebar (some linked to project folders, some not)
- **Session keys** stored per topic via `TopicSessionBridge`
- **Local message history** in SQLite
- **Auto-reset on high usage** (already implemented in SyncBridge)

What's missing is the **bridge between topic identity and agent context**.

---

## Current Architecture

### What We Have

```
┌──────────────┐     ┌───────────────┐     ┌──────────────────┐
│   Topic UI    │────▶│  Topic Model  │────▶│  Session Key     │
│  (sidebar)    │     │  (GRDB)       │     │  (topic_session  │
│               │     │  name, id,    │     │   _bridge)       │
│               │     │  sessionKey?  │     │                  │
└──────────────┘     └───────────────┘     └──────────────────┘
                                                      │
                                                      ▼
                                            ┌──────────────────┐
                                            │  OpenClaw Gateway │
                                            │  sessions.list   │
                                            │  chat.send       │
                                            │  chat.history    │
                                            └──────────────────┘
```

### Topic Model (current)

```swift
public struct Topic: Codable, UpsertableRecord {
    public var id: String
    public var name: String              // Display name
    public var lastMessagePreview: String?
    public var lastActivityAt: Date?
    public var unreadCount: Int = 0
    public var sessionKey: String?       // Gateway session key
    public var isArchived: Bool = false
    public var createdAt: Date
    public var updatedAt: Date
    public var metadataJSON: String?     // ← THIS IS THE EXTENSION POINT
    public var messageCount: Int = 0
}
```

### How Sessions Work Today

1. **Topic creation**: User creates a topic in BeeChat. A `Topic` record is saved with a UUID `id` and a `name`. No `sessionKey` yet.
2. **First message**: When the user sends a message in a topic, BeeChat calls `chat.send` with the topic's eventual session key. The gateway creates a session if one doesn't exist.
3. **Session key mapping**: `TopicSessionBridge` maps `topicId` → `openclawSessionKey`. The `Topic.sessionKey` field also stores this.
4. **Session persistence**: The session key is stored in the local DB. Reopening the app and selecting the same topic resumes the same session.
5. **Auto-reset on bloat**: When `sessionsUsage` exceeds the threshold, BeeChat auto-resets the session and prepends `[SESSION-CONTEXT]` with the last 30 messages.

### The Gap

After auto-reset (or a fresh session), the agent has:
- The `[SESSION-CONTEXT]` prefix with recent messages (if auto-reset happened)
- The session's accumulated conversation up to the context window

But it does **NOT** have:
- The **topic name** (e.g. "Revenue Generation", "BeeChat Dev")
- The **project folder path** (e.g. `/Users/openclaw/Projects/Revenue Generation/`)
- Any **active focus or status** from the project

This means even with session continuity, the agent can't immediately orient itself to the right context without the user restating what they're working on.

---

## Proposed Solution

### Phase 1: Topic Context Injection (Minimal, High Value)

**Goal:** When a message is sent from a topic, BeeChat includes the topic's identity and project context as part of the initial message or as session metadata.

#### 1.1 Extend the Topic Model

Add an optional `projectPath` field and formalise the `metadataJSON` structure:

```swift
public struct Topic: Codable, UpsertableRecord {
    // ... existing fields ...
    public var projectPath: String?       // NEW: linked project folder path
    public var metadataJSON: String?     // EXISTING: now structured
    
    // metadataJSON structure:
    // {
    //   "activeFocus": "paper trading fee-free markets",  // optional one-liner
    //   "tags": ["revenue", "polymarket"],                 // optional tags
    //   "autoContext": true                                 // whether to inject context
    // }
}
```

**Migration:** GRDB `alter(table:add:)` — additive only, no data loss. `projectPath` defaults to `nil`, `metadataJSON` keeps working as-is for existing rows.

#### 1.2 Database Migration

```swift
// In DatabaseManager, add migration:
migrator.registerMigration("v7_add_project_path") { db in
    try db.alter(table: "topics") { t in
        t.add(column: "projectPath", .text)
        // metadataJSON already exists as text column
    }
}
```

#### 1.3 Topic Creation/Editing UI

- **New topic sheet**: Add an optional "Project Folder" field (path picker or text field)
- **Topic settings**: Allow editing project path and active focus after creation
- **Topic list**: Show a folder icon 📁 next to topics with a project path

#### 1.4 Context Injection on Message Send

When the user sends a message from a topic that has context metadata, BeeChat prepends a **context header** to the message:

```
[SESSION-CONTEXT]
Topic: Revenue Generation
Project: /Users/openclaw/Projects/Revenue Generation/
Active Focus: paper trading fee-free markets
Tags: revenue, polymarket

User message follows:
```

This is sent as the `message` parameter to `chat.send`. It's the same pattern already used by the auto-reset flow (`[SESSION-CONTEXT] Continuing from a previous session...`).

**Key rules:**
- Context is only injected on the **first message of a new or reset session**, not every message
- Context injection is controlled by `metadataJSON.autoContext` (default: `true`)
- The agent sees this as part of the user message, so it naturally orients to the topic

#### 1.5 When to Inject Context

Context should be injected in these situations:

| Situation | How to detect | What to inject |
|-----------|---------------|----------------|
| New topic, first message ever | No session key exists for this topic | Full context header |
| After auto-reset | `didStartAutoReset` delegate callback fires | Full context header (already happens via `formatCombinedContext`) |
| Session reconnect after app restart | Session key exists but session was reset/expired on gateway | Check via `chat.history` — if empty or starts with compaction marker, inject context |
| Normal continuation | Session key exists, history present | No injection needed — agent has context |

**Detection logic for "needs context injection":**

```swift
func needsContextInjection(topic: Topic, sessionKey: String) async -> Bool {
    // 1. No session key → new topic, needs context
    guard let sessionKey = topic.sessionKey, !sessionKey.isEmpty else { return true }
    
    // 2. Check if we just auto-reset (delegate flag)
    if justAutoReset.contains(sessionKey) { return true }
    
    // 3. Check session history length — empty or very short means fresh/reset
    if let history = try? await syncBridge.fetchHistory(sessionKey: sessionKey, limit: 5),
       history.count <= 1 {
        return true
    }
    
    return false
}
```

#### 1.6 Context Construction

```swift
func buildContextHeader(topic: Topic) -> String {
    var lines = ["[SESSION-CONTEXT]"]
    lines.append("Topic: \(topic.name)")
    
    if let projectPath = topic.projectPath {
        lines.append("Project: \(projectPath)")
    }
    
    if let metadata = topic.parsedMetadata {
        if let focus = metadata.activeFocus {
            lines.append("Active Focus: \(focus)")
        }
        if let tags = metadata.tags, !tags.isEmpty {
            lines.append("Tags: \(tags.joined(separator: ", "))")
        }
    }
    
    return lines.joined(separator: "\n")
}
```

---

### Phase 2: Resume Context on Session Start (Medium Effort, High Value)

**Goal:** When a user opens a topic (selects it in the sidebar), BeeChat proactively asks the agent to orient itself.

#### 2.1 "Resume Context" on Topic Selection

When the user selects a topic in the sidebar, BeeChat sends a **system event** (not a user message) to the agent:

```
Resume context for topic "Revenue Generation". Project path: /Users/openclaw/Projects/Revenue Generation/. Active focus: paper trading fee-free markets.
```

This uses the existing `chat.inject` RPC method, which appends an assistant note to the transcript without triggering an agent run. Or alternatively, uses a dedicated "system prompt" mechanism if the gateway supports one per-session.

**Better approach:** Use `chat.send` with a special marker that the agent recognizes as a context resume request:

```swift
func sendResumeContext(topic: Topic, sessionKey: String) async throws {
    let contextMessage = """
    [RESUME-CONTEXT] Resuming work on: \(topic.name)
    \(topic.projectPath.map { "Project: \($0)" } ?? "")
    \(topic.parsedMetadata?.activeFocus.map { "Focus: \($0)" } ?? "")
    
    Briefly confirm current context and what we're working on.
    """
    try await syncBridge.sendMessage(sessionKey: sessionKey, text: contextMessage)
}
```

**UX:** When the user selects a topic, BeeChat shows a brief "Loading context..." state, sends the resume message, and displays the agent's orientation response as the first thing they see.

#### 2.2 Agent-Side Convention

The agent (Bee) already has memory tools, LCM, and wiki. With the topic name and project path in the context header, the agent can:

1. Read the project's `STATUS.md` or `CONTEXT.md` if one exists
2. Do a targeted LCM/wiki search for recent work on that topic
3. Respond with a 2-3 line orientation summary

No agent code changes are needed — this is purely a prompt convention.

---

### Phase 3: Project Context Files (Lower Priority, Refinement)

**Goal:** Each project gets a `CONTEXT.md` file that the agent reads on topic entry.

This is already partially in place via AGENTS.md's handoff protocol and project STATUS.md files. The enhancement would be:

- BeeChat could prompt the user to create a `CONTEXT.md` when linking a project folder
- The agent reads `CONTEXT.md` on resume if the project path is provided
- Updates to `CONTEXT.md` happen naturally through agent interactions

This is optional and doesn't require any BeeChat code changes — it's an agent-side convention.

---

## Failure Analysis

### What Could Go Wrong

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|-----------|--------|------------|
| 1 | **Context header breaks agent prompting** | Medium | High — agent misinterprets the header as a user command | Use clear `[SESSION-CONTEXT]` / `[RESUME-CONTEXT]` markers. Agent prompt conventions already handle this. Test with multiple models. |
| 2 | **Context injection on every message** (instead of only first/reset) | Medium | Medium — wastes tokens, confuses agent | Strict detection logic. Only inject when `needsContextInjection()` returns true. Add a per-session flag `contextInjected` that resets on session reset. |
| 3 | **Session key not yet assigned when first message sent** | High | Low — message goes to wrong session | Already handled: `sendMessage` assigns session key after first `chat.send` response. Context injection should use the same flow. |
| 4 | **Auto-reset + context injection creates duplicate context** | Medium | Medium — agent sees context twice | When auto-reset fires, `formatCombinedContext` already prepends context. If topic context is also injected, it'll be doubled. **Fix:** Skip topic context injection when auto-reset just happened — the auto-reset context already includes the conversation history. |
| 5 | **Topic metadata becomes stale** | High | Low — agent sees outdated focus | This is acceptable. The focus line is a hint, not a guarantee. Stale context is still better than no context. The agent can check project STATUS.md for current state. |
| 6 | **Database migration fails on existing topics** | Low | High — app crashes on launch | GRDB additive migrations (`alter(table:add:)`) are safe — nil defaults. Add test for migration path. |
| 7 | **`projectPath` points to non-existent folder** | Medium | Low — agent reads folder, finds nothing | Agent should handle gracefully (file not found → skip project context). UI could validate path on entry. |
| 8 | **Context injection breaks `idempotencyKey` dedup** | Low | Medium — duplicate messages | `idempotencyKey` is per-send, not per-session. Context header changes the message content but not the key. Already safe. |
| 9 | **Resume context on topic selection is jarring** | Medium | Medium — user doesn't expect an AI message when just clicking a topic | Make it opt-in per topic (via `metadataJSON.autoContext`). Default off initially. Show a subtle "resume" button instead of auto-sending. |
| 10 | **Bloat from project STATUS.md reads** | Low | Low — extra tokens | Only the agent reads STATUS.md on resume. This is one file read per topic activation. Acceptable. |

### Critical Failure Mode: Broken Session Continuity

**Scenario:** Context injection changes message content, which changes the hash, which breaks session replay or dedup.

**Analysis:** `chat.send` doesn't hash message content for replay. The `idempotencyKey` is a UUID generated per-send. Session replay works on message IDs returned by the gateway. **No risk.**

### Critical Failure Mode: App Crash on Migration

**Scenario:** Database migration fails on an existing BeeChat database.

**Mitigation:** 
- Additive migration only (new column with nil default)
- Write a test that creates a DB with v6 schema, runs migration, verifies v7 schema
- Ship with a rollback path: if migration fails, the app deletes the DB and re-creates from scratch (acceptable for a pre-release app)

### Critical Failure Mode: Context Header Conflicts with Auto-Reset

**Scenario:** User sends a message → auto-reset fires → context is injected both by auto-reset AND topic context injection.

**Mitigation:**
```swift
// In SyncBridge.sendMessage, after auto-reset logic:
if justAutoReset {
    // Auto-reset already prepended context — skip topic context injection
    return effectiveText  // no additional context header
} else if needsContextInjection(topic: topic, sessionKey: sessionKey) {
    let header = buildContextHeader(topic: topic)
    effectiveText = "\(header)\n\n\(effectiveText)"
}
```

This is the same code path that already handles `formatCombinedContext`. Just extend it.

---

## Implementation Plan

### Phase 1 (Topic Context Injection) — Estimated: 2-3 days

**Step 1: Database Migration** (Q, 0.5 day)
- Add `projectPath` column to `Topic` model
- Define `TopicMetadata` struct for `metadataJSON` parsing
- Write migration test (v6 → v7)

**Step 2: Topic UI Updates** (Mel, 1 day)
- Add "Project Folder" field to New Topic sheet
- Add "Project Folder" and "Active Focus" fields to Topic Settings
- Show folder icon on topics with project paths
- All behind a feature flag initially

**Step 3: Context Injection Logic** (Q, 1 day)
- Add `needsContextInjection()` to SyncBridge
- Add `buildContextHeader()` to SyncBridge
- Integrate into `sendMessage()` flow (after auto-reset check)
- Add `contextInjected` per-session tracking (resets on session reset)

**Step 4: Testing** (Kieran, 0.5 day)
- Test: new topic → first message includes context header
- Test: continued session → no context header
- Test: auto-reset → no double context header
- Test: topic with no project path → minimal context header
- Test: app restart → session reconnect detection
- Test: database migration from v6

### Phase 2 (Resume Context) — Estimated: 1-2 days

**Step 5: Resume Context on Topic Selection** (Q, 1 day)
- Add `sendResumeContext()` to SyncBridge
- Add opt-in `autoContext` flag per topic
- Add "Resume" button in topic header (or auto-trigger based on setting)
- Wire to topic selection in UI

**Step 6: Agent Convention** (Bee, 0.5 day)
- Update AGENTS.md or SOUL.md with context resume convention
- No code changes — purely a prompt convention for how the agent handles `[RESUME-CONTEXT]`

---

## Feature Flag

All context injection features should be behind a feature flag to allow safe rollout:

```swift
struct BeeChatFeatureFlags {
    static let topicContextInjection = true   // Phase 1
    static let resumeContextOnSelect = false  // Phase 2 (off by default)
    static let autoContextPerTopic = false    // Phase 2 (off by default)
}
```

Flags can be read from UserDefaults for easy toggling during testing.

---

## What Does NOT Change

1. **Session creation/resumption** — BeeChat still creates and resumes sessions the same way via `chat.send`
2. **Auto-reset on bloat** — Already implemented, keeps working as-is
3. **Topic sidebar** — Visual changes only (folder icon, settings). Core navigation unchanged
4. **Message flow** — `chat.send` → gateway → agent → `chat` event → UI. Same pipeline
5. **Telegram topics** — Not affected. Telegram has its own session binding. This is BeeChat-only

## Open Questions for Team Review

1. **Should context injection happen at the app level (BeeChat prepends to message) or the gateway level (new RPC parameter)?**  
   - App level is simpler, no gateway changes needed, works today
   - Gateway level is cleaner semantically but requires OpenClaw code changes
   - **Recommendation:** Start with app level. Revisit gateway level if it proves valuable.

2. **Should `projectPath` be a file system path or a logical project name?**  
   - File system path (e.g. `/Users/openclaw/Projects/Revenue Generation/`) — agent can read files directly
   - Logical name (e.g. `revenue-generation`) — needs a mapping table
   - **Recommendation:** File system path. Agent has file access and can read STATUS.md etc.

3. **How should topics without project folders (General, Optimisation, Openclaw) work?**  
   - They get a minimal context header: just the topic name
   - `[SESSION-CONTEXT]\nTopic: General`
   - The agent uses the topic name for memory/wiki search
   - This is still better than a blank slate

4. **Should the "Active Focus" field be editable by the user or auto-populated?**  
   - Start with manual entry in topic settings
   - Future: agent could update it after significant conversations (requires a feedback mechanism)

5. **Should resume context be automatic or triggered by a button?**  
   - **Recommendation:** Start with a button ("Resume" / "📍 Pick up where we left off")
   - Auto-resume can be a per-topic setting later
   - Automatic messages on topic selection could feel jarring

---

## Success Criteria

| Criterion | How to Verify |
|-----------|---------------|
| New topic sends context header on first message | Create a topic named "Test" with project path, send first message, verify `[SESSION-CONTEXT]` prefix in gateway session |
| Existing session does NOT send context header | Continue conversation in established topic, verify no `[SESSION-CONTEXT]` prefix |
| Auto-reset does NOT double-inject context | Trigger auto-reset, verify single context header |
| App doesn't crash on migration | Install over existing BeeChat with v6 DB, launch successfully |
| Topic without project path sends minimal context | Create topic without project path, send message, verify `[SESSION-CONTEXT]\nTopic: General` |
| Feature flag disables injection | Set flag to false, verify no context header is prepended |
| Resume button sends orientation request | Click "Resume" on a topic, verify agent responds with context summary |

---

## Appendix: Current Session Flow (Reference)

```
User opens BeeChat
  → Selects topic in sidebar
  → TopicViewModel provides sessionKey
  → SyncBridge.sendMessage(sessionKey, text)
    → If usage > threshold: auto-reset, prepend history
    → Else: send text as-is
  → Gateway processes chat.send
  → Agent responds
  → EventRouter routes chat events back
  → UI displays response
```

**Proposed flow (Phase 1):**

```
User opens BeeChat
  → Selects topic in sidebar
  → TopicViewModel provides sessionKey AND topic metadata
  → SyncBridge.sendMessage(sessionKey, text, topic: topic)
    → If justAutoReset: send with auto-reset context only (no double injection)
    → Else if needsContextInjection(topic): prepend context header, send
    → Else: send text as-is
  → Gateway processes chat.send
  → Agent responds (with topic awareness)
  → EventRouter routes chat events back
  → UI displays response
```

**Proposed flow (Phase 2, resume):**

```
User selects topic in sidebar
  → UI checks: is this topic's session fresh/reset?
  → If yes AND autoContext enabled: show "Resume" button
  → User clicks "Resume" (or auto if per-topic setting)
  → SyncBridge.sendResumeContext(sessionKey, topic)
  → Agent reads project STATUS.md, does LCM search, responds with orientation
  → UI displays orientation response as first thing user sees
```

---

*End of spec. Feedback from Q (implementation), Mel (UI/UX), and Kieran (review) requested before proceeding.*