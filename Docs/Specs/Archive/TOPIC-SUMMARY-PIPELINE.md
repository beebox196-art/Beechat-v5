# Spec: Topic Summary Pipeline (Phase 2 — Manual Save, Intelligent Topics)

**Created:** 2026-05-31T19:55:00+01:00
**Revised:** 2026-05-31T20:35:00+01:00 (manual-only scope, all review issues resolved)
**Author:** Bee (drafted from conversation with Adam)
**Status:** DRAFT v2 — pending final team confidence check
**Parent:** `TOPIC-PROJECT-CONTINUITY.md` (Phase 1)
**Target:** BeeChat-v5 (macOS app) — iOS deferred

---

## 1. Problem

Phase 1 solved the read side: project files get injected into the agent context when a project-bound topic is active. But the write side is still missing. Conversations produce durable knowledge — decisions, corrections, project state changes — but that knowledge dies when the conversation scrolls past or the session resets.

Right now, capturing durable knowledge requires Adam to manually ask the agent to write things up. That's friction. If the agent could automatically promote durable content from conversations into the project files and memory layer, the system becomes self-maintaining.

**Phase 2 scope (revised):** Manual "Save Topic Summary" trigger only. No compaction hook, no quiet-period timer in this phase. Those are Phase 2.5 additions once the pipeline is validated. This reduces risk, removes upstream dependencies, and delivers 80% of the value in ~4 hours.

---

## 2. Goals

1. **Topic re-entry is seamless.** When Adam returns to a topic, the agent is already up to speed on what was last discussed, what's pending, and what decisions were made.
2. **Durable knowledge flows automatically.** Decisions, corrections, and project state changes discovered in conversations are promoted to the correct files without manual intervention (beyond the initial Save action).
3. **No new memory structures.** The pipeline writes to existing project file conventions. The agent reads these on next context injection.
4. **Minimal UI surface.** One context menu item, one transient status, one extra row in EditTopicSheet. No permanent sidebar badges.

---

## 3. Design

### 3.1 Trigger: Manual "Save Topic Summary" only

Right-click a topic in the sidebar → "Save Topic Summary". That's the only trigger in Phase 2.

**Why manual first:**
- Adam knows when something important happened — he controls the timing
- No upstream OpenClaw dependencies (compaction hook doesn't exist)
- No subagent spawning from the Mac app (architecture conflict)
- No quiet-period timer complexity (duplicate summaries, race conditions)
- Validates the extraction + write pipeline before automating it

**Future (Phase 2.5):** Compaction hook (when OpenClaw exposes it), quiet-period timer, batch extraction for mobile.

### 3.2 Summary Format

Each topic gets a lightweight summary file:

- **Project-bound topic:** `projectPath/docs/topics/{topic-id}-summary.md`
- **Unbound topic (no project):** `workspacePath/docs/topics/unbound/{topic-id}-summary.md`

```markdown
# Topic: [topic name]
**Last updated:** YYYY-MM-DD HH:mm
**Project:** [project name] (or "None — general topic")
**Status:** active | paused | completed

## Last State
[Brief description of what was being worked on, what's pending, any blockers]

## Decisions
- [YYYY-MM-DD] Decision text
- [YYYY-MM-DD] Decision text

## Corrections
- [YYYY-MM-DD] Correction text

## Open Questions
- [Open question text]

## Recent Activity
- [YYYY-MM-DD] Brief activity summary
```

**Size cap:** 8KB total. If exceeded, oldest entries in "Recent Activity" are trimmed first, then "Corrections", then "Decisions" (keeping at least the last 5). "Last State" is always replaced, never accumulated.

**Human-editable:** Adam can open and edit the summary file directly at any time. The format is plain markdown.

### 3.3 Extraction: Local via `chat.send`, parse in Swift

The Mac app does extraction locally — no subagent spawning, no gateway changes.

**Flow:**
1. User clicks "Save Topic Summary"
2. `TopicSummaryExtractor` reads the topic's recent messages from local SQLite (last 50 messages, or since last save)
3. Constructs an extraction prompt and sends it via `chat.send` to the topic's session
4. The agent returns structured JSON output
5. Swift parses the JSON response
6. `TopicSummaryWriter` merges the parsed data into the summary file

**Extraction prompt:**
```
Read the recent conversation messages for topic "{topic-name}" (project: {project-name or "none"}).

Return a JSON object with these keys:
- "state": string — brief description of what is currently being worked on and what is pending
- "decisions": array of strings — explicit agreements reached on specific choices, directions, or approaches
- "corrections": array of strings — things identified as wrong where the fix was confirmed
- "open_questions": array of strings — topics discussed but left unresolved with intent to revisit

Rules:
- ONLY extract items that are about the project or the work being done in this topic
- Require a specific, actionable outcome — not just "let's do something"
- Do NOT extract: social plans, tool preferences, debugging attempts that didn't converge, brainstorming that didn't reach a conclusion, casual discussion
- Return empty arrays for keys where nothing durable was found
- If nothing durable was found at all, return all empty arrays and empty state

Output ONLY the JSON object, no markdown formatting, no explanation.
```

**Expected response:**
```json
{
  "state": "Implementing TopicSummaryWriter, testing merge logic",
  "decisions": ["Use SQLite for local cache", "Cap summary files at 8KB"],
  "corrections": ["Path validation was rejecting workspace root"],
  "open_questions": ["How to handle topic re-binding to a new project"]
}
```

### 3.4 Concurrency Model

Serial queue per topic. One summary write at a time per topic.

If the user clicks "Save Topic Summary" twice rapidly:
- The UI disables the menu item while a save is in progress
- `TopicSummaryWriter` uses `.atomic` file writes (write to temp file, then rename)
- On merge: read current file, apply new data, write atomically. If the file changed between read and write, retry once.

This eliminates silent data loss from concurrent writes without needing a full mutex system.

### 3.5 Merge Semantics (per-section rules)

| Section | Merge Rule |
|---|---|
| **Last State** | Replace entirely (always reflects current state) |
| **Decisions** | Append new, dedup by normalised key (lowercase, trimmed, first 50 chars). Keep last 5 minimum. |
| **Corrections** | Append new, exact-string dedup. Keep all. |
| **Open Questions** | Append new, exact-string dedup. Cap at 5. If a question appears answered in the new extraction, move it to a "Resolved" note in the state section. |
| **Recent Activity** | Append timestamped entry, cap at last 10 entries. |

### 3.6 Context Injection on Topic Re-Entry

When Adam selects a topic in the sidebar, before the first message:

1. Check for existing summary file at `projectPath/docs/topics/{topic-id}-summary.md` (project-bound) or `workspacePath/docs/topics/unbound/{topic-id}-summary.md` (unbound)
2. If found: inject its content into the context header as `[TOPIC-SUMMARY]` section
3. If not found: proceed with Phase 1 context only

The `[TOPIC-SUMMARY]` section is appended after `[PROJECT-CONTEXT]` and before any auto-reset context. Its size is counted in the Phase 1 50KB combined context budget guard — if total exceeds 50KB, trim summary first (most likely to be stale), then project context.

### 3.7 Path Validation

`TopicSummaryWriter` validates paths against a configurable allowed-roots set:
- `/Users/openclaw/Projects/` — for project-bound topics
- `/Users/openclaw/.openclaw/workspace/` — for unbound topics

Symlink resolution checks the full path (not just leaf component), matching Phase 1's C1 fix.

---

## 4. Architecture

### 4.1 Component: TopicSummaryWriter

**File:** `Sources/BeeChatSyncBridge/Utilities/TopicSummaryWriter.swift`

```swift
public enum TopicSummaryWriter {
    
    /// Maximum summary file size in bytes (8KB)
    private static let maxBytes = 8192
    
    /// Allowed root directories for summary files
    private static let allowedRoots = [
        "/Users/openclaw/Projects/",
        "/Users/openclaw/.openclaw/workspace/",
    ]
    
    /// Writes (or merges) a topic summary.
    /// - Parameters:
    ///   - topicId: The topic's unique identifier
    ///   - topicName: The topic's display name
    ///   - projectPath: The project's root path, or nil for unbound topics
    ///   - workspacePath: The workspace root (used when projectPath is nil)
    ///   - extracted: Structured extraction result
    /// - Returns: The path to the written file, or nil on failure
    public static func write(
        topicId: String,
        topicName: String,
        projectPath: String?,
        workspacePath: String,
        extracted: TopicSummaryExtracted
    ) -> String?
    
    /// Reads an existing summary for a topic, if one exists.
    /// - Returns: The summary content, or nil if no summary file exists
    public static func read(topicId: String, projectPath: String?, workspacePath: String) -> String?
}

/// Structured extraction result from the LLM
public struct TopicSummaryExtracted: Codable {
    public var state: String
    public var decisions: [String]
    public var corrections: [String]
    public var openQuestions: [String]
    
    public var isEmpty: Bool {
        state.isEmpty && decisions.isEmpty && corrections.isEmpty && openQuestions.isEmpty
    }
}
```

**Key behaviors:**
- Determines write path: project-bound → `projectPath/docs/topics/`, unbound → `workspacePath/docs/topics/unbound/`
- Creates directory if it doesn't exist
- Reads existing summary, merges per Section 3.5 rules
- Writes atomically (temp file + rename)
- Enforces 8KB cap by trimming oldest entries
- Path validation against allowed-roots set with full symlink resolution
- Synchronous, non-throwing, safe inside an actor

### 4.2 Component: TopicSummaryExtractor

**File:** `Sources/BeeChatSyncBridge/Utilities/TopicSummaryExtractor.swift`

```swift
public enum TopicSummaryExtractor {
    
    /// Extracts durable items from a topic's recent messages via a local chat.send call.
    /// - Parameters:
    ///   - topicId: The topic's unique identifier
    ///   - topicName: The topic's display name
    ///   - projectPath: The project's root path, or nil for unbound topics
    ///   - bridge: The SyncBridge instance for chat.send
    /// - Returns: The extraction result, or nil if the call failed or nothing durable was found
    public static func extract(
        topicId: String,
        topicName: String,
        projectPath: String?,
        bridge: SyncBridge
    ) async -> TopicSummaryExtracted?
}
```

**Flow:**
1. Read last 50 messages from the topic's local SQLite (or since last save timestamp)
2. Format as a conversation transcript
3. Send via `bridge.chatSend()` with the extraction prompt (Section 3.3) as a system-level instruction
4. Parse the JSON response into `TopicSummaryExtracted`
5. Return nil if response is empty or unparseable

**Note:** This uses the existing `chat.send` RPC — no new gateway methods, no subagent spawning. The extraction runs within the topic's own session context.

### 4.3 Trigger: "Save Topic Summary" UI

**File:** `Sources/App/UI/Components/SessionRow.swift`

Add to the existing context menu, positioned as:
1. `Edit Topic`
2. `Save Topic Summary` ← NEW
3. `Reset Session`
4. divider
5. `Delete Topic`

```swift
Button {
    Task { await topicViewModel.saveTopicSummary() }
} disabled: isSaving
label: {
    Label("Save Topic Summary", systemImage: "doc.badge.plus")
}
```

**Transient status (inline, not toast):**
- In-progress: small spinner + `Saving topic...` (VoiceOver: "Saving topic summary")
- Success: `Topic saved` for 2 seconds (VoiceOver: "Topic summary saved")
- Empty result: `No changes to save` for 2 seconds (VoiceOver: "No durable topic changes found")
- Failure: `Could not save` for 4 seconds with amber indicator + tooltip with reason (VoiceOver: "Topic summary could not be saved: [reason]"). **The failure reason persists in the row's `.help` and accessibility help text until the next retry, a successful save, the topic selection changes, or the user navigates away.** This ensures the error remains discoverable even after the transient indicator fades.
- Menu item disabled while save is in progress. Accessibility hint: "Save already in progress"

**File:** `Sources/App/UI/ViewModels/TopicViewModel.swift`

Add `saveTopicSummary()` async method that:
1. Sets `isSaving = true`
2. Calls `TopicSummaryExtractor.extract()`
3. If result is non-empty, calls `TopicSummaryWriter.write()`
4. Updates status state
5. Sets `isSaving = false`

### 4.4 Phase 1 Integration

**`ProjectContextReader.swift` update:** Add optional `topicId` parameter. When provided, also read `docs/topics/{topicId}-summary.md` from the project path (or unbound fallback). Return this as a separate field in `ProjectContextReadResult`.

**`buildContextHeader` update:** After `[PROJECT-CONTEXT]`, add `[TOPIC-SUMMARY]` section if a summary file exists. Include its size in the 50KB combined context budget guard.

**`EditTopicSheet.swift` update:** In the existing "Context files" section, add a "Topic summary" row with status: `found`, `missing`, `saving`, or `error`. Show last-updated time and approximate size when found.

---

## 5. Files to Modify

| File | Change |
|---|---|
| `Sources/BeeChatSyncBridge/Utilities/TopicSummaryWriter.swift` | **NEW** — file I/O, merge logic, path validation, 8KB cap |
| `Sources/BeeChatSyncBridge/Utilities/TopicSummaryExtractor.swift` | **NEW** — prompt construction, chat.send call, JSON parsing |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Add `triggerTopicSummary(topicId:)` async method; upgrade `buildContextHeader` with `[TOPIC-SUMMARY]` |
| `Sources/BeeChatSyncBridge/Utilities/ProjectContextReader.swift` | Add optional `topicId` parameter; read summary file when available |
| `Sources/App/UI/ViewModels/TopicViewModel.swift` | Add `saveTopicSummary()` async method + `isSaving` state |
| `Sources/App/UI/Components/SessionRow.swift` | Add "Save Topic Summary" context menu item + transient status |
| `Sources/App/UI/Components/EditTopicSheet.swift` | Add "Topic summary" row to existing Context files section |

---

## 6. Data Flow

```
User right-clicks topic → "Save Topic Summary"
       │
       ▼
TopicSummaryExtractor.extract()
       │  Reads last 50 messages from local SQLite
       │  Sends via chat.send with extraction prompt
       │  Parses JSON response
       ▼
TopicSummaryExtracted (decisions, corrections, state, open questions)
       │
       ▼
TopicSummaryWriter.write()
       │  Reads existing summary (if any)
       │  Merges per-section rules
       │  Enforces 8KB cap
       │  Writes atomically
       ▼
projectPath/docs/topics/{topic-id}-summary.md
(or workspacePath/docs/topics/unbound/ for unbound topics)
       │
       │  Next topic re-entry:
       │  buildContextHeader reads summary → injects as [TOPIC-SUMMARY]
       ▼
Agent enters topic with full context
```

---

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Extraction prompt false positive | Medium | Low | Narrow prompt with negative examples. Normalised dedup on merge. |
| Extraction prompt false negative | Medium | Low | Manual retry available. Not catastrophic — just delayed capture. |
| Concurrent saves (user double-clicks) | Low | Medium | UI disables during save. Atomic write + retry on merge conflict. |
| Summary file exceeds 8KB | Low | Medium | Cap enforced on every write. Oldest entries trimmed first. |
| Path traversal via malformed metadata | Low | High | Full symlink resolution + allowed-roots validation. |
| Context budget collision | Low | Medium | [TOPIC-SUMMARY] included in 50KB combined guard. Trimmed first. |
| Unparseable JSON from extraction | Low | Medium | Graceful fallback: "No changes to save". User can retry. |
| Topic re-binding after summary exists | Low | Low | Summary stays in old project folder. Edge case, manual resolution. |

---

## 8. Verification Checklist

### Unit Tests
- [ ] **TopicSummaryWriter** — Write a summary to a temp directory, verify file exists with correct content
- [ ] **TopicSummaryWriter merge** — Write, then write again with new decisions. Verify existing decisions preserved, new ones appended, no duplicates
- [ ] **TopicSummaryWriter dedup** — Two similar decisions ("Use SQLite" vs "Going with SQLite") — verify normalised dedup prevents duplicates
- [ ] **TopicSummaryWriter 8KB cap** — Write exceeding 8KB, verify oldest entries trimmed
- [ ] **TopicSummaryWriter path validation** — Reject paths outside allowed roots
- [ ] **TopicSummaryWriter symlink escape** — Symlink inside allowed root pointing outside — verify rejection (full path resolution)
- [ ] **TopicSummaryWriter unbound path** — Nil projectPath writes to workspace unbound directory
- [ ] **JSON parsing** — Valid JSON → TopicSummaryExtracted. Invalid JSON → nil.
- [ ] **Empty result** — All-empty JSON → nil returned, UI shows "No changes to save"
- [ ] **buildContextHeader with summary** — Topic with summary file → `[TOPIC-SUMMARY]` present in header
- [ ] **buildContextHeader without summary** — No summary file → `[TOPIC-SUMMARY]` absent

### Manual Tests
- [ ] **Right-click menu** — "Save Topic Summary" appears after "Edit Topic" and before "Reset Session"
- [ ] **Save flow** — Click save → spinner → "Topic saved" → summary file created in correct location
- [ ] **Empty result** — Topic with no durable content → "No changes to save"
- [ ] **Failed save** — Simulate write failure → amber indicator + tooltip + VoiceOver announcement
- [ ] **Disabled during save** — Menu item greyed out while save in progress
- [ ] **Topic re-entry** — After saving, close and re-open topic. Agent responds with awareness of prior decisions
- [ ] **EditTopicSheet** — "Topic summary" row shows found/missing/saving/error state
- [ ] **Unbound topic** — Topic with no project binding → summary written to workspace unbound directory, no error
- [ ] **Context injection** — Summary file content appears in `[TOPIC-SUMMARY]` section on next send

---

## 9. Implementation Order

1. **TopicSummaryWriter** — Core file I/O with merge logic, 8KB cap, path validation. Pure Swift, no dependencies. ~1 hour.
2. **TopicSummaryExtractor** — Prompt construction, chat.send call, JSON parsing. ~1 hour.
3. **buildContextHeader upgrade** — Add `[TOPIC-SUMMARY]` injection. Reuses Phase 1 infrastructure. ~30 min.
4. **ProjectContextReader update** — Read summary files when topicId available. ~30 min.
5. **TopicViewModel.saveTopicSummary()** — Async method with isSaving state. ~30 min.
6. **SessionRow context menu** — Menu item + transient status + VoiceOver. ~1 hour.
7. **EditTopicSheet update** — Topic summary row in Context files section. ~30 min.
8. **Tests** — Unit tests + manual verification. ~1 hour.

**Estimated effort:** 4-5 hours total. Zero gateway changes. Zero upstream dependencies.

---

## 10. Deferred (Phase 2.5)

These were in the original draft but moved out of Phase 2 scope:

| Item | Reason deferred |
|---|---|
| LCM compaction hook trigger | OpenClaw doesn't expose a compaction event. Future upgrade. |
| Quiet-period timer (2h scan) | Adds complexity (duplicate summaries, race conditions). Validate manual first. |
| Batch extraction for mobile | Mobile context menu UX is different. Validate desktop flow first. |
| iOS delegation (Save on Mac) | Needs new RPC method. Defer until desktop pipeline validated. |

---

## 11. Why This Approach

The simplification is the strength. The original spec tried to do too much: compaction hooks, subagent spawning, three triggers. Q, Kieran, and Mel all independently recommended starting with manual-only.

This version:
- **No upstream dependencies** — everything is app-side Swift
- **No gateway protocol changes** — uses existing `chat.send`
- **No subagent spawning from the Mac** — extraction is a local chat call
- **Validates the core pipeline** — if manual save works well, automation is the next natural step
- **4-5 hours of work** — deliverable in a single session
- **Builds cleanly on Phase 1** — extends `ProjectContextReader` and `buildContextHeader`, doesn't rewrite them

The extraction prompt is narrow and structured (JSON output), reducing false positives. The merge logic is explicit per-section. The UI is minimal: one menu item, one transient status, one extra row. Nothing permanent in the sidebar.
