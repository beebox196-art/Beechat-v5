# Implementation Spec: Topic-Project Binding — Read STATUS.md + Write Activity Back

**Date:** 2026-05-21  
**Author:** Bee (coordinator)  
**Status:** v0.3.1 — effort correction, pre-build sandbox check  
**Reviewers:** Kieran (conditional approve), Q (build with caution)  

---

## Changelog

### v0.3 (2026-05-21) — Simplified binding + project creation
- **New topic creation unchanged:** No project picker at creation time. Just a name, like now.
- **Project binding is post-creation only:** Done via topic settings (Edit Topic sheet) after the topic exists.
- **Topics without projects:** Work exactly as today. No generic coverall project needed. Completely optional.
- **Create project from topic settings:** If the project folder doesn't exist yet, user can create it directly from the topic settings sheet. Uses the existing `/Projects/_template/` to scaffold the folder.
- **Effort reduced:** New Topic UI changes dropped to zero (no picker needed at creation). Edit Topic UI is the only new UI.

### v0.2 (2026-05-21) — Post-review corrections
- **DB approach:** Changed from `ALTER TABLE` new column to using existing `metadataJSON` column (zero migration, zero risk) — per Q's review
- **Context injection:** Changed from "metadata in chat.send" to `[PROJECT-CONTEXT]` message prefix via `buildContextHeader` — per Q's review, consistent with existing `[TOPIC-CONTEXT]` pattern
- **OpenClaw system prompt:** Separated from BeeChat scope into its own workstream — not a BeeChat code change, requires separate agent config — per Q's review
- **Edit Topic UI:** Added to scope honestly — no existing edit UI, needs building from scratch (3-4 hrs) — per Q's review
- **Path validation:** Added `projectPath` validation (must start with `/Users/openclaw/Projects/`, directory must exist) — per Kieran's review
- **Write trigger:** Changed from vague "significant progress" to concrete session-end hook — per Kieran's review
- **ACTIVITY.md bootstrapping:** Added — create file with header if it doesn't exist — per Kieran's review
- **Mobile SyncBridge:** Clarified — `projectPath` flows through same SyncBridge, file reading is server-side — per Kieran's review
- **Context budget:** Added — read only recent section of STATUS.md, not entire file — per Kieran's review
- **ACTIVITY.md read limit:** Added — read only recent 10 entries on reset, not full file — per Kieran's review
- **Effort estimate:** Updated from 8-10hrs to 15-18hrs — per Q's review
- **Migration:** Changed from script to manual — 6 rows, not worth a script — per both reviewers

---

## 1. Overview

### 1.1 Problem

Two related issues:

1. **Context drift** — AI in a BeeChat topic loses focus over time. At 20% usage the AI forgets what project the topic belongs to, asks "What app are we talking about?", and drifts off-topic. This is separate from the session reset problem (which occurs at 80% usage).

2. **Activity capture gap** — Decisions, progress, and outcomes made in BeeChat topics don't automatically feed back into the project folder. The project STATUS.md is maintained manually, which means it's often stale.

### 1.2 Root Cause

- Topics have a name ("Beechat Mobile") but no link to their project folder (`/Projects/BeeChat-Mobile/`)
- The AI has no instruction to read the project STATUS.md at session start
- There's no mechanism to write activity summaries back to the project folder during or after a session

### 1.3 Proposed Solution

**Topic-Project Binding** — a lightweight two-way link:

- **Read path:** When a topic session starts (or resets), the AI receives a `[PROJECT-CONTEXT]` message prefix pointing to the project folder. The AI reads STATUS.md and key files to establish context.
- **Write path:** When a session ends or significant activity occurs, the AI appends a dated entry to ACTIVITY.md in the project folder.

This is NOT a new database system or complex framework. It's a metadata field in an existing column, a message prefix convention, and an Edit Topic sheet.

---

## 2. Design

### 2.1 Topic Metadata: `projectPath` in `metadataJSON`

Store `projectPath` inside the existing `metadataJSON` column on the `topics` table:

```json
{
  "projectPath": "/Users/openclaw/Projects/BeeChat-Mobile/"
}
```

**Why `metadataJSON` instead of a new column (v0.1 change):**
- Zero migration needed — the column already exists and stores JSON
- Zero risk to existing `SELECT t.*` queries that GRDB decodes into `Topic`
- Naturally extensible — future metadata (color, icon) fits in the same JSON
- Avoids adding a migration (currently at Migration012) for a single optional field

**Access pattern:**
```swift
struct TopicMetadata: Codable {
    var projectPath: String?
}

extension Topic {
    var projectPath: String? {
        guard let json = metadataJSON,
              let data = json.data(using: .utf8),
              let meta = try? JSONDecoder().decode(TopicMetadata.self, from: data) else { return nil }
        return meta.projectPath
    }
    
    mutating func setProjectPath(_ path: String?) {
        var meta = TopicMetadata()
        if let json = metadataJSON,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TopicMetadata.self, from: data) {
            meta = decoded
        }
        meta.projectPath = path
        metadataJSON = String(data: (try? JSONEncoder().encode(meta)) ?? Data(), encoding: .utf8)
    }
}
```

**Path validation (per Kieran's review):**
- `projectPath` MUST start with `/Users/openclaw/Projects/`
- **Resolve symlinks before checking prefix** — use `FileManager.destinationOfSymbolicLink(atPath:)` to resolve the path first, then check `hasPrefix`. This prevents path traversal attacks.
- The directory MUST exist on disk at the time of setting
- Reject invalid paths with a user-facing error
- Validate on set, not on every read (directories can move — handle gracefully at read time with a warning)
- **Create flow exception:** When using "Create New Project," the directory is created first, then validated — so it passes the existence check.
- **Name collision:** If creating a project with a name that already exists in `/Users/openclaw/Projects/`, show a clear error and do NOT overwrite the existing folder.

**How to set it:**
- **Not at topic creation time** — new topics are created exactly as now (just a name)
- **After creation, via topic settings** — the Edit Topic sheet lets you bind/unbind a project
- **Create new project from settings** — if the project folder doesn't exist yet, you can create it directly from the Edit Topic sheet (scaffolded from `/Projects/_template/`)
- Existing topics get a one-time manual mapping (6 rows, see section 3.3)

**Mapping (initial):**

| Topic Name | Project Path |
|-------------|-------------|
| Beechat | `/Users/openclaw/Projects/BeeChat-v5/` |
| Beechat Mobile | `/Users/openclaw/Projects/BeeChat-Mobile/` |
| SolarDashboard | `/Users/openclaw/Projects/SolarDashboard/` |
| Topcon-Eval | `/Users/openclaw/Projects/Topcon-Eval/` |
| MissionControl | `/Users/openclaw/Projects/MissionControl/` |
| Revenue Generation | `/Users/openclaw/Projects/Revenue Generation/` |

Topics without a project match simply don't have the field — no binding, no read/write.

### 2.2 Read Path: `[PROJECT-CONTEXT]` Message Prefix

**When:** At session start and after session reset.

**How it works (per Q's review):**

BeeChat already has a `buildContextHeader(topic:)` method that prefixes messages with `[TOPIC-CONTEXT]`. We extend this pattern:

```swift
// In SyncBridge.buildContextHeader(topic:)
private func buildContextHeader(for topic: Topic) -> String {
    var header = "[TOPIC-CONTEXT] Topic: \(topic.name)"
    if let projectPath = topic.projectPath {
        header += "\n[PROJECT-CONTEXT] Project: \(projectPath)"
        header += "\nRead \(projectPath)STATUS.md for project context."
        header += "\nRead \(projectPath)decisions.md and \(projectPath)corrections.md if they exist."
    }
    return header
}
```

This is **Option A from Q's review** — prefix the message text. It:
- Requires zero gateway API changes
- Follows the existing `[TOPIC-CONTEXT]` pattern
- Costs zero extra RPC calls (unlike `chat.inject`)
- The AI sees the project path as part of the user message and reads the files itself

**What the AI reads:**
1. `STATUS.md` — project status, current state, known issues, next steps
2. `decisions.md` — if it exists, key decisions made
3. `corrections.md` — if it exists, known mistakes to avoid

**Context budget (per Kieran's review):**
- STATUS.md: Read only the most recent section (up to 2000 chars). If the file is large, truncate at the last `---` boundary before 2000 chars.
- ACTIVITY.md on reset: Read only the most recent 10 entries (see section 2.4).
- Total context injection budget: ~3000 chars per session start.

**Graceful failure:**
- If `projectPath` points to a directory that no longer exists, the AI proceeds without project context. No error, no hang.
- If STATUS.md doesn't exist, the AI proceeds without it. No error.
- If decisions.md or corrections.md don't exist, skip them. (Already in spec as "if they exist")

### 2.3 Write Path: Activity Logging

**When:** At session end (primary trigger) and after significant progress (supplementary).

**Per Kieran's review:** "When significant progress is made" is too vague. The primary trigger should be a concrete event:

1. **Session end hook:** When the agent yields (end of a significant session), it appends to ACTIVITY.md. This is a system-level instruction, not a vague "when you feel like it."
2. **Supplementary writes:** The AI may also write during the session for major decisions. This is optional and convention-based.

**What gets written:**
- A dated entry appended to `ACTIVITY.md` in the project folder
- Format: `### YYYY-MM-DD — One-line summary` followed by 2-3 lines of detail

**Example ACTIVITY.md entry:**
```markdown
### 2026-05-21 — Session reset redesign built and deployed
- Replaced pendingResetContext raw dump with concise summary via chat.inject
- Auto-reset now waits for stream completion before resetting
- Added waitForStreamCompletion with 30s timeout fallback
- Both reviewers approved spec v0.7 before implementation
```

**Bootstrapping (per Kieran's review):**
- If `ACTIVITY.md` doesn't exist, the AI creates it with a header:
  ```markdown
  # Activity Log

  Project: [project name]
  Auto-generated. Entries are appended by the AI at session end.

  ```
- This ensures there's always a file to append to.

**How it's triggered:**
- The `[PROJECT-CONTEXT]` message prefix includes the instruction: *"When this session ends or significant progress is made, append a dated entry to {projectPath}ACTIVITY.md using the format: ### YYYY-MM-DD — One-line summary"*
- This is a convention enforced by the message prefix, not a code change in BeeChat

**Relationship to STATUS.md:**
- ACTIVITY.md is the rolling log (append-only)
- STATUS.md is the curated overview (updated periodically, not every session)
- The AI updates STATUS.md only when explicitly asked or at natural milestones
- This matches the existing MEMORY.md pattern — daily raw log vs curated long-term memory

**Write path reliability (per Kieran's review):**
- Acknowledged: the AI is a probabilistic system and will sometimes forget to write
- Mitigation: the session-end instruction is a concrete trigger, not a vague "when significant"
- If the AI forgets: ACTIVITY.md goes stale. This is a nuisance, not a crisis. Stale activity log is better than no activity log.
- Future improvement: a periodic "review ACTIVITY.md and update STATUS.md" reminder in the system prompt

### 2.4 Session Reset Integration

When a session resets (using the summary injection from the reset redesign):

1. **Summary injection** fires as before (200-400 chars, concise recap)
2. **`[PROJECT-CONTEXT]` message prefix** is automatically included in the first message after reset (because `projectPath` is part of the topic metadata)
3. **The AI reads:** STATUS.md (recent section only, up to 2000 chars) + recent 10 entries from ACTIVITY.md
4. This gives the AI both the conversation summary AND the project context — no drift possible

**In `formatSessionSummary()`:**
```swift
if let projectPath = topic.projectPath {
    summary += "\n[PROJECT-CONTEXT] Project: \(projectPath)"
    summary += "\nRead \(projectPath)STATUS.md and recent entries in \(projectPath)ACTIVITY.md for project context."
}
```

### 2.5 Mobile SyncBridge Behaviour (per Kieran's review)

- `projectPath` is stored in the topic's `metadataJSON` in the local SQLite database
- Both desktop and mobile apps read/write the same database field
- The `[PROJECT-CONTEXT]` message prefix is included in messages sent from both platforms
- File reading happens on the OpenClaw server side, not on the mobile device — the mobile app doesn't need filesystem access to project folders
- **Mobile UI:** Show a small project badge (just the project name, e.g. "BeeChat Mobile") in the topic list row. Not the full path. Settings-only for editing.

---

## 3. Implementation

### 3.1 BeeChat Code Changes

#### 3.1.1 Topic Model (NO migration needed)

Add `projectPath` as a computed property using the existing `metadataJSON` column:

```swift
// In Topic model — no schema change, no migration
struct TopicMetadata: Codable {
    var projectPath: String?
}

extension Topic {
    var projectPath: String? {
        guard let json = metadataJSON,
              let data = json.data(using: .utf8),
              let meta = try? JSONDecoder().decode(TopicMetadata.self, from: data) else { return nil }
        return meta.projectPath
    }
    
    mutating func setProjectPath(_ path: String?) throws {
        // Validate path
        if let path = path {
            guard path.hasPrefix("/Users/openclaw/Projects/") else {
                throw TopicError.invalidProjectPath("Path must start with /Users/openclaw/Projects/")
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw TopicError.invalidProjectPath("Directory does not exist: \(path)")
            }
        }
        
        var meta = TopicMetadata()
        if let json = metadataJSON,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TopicMetadata.self, from: data) {
            meta = decoded
        }
        meta.projectPath = path
        metadataJSON = String(data: (try? JSONEncoder().encode(meta)) ?? Data(), encoding: .utf8)
    }
}
```

**No new column. No migration. No SQL audit.**

#### 3.1.2 Topic Creation UI — NO CHANGES

**New topic creation is unchanged.** No project picker, no extra fields. Just create the topic with a name, exactly as now. Project binding happens later via topic settings.

This is the simplest possible approach — zero extra UI at creation time, zero extra steps for topics that don't need a project binding.

Estimated effort: **0 hours** (no changes)

#### 3.1.3 Topic Edit UI — Project Binding & Creation

There is currently no "Edit Topic" UI in BeeChat. This needs to be created from scratch:

- New sheet/modal for topic editing
- Triggered from context menu on sidebar topic row
- Contains: topic name field + project binding section
- Project binding section has:
  - **Dropdown of known projects** (scanned from `/Users/openclaw/Projects/` subdirectories)
  - **"Create New Project" button** — scaffolds a new project folder from `/Projects/_template/` and binds to it
  - **"Remove binding" button** — sets projectPath to nil
- Path validation: must start with `/Users/openclaw/Projects/`, directory must exist
- Uses existing `ThemeManager` patterns from `MainWindow.swift`

**"Create New Project" flow:**
1. User clicks "Create New Project" in Edit Topic sheet
2. A text field appears for the project name (e.g. "My New Project")
3. On confirm:
   - **Name collision check:** If `/Users/openclaw/Projects/My New Project/` already exists, show a clear error ("A project with this name already exists. Choose a different name or select it from the dropdown.") — do NOT overwrite
   - Create `/Users/openclaw/Projects/My New Project/` directory
   - Copy `/Users/openclaw/Projects/_template/` contents into it (STATUS.md, Docs/, README.md, DEBUG.md)
   - **Template placeholder replacement:** Replace `[Project Name]` with the actual project name and `YYYY-MM-DD` with today's date in all copied files. Filter out `.DS_Store` during copy.
   - Set the topic's `projectPath` to the new directory
   - The AI reads the new STATUS.md on the next message
4. This handles the case where the topic exists before the project folder does

**Validation order:**
- **Create flow:** Create directory → validate (check starts with `/Users/openclaw/Projects/` and exists) → set path. The newly-created directory passes validation because it now exists.
- **Manual entry (dropdown):** Validate → set path. The directory must already exist.
- **Symlink resolution:** Before the `hasPrefix` check, resolve any symlinks in the path using `FileManager.destinationOfSymbolicLink(atPath:)`. This prevents `../../../etc/` path traversal attacks. Only validate the resolved path.

Estimated effort: 4-5 hours (edit UI + project creation flow)

#### 3.1.4 SyncBridge Message Prefix

Extend `buildContextHeader(topic:)` to include `[PROJECT-CONTEXT]`:

```swift
private func buildContextHeader(for topic: Topic) -> String {
    var header = "[TOPIC-CONTEXT] Topic: \(topic.name)"
    if let projectPath = topic.projectPath {
        header += "\n[PROJECT-CONTEXT] Project: \(projectPath)"
        header += "\nRead \(projectPath)STATUS.md for project context."
        header += "\nRead \(projectPath)decisions.md and \(projectPath)corrections.md if they exist."
        header += "\nWhen this session ends or significant progress is made, append a dated entry to \(projectPath)ACTIVITY.md."
    }
    return header
}
```

This uses the existing `[TOPIC-CONTEXT]` pattern. **No gateway API changes. No new RPC params. No metadata tunnel.**

#### 3.1.5 Session Summary Enhancement

In `formatSessionSummary()`, append project reference line:

```swift
if let projectPath = topic.projectPath {
    summary += "\n[PROJECT-CONTEXT] Project: \(projectPath)"
    summary += "\nRead \(projectPath)STATUS.md and recent entries in \(projectPath)ACTIVITY.md for project context."
}
```

### 3.2 OpenClaw Agent Configuration (SEPARATE WORKSTREAM)

This is **NOT a BeeChat code change.** The `[PROJECT-CONTEXT]` message prefix tells the AI what to do, but the AI's behavioral convention (read files, write ACTIVITY.md) needs to be reinforced in the agent's instructions.

**Where this lives:**
- The system prompt / AGENTS.md / agent instructions — this is OpenClaw's agent configuration, not the BeeChat app
- This requires its own spec and effort estimate, separate from the BeeChat work

**What needs to change:**
- The agent's instructions need to include: "When you see `[PROJECT-CONTEXT]`, read the project files and follow the activity logging convention"
- This is a config change, not a code change

**Estimated effort:** 1-2 hours to write and test the agent instruction changes (but this is outside BeeChat scope)

### 3.3 Manual Migration for Existing Topics

**No script needed.** Six rows, exact matches only:

1. Open BeeChat database: `sqlite3 "/Users/openclaw/Library/Application Support/BeeChat/BeeChat.sqlite"`
2. For each topic, update the metadataJSON:
   ```sql
   UPDATE topics SET metadataJSON = '{"projectPath":"/Users/openclaw/Projects/BeeChat-v5/"}' WHERE name = 'Beechat';
   UPDATE topics SET metadataJSON = '{"projectPath":"/Users/openclaw/Projects/BeeChat-Mobile/"}' WHERE name = 'Beechat Mobile';
   -- etc.
   ```
3. Verify with: `SELECT name, metadataJSON FROM topics WHERE metadataJSON IS NOT NULL;`

**Note:** If a topic already has `metadataJSON` set, preserve existing fields:
```sql
-- If metadataJSON is already set, merge projectPath in
-- If metadataJSON is NULL, just set it to the new JSON
```

**Unmapped topics:** Leave as NULL. No binding, no context injection, works as before.

---

## 4. What This Is NOT

- **NOT** a new database system or ORM layer
- **NOT** a new database column or migration
- **NOT** an automatic file watcher or real-time sync
- **NOT** replacing AGENTS.md or SOUL.md — this is project-specific context
- **NOT** a gateway API change — uses existing message prefix pattern
- **NOT** a BeeChat code change for the AI's read/write behaviour — that's an OpenClaw agent config
- **NOT** mandatory — topics without a project binding work exactly as before

---

## 5. Testing Checklist

- [ ] New topic created → no project picker, works exactly as before
- [ ] Edit topic → bind to existing project from dropdown → `[PROJECT-CONTEXT]` prefix appears on next message
- [ ] Edit topic → create new project → scaffolds from template, binds, prefix appears
- [ ] Edit topic → remove binding (set to nil) → prefix removed, no stale data
- [ ] Path validation → rejects paths outside `/Users/openclaw/Projects/`
- [ ] Path validation → rejects non-existent directories (except "create new project" flow)
- [ ] Topic with no project → works exactly as today, no fallback, no generic project
- [ ] Session reset with project binding → summary includes `[PROJECT-CONTEXT]` line
- [ ] Session reset without project binding → works as before (just the 200-400 char summary)
- [ ] AI reads STATUS.md after seeing `[PROJECT-CONTEXT]` prefix
- [ ] AI appends to ACTIVITY.md at session end
- [ ] AI creates ACTIVITY.md with header if it doesn't exist
- [ ] Project directory deleted → AI proceeds gracefully without project context
- [ ] Mobile app → project badge shows in topic list
- [ ] Mobile app → SyncBridge includes `[PROJECT-CONTEXT]` in messages
- [ ] Multiple topics bound to same project → both work independently
- [ ] `metadataJSON` with existing data → `projectPath` merges in without overwriting other fields
- [ ] `metadataJSON` NULL → `projectPath` returns nil, no crash

---

## 6. Resolved Open Questions

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Activity log filename | **`ACTIVITY.md`** | Matches ALL-CAPS convention (STATUS.md, MEMORY.md, AGENTS.md) |
| 2 | Who triggers initial read? | **Option A: auto-read at session start** | Context drift at 20% means the AI needs context from the first message. Token cost is small. |
| 3 | Auto-update STATUS.md vs manual | **Proactive at milestones with confirmation** | AI proposes update, Adam confirms. Not full auto. |
| 4 | Topic-project matching | **Exact match only** | Fuzzy matching risks wrong bindings. Manual for mismatches. |
| 5 | projectPath in UI | **Settings + mobile badge** | Settings for editing. Small project name badge on mobile for visual confirmation. |
| 6 | DB approach | **metadataJSON** (no new column) | Zero migration, zero risk, naturally extensible. |
| 7 | Context injection method | **`[PROJECT-CONTEXT]` message prefix** | Follows existing pattern, zero gateway changes. |
| 8 | Migration approach | **Manual SQL** (6 rows) | Not worth a script. |
| 9 | Edit Topic UI | **Build from scratch** | No existing UI. 4-5 hours budgeted (includes project creation flow). |
| 10 | New topic creation | **Unchanged** | No project picker at creation time. Bind later. |
| 11 | Topics without projects | **Work as today** | No generic coverall. Optional binding. |
| 12 | Project creation from topic | **Scaffold from template** | Handles topic-before-project case. |

---

## 7. Estimated Effort

| Task | v0.1 Estimate | v0.2 Estimate | Change Reason |
|------|---------------|---------------|---------------|
| Database changes | 30 min | **0 min** | Use metadataJSON — no migration needed |
| Topic model (computed property) | 1 hr | **1 hr** | Same — JSON helpers instead of column |
| New Topic UI changes | 2-3 hrs | **0 hrs** | No changes at creation time |
| Edit Topic UI (build from scratch) | 1 hr | **4-5 hrs** | Edit UI + project creation flow |
| Sandbox check + bookmark flow (if needed) | — | **0-1 hr** | Depends on entitlements. Zero if unsandboxed. |
| SyncBridge message prefix | 1 hr | **1-2 hrs** | Extend buildContextHeader, straightforward |
| formatSessionSummary enhancement | 30 min | **30 min** | Same |
| Manual migration | 1 hr | **30 min** | 6 SQL statements, not a script |
| Testing | 1-2 hrs | **2-3 hrs** | More edge cases from review |
| **Total BeeChat** | **8-10 hrs** | **~11-14 hrs** | Honest estimates per Q's review |
| OpenClaw agent config | 30 min | **1-2 hrs** | Separate workstream, needs its own spec |
| **Total** | **8-10 hrs** | **~12-16 hrs** | |

---

## 8. Reviewer-Required Changes Checklist

From Kieran's review (CONDITIONAL APPROVE):

- [x] Path validation: must start with `/Users/openclaw/Projects/`, directory must exist → Section 2.1, 3.1.1
- [x] Session-end trigger for ACTIVITY.md writes → Section 2.3
- [x] ACTIVITY.md bootstrapping (create if doesn't exist) → Section 2.3
- [x] Clarify mobile SyncBridge behaviour → Section 2.5

From Q's review (BUILD WITH CAUTION):

- [x] Use metadataJSON not new column → Section 2.1, 3.1.1
- [x] Use message prefix not RPC param → Section 2.2, 3.1.4
- [x] Separate OpenClaw agent config from BeeChat scope → Section 3.2
- [x] Honest Edit Topic UI estimate → Section 3.1.3
- [x] Honest total estimate → Section 7

From Kieran's v0.3 review (CONDITIONAL APPROVE):

- [x] C1: Name collision handling — error clearly, don't overwrite → Section 3.1.3
- [x] C2: Template placeholder replacement — replace `[Project Name]` and `YYYY-MM-DD` during scaffolding → Section 3.1.3
- [x] C3: Validation order clarification — create flow (create dir → validate → set path) vs manual entry (validate → set path) → Section 3.1.3
- [x] Security: Resolve symlinks before hasPrefix check → Section 2.1, 3.1.1
- [ ] Recommended: Desktop visual indicator for bound topics (parity with mobile badge)
- [x] Filter `.DS_Store` during template copy → Section 3.1.3

From Q's v0.3 review (BUILD WITH CAUTION):

- [ ] Pre-build: Check `BeeChat-v5.entitlements` for sandbox setting → determines if bookmark flow needed
- [x] Edit Topic UI effort corrected to 6-8 hours → Section 7
- [x] Total estimate corrected to ~12-16 hours → Section 7
- [x] Sandbox check + bookmark flow added as task (0-1 hrs if needed) → Section 7
- [ ] Recommended: Name sanitization (alphanumeric + spaces + hyphens only)
- [ ] Recommended: UX decision for "Create New Project" button (inline form vs sub-sheet)

---

*Bee — coordinator. v0.3.1 — effort correction, pre-build sandbox check added.*