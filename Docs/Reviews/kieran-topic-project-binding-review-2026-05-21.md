# Kieran Review: Topic-Project Binding Spec

**Date:** 2026-05-21
**Reviewer:** Kieran
**Spec:** `/Users/openclaw/Projects/BeeChat-v5/Docs/Fix-Specs/topic-project-binding-spec.md`
**Verdict:** CONDITIONAL APPROVE

---

## Executive Summary

The spec solves a real problem with minimal machinery — that's good. The two-path design (read STATUS.md, write ACTIVITY.md) is conceptually sound but has several failure modes that are acknowledged but not sufficiently mitigated. The spec leans heavily on "convention enforced by system prompt" as its reliability mechanism, which is both its strength (simple) and its greatest risk (unreliable). Conditional approval with the recommendations below.

---

## 1. Architecture — Two-Path Design

### Read Path: Mostly Sound
Reading STATUS.md + decisions.md + corrections.md at session start is the right approach. These files are the curated project context the AI needs. The spec correctly identifies that this is an agent convention, not a BeeChat code change — that keeps the system boundary clean.

**Failure mode 1: STATUS.md is stale.** The spec acknowledges this in the problem statement but the read path trusts whatever's in STATUS.md. If STATUS.md says "next step: build the UI" but the UI was built three weeks ago and nobody updated it, the AI gets misleading context. This is acceptable — stale context is better than no context, and the session summary injection partially covers it.

**Failure mode 2: File doesn't exist.** The spec says "if it exists" for decisions.md/corrections.md but doesn't address what happens if STATUS.md itself is missing. The AI needs a graceful fallback — it should proceed without project context, not error out or hang trying to read a file that isn't there.

**Failure mode 3: Large STATUS.md.** If STATUS.md grows to 2000+ words, injecting it on every session start is a token cost the spec doesn't account for. The spec should recommend a "recent section only" strategy or a maximum context injection size.

### Write Path: Fragile by Design
This is the weak point. The spec delegates ACTIVITY.md writes to the AI as a "convention enforced by system prompt." This is a soft constraint on a non-deterministic system.

**Failure modes:**
- The AI forgets the instruction (context window pressure, especially at 80% usage)
- The AI interprets "significant progress" differently each time — sometimes logging trivial things, sometimes missing important decisions
- Concurrent topics writing to the same ACTIVITY.md → race condition with file append
- The AI hallucinates the path or writes to the wrong file

The append operation itself is also underspecified. Is it a read-modify-write? An append syscall? If the AI reads ACTIVITY.md, prepends new content, and writes it back, two concurrent sessions will lose one entry. This needs a serialization strategy or at least acknowledgment of the risk.

### The `projectPath` Column Design
A nullable TEXT column is the right choice. Simple, queryable, easy to migrate. Storing it directly (not in metadataJSON) is the right call — this is a first-class relationship now, not metadata soup.

**Recommendation:** Add a CHECK constraint or validation that the path starts with `/Users/openclaw/Projects/`. This prevents garbage data from being stored and makes the invariant explicit.

---

## 2. Scope Creep — Is This the Simplest Solution?

The spec is well-scoped. It does three things:

1. Store a path in the database
2. Read project files at session start
3. Write activity summaries

Everything else is explicitly called out as "what this is NOT." Good discipline.

**What I would cut:**

- **The project picker autocomplete from `/Users/openclaw/Projects/` subdirectories.** This requires BeeChat (a Swift app) to scan the filesystem, which introduces macOS sandbox permissions complexity. Start with a dropdown of known projects (the 6 listed in the mapping table). The user can type a custom path if needed. Defer filesystem scanning to v2 if it becomes a pain point.

- **The migration script.** The spec says "match topic name to project folder" — this is a one-off, 6-row operation. Do it manually. A script introduces test burden for something you run once.

**What I would keep:** Everything else is lean and justified.

---

## 3. Open Questions — Recommendations

| # | Question | Recommendation | Rationale |
|---|----------|----------------|-----------|
| 1 | Activity log filename | **`ACTIVITY.md`** | Matches ALL-CAPS convention (STATUS.md, MEMORY.md, AGENTS.md). Consistency reduces cognitive overhead. |
| 2 | Who triggers initial read? | **Option A: auto-read at session start** | The spec's own problem statement says context drift happens at 20% usage. If the first session has no project context, the AI starts blind. Token cost is small relative to the value of grounded context. |
| 3 | Auto-update STATUS.md vs manual | **Proactive at milestones with confirmation** | This is the right balance. The AI should propose a STATUS.md update, Adam confirms (or rejects). Full auto-update risks the AI making decisions about what's "current" without human judgment. |
| 4 | Topic-project matching heuristic | **Exact match only** | Fuzzy matching is a footgun. "Beechat" and "BeeChat Mobile" are different projects — fuzzy matching could bind the wrong one. Explicit manual assignment for mismatches is safer. |
| 5 | projectPath in UI | **Settings only, with one exception** | Keep it out of the topic list for cleanliness. BUT: show a small project badge (just the project name, not the path) on the topic card when bound. This provides visual confirmation without clutter. |

---

## 4. Missing Pieces

### 4.1 ACTIVITY.md Race Conditions
Already noted in Architecture. If two topics bound to the same project are active simultaneously, both may try to append to ACTIVITY.md. The simplest fix: the AI should read the file, find the last `###` heading, and insert its entry after — but this is still a TOCTOU (time-of-check-time-of-use) race. For BeeChat's single-user context, this is unlikely but not impossible. **Recommendation:** Document the risk, accept it for v1. If it becomes a problem, use a lock file or a `YYYY-MM-DD-HHMM.md` per-session pattern instead of appending to one file.

### 4.2 Path Changes / Project Moves
If a project folder moves (e.g. `/Projects/BeeChat-Mobile/` → `/Projects/BeeChat-v5-Mobile/`), the stored `projectPath` breaks. **Recommendation:** Add a "validate binding" function that checks if the path exists on disk and surfaces a warning to the user if it doesn't. This could run on topic open.

### 4.3 ACTIVITY.md Format Drift
The spec defines a format for ACTIVITY.md entries, but there's no enforcement mechanism. Over time, entries will drift — some will be one-liners, some will be essays, some will be structured, some won't. **Recommendation:** Include a format example in the system prompt. The spec already does this implicitly, but it should be explicit: the prompt must include the exact format template.

### 4.4 Session End vs. Session Reset
The spec covers session start and session reset, but not session end. When does the AI write the ACTIVITY.md entry? At the end of each message exchange? At the end of the session? The spec says "when significant progress is made" which is ambiguous. **Recommendation:** Trigger on session end (the agent is about to yield) as the primary write point. Supplemental writes during the session for major decisions are optional.

### 4.5 Unbound Topics
The spec says "topics without a project match simply don't have the field." What happens if a topic starts unbound and the user adds a binding mid-conversation? The AI won't have read STATUS.md at session start. **Recommendation:** When a binding is added, the system prompt should instruct the AI to read the project context on the next message.

### 4.6 Testing — No Test Strategy
The testing checklist is a manual checklist. For a Swift app, there should be at least unit tests for:
- Database migration (column added, nullable, no crash)
- Topic model serialization/deserialization with projectPath
- SyncBridge metadata forwarding (projectPath included/excluded correctly)

---

## 5. Security

### File Path Traversal
`projectPath` is user-editable (topic settings). If a malicious or mistaken user sets `projectPath` to `../../../` or `/Users/openclaw/.ssh/`, the AI could read sensitive files and write ACTIVITY.md to unexpected locations.

**Risk level:** Low for a single-user local app, but non-zero. Adam is the only user, but accidents happen.

**Recommendation:**
1. **Validate on write:** When `projectPath` is set, check that it starts with `/Users/openclaw/Projects/` and that the directory exists. Reject invalid paths with a user-facing error.
2. **Never follow symlinks** when reading project files.
3. **Sanitize on read:** The OpenClaw agent instruction should include the project path as a validated constant, not interpolated from user input without checking.

### SQLite Injection
`projectPath` is stored as a TEXT column. If the UI passes the path through raw SQL (it shouldn't, but the spec doesn't specify parameterized queries), there's an injection vector. **Recommendation:** Explicitly state that all database operations use parameterized queries. This is almost certainly already the case, but it should be called out.

### Content Injection in ACTIVITY.md
If the AI writes user-provided content to ACTIVITY.md without sanitization, and that content contains markdown that looks like headers, links, or HTML, it could affect downstream parsing. **Recommendation:** Not critical for v1, but note that ACTIVITY.md is a display file — markdown injection is a cosmetic risk, not a security one.

---

## 6. Write Path Reliability

This is the biggest risk in the spec, and it deserves its own section.

### The Fundamental Problem
The AI is a probabilistic system. The spec asks it to:
1. Detect "significant progress" (subjective judgment)
2. Format an entry correctly (template following)
3. Write to the right file (path correctness)
4. Do this consistently across many sessions (reliability)

These are four independent failure points. Even if each has 90% reliability, the compound reliability is 90%^4 = 66%. In practice, it'll be higher because some failures are correlated, but the point stands: **convention-based writes will fail silently.**

### What Happens When It Fails?
- The AI forgets to write → ACTIVITY.md goes stale. This is the most likely failure mode. It's also the least damaging — stale activity log is a nuisance, not a crisis.
- The AI writes to the wrong path → entries end up in the wrong project. Detectable by periodic review.
- The AI writes garbage → detectable by review.

### Mitigations I Recommend
1. **Session-end hook:** Instead of relying on the AI to remember, the system should inject a system message at session end: "You are ending this session. If you made significant progress, append a dated entry to ACTIVITY.md." This is a concrete trigger point, not a vague "when significant progress is made."
2. **ACTIVITY.md existence check:** If ACTIVITY.md doesn't exist, the AI should create it with a header. The spec assumes it exists but doesn't address bootstrapping.
3. **Adam review cadence:** Add to the system prompt a periodic instruction: "Every N sessions, remind Adam to review ACTIVITY.md and update STATUS.md." This creates a human-in-the-loop catch for missed writes.
4. **Graceful degradation:** If the AI can't write (permissions error, path doesn't exist, etc.), it should log a warning in the session, not silently fail.

---

## 7. Mobile Implications

### BeeChat Mobile App
The spec describes BeeChat code changes (DatabaseManager, Topic model, SyncBridge, UI). If BeeChat Mobile shares code with the desktop/web version, these changes apply. If it's a separate codebase, the mobile app needs the same `projectPath` field and UI updates.

**Specific mobile concerns:**

1. **File access from mobile:** The mobile app can't directly read `/Users/openclaw/Projects/` — that's a Mac filesystem path. The `projectPath` field is stored on the server/gateway side, not on the mobile device. The mobile UI shows the binding, but the actual file reading happens on the OpenClaw server. **Clarification needed in spec:** Does BeeChat Mobile sync `projectPath` through the same SyncBridge? If so, this is fine. If not, mobile topics won't have project bindings.

2. **Mobile UI space:** The spec recommends settings-only for projectPath visibility. On mobile, settings are already buried. **Recommendation:** Show a small project badge in the topic list on mobile — one line, just the project name. Mobile users need more visual cues, not fewer.

3. **No mobile filesystem picker:** The autocomplete filesystem picker is a macOS-only feature anyway. On mobile, use a static list. This aligns with my recommendation to cut the filesystem scanner entirely.

4. **Offline behavior:** If BeeChat Mobile works offline, `projectPath` is local metadata — no problem. The AI reads project files on the server side when the session connects.

---

## 8. Additional Concerns

### Token Budget
Reading STATUS.md + decisions.md + corrections.md on every session start adds tokens to every conversation. The spec doesn't quantify this. For a large STATUS.md (5000+ chars), this is a non-trivial cost per session. **Recommendation:** Consider a "context budget" — read only the most recent section of STATUS.md, or summarize it once and cache the summary.

### ACTIVITY.md Growth
ACTIVITY.md is append-only and unbounded. After 6 months of daily entries, it'll be hundreds of lines. The AI won't read it all on reset. **Recommendation:** Specify that the AI reads only the most recent 5-10 entries on reset, not the full file. Or recommend periodic pruning/archiving of old entries.

---

## 9. Summary of Required Changes Before Approval

| # | Change | Priority | Effort |
|---|--------|----------|--------|
| 1 | Add path validation (must start with `/Users/openclaw/Projects/`, directory must exist) | **Required** | 30 min |
| 2 | Define session-end trigger for ACTIVITY.md writes (not "when significant progress is made") | **Required** | 15 min |
| 3 | Address ACTIVITY.md bootstrapping (create if doesn't exist) | **Required** | 10 min |
| 4 | Clarify mobile SyncBridge behavior for projectPath | **Required** | 15 min |
| 5 | Add context budget for STATUS.md read (don't inject unlimited content) | **Recommended** | 15 min |
| 6 | Specify ACTIVITY.md read limit on reset (recent N entries only) | **Recommended** | 10 min |
| 7 | Cut filesystem autocomplete picker, use known project list | **Recommended** | Already simpler |
| 8 | Do migration manually, not with a script | **Recommended** | Already simpler |

---

## Verdict: CONDITIONAL APPROVE

The spec is sound, well-scoped, and solves a real problem. The two-path design is architecturally clean. The main risk is the write path's reliance on convention — this needs stronger triggers and failure handling before implementation. The required changes above are all small (90 minutes total) and don't change the fundamental design.

Once the 4 required items are addressed, this is ready for implementation.

— Kieran, 2026-05-21
