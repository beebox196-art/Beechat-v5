# FR-003: Research Pipeline

**Priority:** High
**Status:** Spec — Kieran reviewed (Approve with conditions, all applied). Updated to include minimal BeeChat research panel per Adam feedback.
**Author:** Bee (synthesised from Gav + Kieran input)
**Date:** 2026-06-19
**Predecessor:** FR-002 (tap-to-reconnect, merged v0.9.1)
**Related docs:**
- `Docs/Specs/Active/FR-003-RESEARCH-ENTRY-GAV-INPUT.md` — Gav's pipeline assessment
- `Docs/Specs/Active/FR-003-RESEARCH-ENTRY-KIERAN-REVIEW.md` — Kieran's architectural review

## Problem

Research is currently ad-hoc. Adam drops a link or topic into Telegram, Bee or Gav picks it up, and the depth varies wildly — sometimes a 2-minute web_search, sometimes a 20-minute deep dive. There's no consistency, no tracking, no deduplication, and no way to find what was researched three weeks ago.

## Solution

A **server-side research pipeline** with two entry points: a minimal research panel in BeeChat (text field + depth selector — no syntax to remember) and a slash command for power users. The intelligence lives in OpenClaw (a new skill), not in BeeChat's UI.

**Principle:** The pipeline is a server-side skill. BeeChat provides a minimal research panel that constructs the same text payload — no syntax to remember, no shared package changes.

## Trigger

### BeeChat research panel (primary entry point)

A minimal UI panel in BeeChat — accessible from the sidebar or a toolbar button:

- **Text field:** Paste a link, topic, or idea (multi-line supported)
- **Depth selector:** Three buttons — Quick Scan / Standard / Deep Dive (default: Standard)
- **Tags field:** Optional, free text, comma-separated
- **Submit button:** Sends the research request

Under the hood, the panel constructs the same text payload (e.g. `/research --depth standard "topic" --tags topcon,competitor`) and sends it through the existing WebSocket. No new message types, no shared package changes, no state management beyond the UI controls themselves.

**SwiftUI estimate:** ~60 lines in a new `ResearchPanel.swift` view (Mac-only, `Sources/App/UI/`). Does not touch BeeChatSyncBridge, BeeChatPersistence, or any shared package. The depth selector and tags field are local `@State` — no AppState changes, no environment object additions.

### Slash command (power user / fallback)

For users who prefer typing, the slash command still works in the existing composer:
```
/research "Topcon positioning market share"              — defaults (standard, HTML)
/research --depth quick "latest AI news today"            — quick scan, chat brief
/research --depth deep "PulseChain 2026 roadmap"          — deep dive, HTML report
```

### Telegram command (transitional mobile entry path)

Same syntax, same pipeline — until BeeChat Mobile replaces Telegram:
```
/research "topic"                    — defaults
/research --depth deep "topic"       — deep dive
```

**The research panel and slash command produce the same payload.** The panel is just a friendlier way to construct it — no syntax to remember.

### Defaults

| Parameter | Default | Options |
|-----------|---------|---------|
| `--depth` | `standard` | `quick` / `standard` / `deep` |
| `--format` | `html` (standard/deep) / `brief` (quick) | `html` / `brief` |
| `--tags` | (none) | Free text, comma-separated |

**Retention policy:** Keep everything for now — storage is cheap. Revisit if research-index.json exceeds 1,000 entries or HTML reports exceed 5GB. No auto-pruning in MVP.

**Conflict with existing knowledge:** If research findings contradict existing KB entries, flag the conflict explicitly in the HTML report ("⚠️ Conflicts with prior knowledge: [link to KB entry]"). Create a correction entry if Adam confirms the new finding is correct.

## Pipeline

### Stage 1: Intake & Triage (automated, <30s)

1. **Parse input:** URL? → `web_fetch` to extract content. Topic? → generate search queries. Idea? → expand to search terms.
2. **Dedup check:** Search existing research index + recent AI digests + knowledge base for overlap. If the topic was researched recently, report when and offer to go deeper instead of starting fresh.
3. **Build research brief:** Auto-generated search plan based on topic + depth level.
4. **Progress message:** Send "Researching: [topic] — Depth: [level] — Est. [time]" back to user.

### Stage 2: Collection (depth-dependent, 2-20 min)

| Source | Quick Scan | Standard | Deep Dive |
|--------|-----------|----------|-----------|
| Web search | 3-5 queries | 8-12 queries | 20+ queries |
| Sag scout files | Check latest | Check last 3 days | Check last 7 days |
| Reddit | Skip | 2-3 relevant subs | 5+ subs, deep scan |
| Firecrawl | Skip | JS-heavy pages only | All key pages |
| Knowledge base | Quick lookup | Cross-reference | Full Beelinks graph |
| X/Twitter (via Sag) | Latest files only | Latest + relevant historical | Deep historical search |

**Source weighting:** Claims from multiple independent sources get higher confidence. Single-source claims flagged. Low-quality sources (random blogs) downweighted vs authoritative sources (official docs, known experts).

### Stage 3: Analysis & Synthesis (depth-dependent, 3-15 min)

1. **Source extraction:** Key claims, data points, quotes (with source links)
2. **Conflict detection:** Do sources agree? Flag contradictions explicitly.
3. **Assessment:** Is this actionable? Worth monitoring? Noise? (Explicit verdict)
4. **Knowledge connection:** How does this fit what we already know? Link to related KB entries, past digests, prior research.
5. **Confidence assessment:** Per-finding confidence level (high/moderate/low) based on source quality and corroboration.

### Stage 4: Output (automated, <1 min)

**HTML report (Standard & Deep Dive):**
- Same CSS as AI Digest reports (`shared/report-style.css`)
- Sections: Summary → Key Findings → Detailed Analysis → Sources → Knowledge Base Links
- **Source provenance:** Every claim in the HTML report links to its source. No "according to various sources" — actual links, same requirement as KB entries.
- Written to: `/Users/openclaw/Desktop/Research Reports/YYYY-MM-DD-topic-slug.html`
- Chat summary sent back: 3-5 bullet points + link to full report

**Chat brief (Quick Scan):**
- 5-10 bullet points in chat
- Verdict: "Worth deeper research" or "Noise — here's why"
- No HTML file, no KB entry
- Logged in research index only

**Knowledge base entry (Standard & Deep Dive only):**
- Markdown summary written to knowledge base with tags, source links, date
- `wiki_apply` for structured knowledge + `memory` entry for searchability
- Every claim links to its source (no "according to various sources")

**Research index:**
- `research-index.json` — append on each run
- Simple JSON, not a database

**Research index schema:**
```json
{
  "id": "2026-06-19-topcon-positioning",
  "title": "Topcon positioning market share",
  "date": "2026-06-19T14:30:00Z",
  "depth": "standard",
  "tags": ["topcon", "competitor"],
  "status": "complete",
  "html_path": "/Users/openclaw/Desktop/Research Reports/2026-06-19-topcon-positioning.html",
  "kb_entry_path": "knowledge/Research/...",
  "cost_gbp": 0.15,
  "duration_seconds": 480,
  "sources_count": 11,
  "dedup_of": null
}
```

- `dedup_of`: null for original research, or the `id` of the prior research this builds on
- `cost_gbp`: estimated based on token count × model rate
- `status`: `complete` / `failed` / `partial`

### Stage 5: Follow-up (optional, user-triggered)

- "Go deeper on X" → re-enters pipeline with narrower focus, builds on existing research
- "Monitor this" → adds to watch list for future digests to track
- Feedback: 👍/👎 on research quality (logged for pipeline improvement)

## Depth Levels

| Level | Name | Time | Cost (approx) | Output | KB Entry |
|-------|------|------|---------------|--------|----------|
| 1 | Quick Scan | 2-3 min | ~£0.05 | Chat brief | No |
| 2 | Standard | 8-12 min | ~£0.15 | HTML + chat | Yes |
| 3 | Deep Dive | 15-25 min | ~£0.60 | HTML + chat | Yes |

**Default: Standard.** Most requests are standard depth. Quick Scan for "is this real?" checks. Deep Dive for strategic decisions.

## Model Selection (automatic, not user-facing)

| Depth | Model | Why |
|-------|-------|-----|
| Quick Scan | Default (active model) | Speed over depth |
| Standard | MiniMax-M3 | Good synthesis, cost-effective |
| Deep Dive | Grok 4.3 (search) + MiniMax-M3 (synthesis) | Best search + best synthesis |

**Model selection is preferred, not hard.** If a preferred model is unavailable, fall back to the default active model rather than failing the run.

## Sag Integration

Before any web search, the pipeline checks Sag's scout files on SSD:
- Quick Scan: Check today's files only
- Standard: Check last 3 days
- Deep Dive: Check last 7 days

If Sag already captured relevant X/Twitter signal, use it instead of re-searching. This saves API cost and avoids duplicating work Sag already did.

## Cost Management

- Log cost per run in `research-index.json` (estimated tokens × model rate)
- Weekly total surfaced in Monday digest
- No upfront cost wall — costs are observable, not blocked
- If weekly spend exceeds £50, flag in digest for Adam's awareness

## Implementation

### Phase 1: Pipeline skill (MVP — 1-2 days, zero Swift changes)

**Create `research-pipeline` skill:**
```
~/.openclaw/workspace/skills/research-pipeline/
├── SKILL.md                    — Pipeline definition, parameters, output format
├── templates/
│   └── report.html             — Standardised HTML template (uses shared CSS)
├── scripts/
│   └── ingest.py               — Push output to knowledge base (wiki + memory)
└── data/
    └── research-index.json     — Dedup + research log
```

**Bee routing rule:** When message starts with `/research`, parse parameters, dispatch to Gav with research-pipeline skill context.

**Gav executes:** web_search + firecrawl + Sag files → synthesise → write HTML → return chat summary.

**`ingest.py` contract:**
- Runs after every Standard or Deep Dive run (not Quick Scan)
- Reads: the HTML report file path + research metadata (title, tags, date, sources)
- Writes: `wiki_apply` call for structured KB entry + `memory` entry for searchability
- Input: command-line args (`--html-path`, `--title`, `--tags`, `--sources`)
- Does NOT: create the HTML report (Gav writes that during synthesis), or modify the HTML file
- Failure handling: log error, set `status: "partial"` in research-index.json, do NOT fail the run

### Phase 2: Knowledge base integration

- Dedup check against existing research before running
- Wiki entry creation with source citation
- Memory entry for searchability
- Cross-reference to related KB entries and past digests

### Phase 3: Sag integration

- Check Sag scout files before web search
- Incorporate relevant X/Twitter signal into research output
- Credit Sag as source in the report

### Phase 4: Telegram entry path

- `/research` command works from Telegram (same syntax, same pipeline)
- Critical for mobile — Adam often finds things on his phone

### Phase 5: Polish (only if warranted)

- Research history view in BeeChat sidebar (Mac-only, reads research-index.json)
- Rich parameter panel (Mac-only, constructs slash command from UI controls)
- Scheduled/cron-triggered research on recurring topics
- Multi-agent deep dives (Gav + Sag + deep-research-pro in parallel)
- Cost dashboard in BeeChat
- Feedback loop (👍/👎 after each run)

## Error Handling

| Scenario | Behaviour |
|----------|----------|
| Dead link (404) | Report "link dead" in chat, suggest searching topic instead |
| No results found | Report "no results" in chat, suggest broader search terms |
| Partial results | Return what was found, flag incomplete coverage |
| API rate limit | Wait and retry (existing web_search behaviour) |
| Pipeline crash | Report error in chat, log failure in research-index.json |
| Sag files unavailable / SSD not mounted | Degrade gracefully — skip Sag, proceed with web search, note in report that Sag was unavailable |
| `wiki_apply` or memory write fails | HTML report and chat summary still delivered. KB ingestion is secondary — failure doesn't fail the run. Log the failure in research-index.json with `status: "partial"` |
| Pathologically short or ambiguous input (e.g. `/research "ai"`) | Default to Quick Scan with a note: "Topic is broad — running Quick Scan. Use `--depth deep` for comprehensive coverage" |

## Concurrency

- One Deep Dive at a time
- Up to 2 Quick Scans in parallel
- Standard queues behind any running Deep Dive
- User notified if queued: "Research queued — your Deep Dive on X is running, this will start when it completes"

## Success Criteria

1. `/research "test topic"` in BeeChat → chat summary appears within 3 min (quick) / 12 min (standard) / 25 min (deep)
2. HTML report exists at expected path, opens in browser, uses standard CSS
3. KB entry created with tags, source links, date
4. `/research` from Telegram works identically
5. Re-searching same topic → dedup message with link to existing research
6. Sag scout files checked before web search (visible in report sources)
7. Cost logged in research-index.json
8. Progress message sent at start of research
9. Error cases handled gracefully (dead link, no results, rate limit, Sag unavailable, KB write failure)
10. Research findable 2 weeks later via knowledge base search (verify mechanism on build day, schedule 2-week follow-up)
11. Every claim in HTML report links to its source (source provenance)
12. HTML report renders correctly in browser (readable, sections, headings, links work)

## Out of Scope (MVP)

- No new Swift UI components
- No changes to BeeChatSyncBridge or BeeChatPersistence
- No shared package changes
- No database (JSON index only)
- No research history UI in BeeChat
- No scheduled/cron-triggered research
- No multi-agent parallel research

## Files Changed (MVP)

| Location | Change | Type |
|----------|--------|------|
| `~/.openclaw/workspace/skills/research-pipeline/SKILL.md` | New skill definition | New |
| `~/.openclaw/workspace/skills/research-pipeline/templates/report.html` | HTML template | New |
| `~/.openclaw/workspace/skills/research-pipeline/scripts/ingest.py` | KB ingestion script | New |
| `~/.openclaw/workspace/skills/research-pipeline/data/research-index.json` | Research log | New |
| `Sources/App/UI/ResearchPanel.swift` | Minimal research panel (text field + depth selector + tags + submit) | New (~60 lines) |
| `Sources/App/UI/Components/Sidebar.swift` or toolbar | Button to open research panel | Modified (~5 lines) |
| Bee routing (internal) | `/research` command parsing | Config |
| `~/Desktop/Research Reports/` | Output directory | New (filesystem) |

**Swift changes: 1 new file (~60 lines) + 1 small modification (~5 lines). No shared package changes. No BeeChatSyncBridge or BeeChatPersistence changes.**

## Review Checklist

- [ ] Pipeline produces consistent output regardless of which agent runs it
- [ ] Dedup check works (same topic twice → second run references first)
- [ ] Sag integration doesn't duplicate already-captured signal
- [ ] HTML output uses same CSS as AI Digest (visual consistency)
- [ ] KB entries are searchable via memory_search
- [ ] Cost logging is accurate (within 20% of actual)
- [ ] Error paths produce useful user-facing messages
- [ ] Telegram entry path works (mobile testing)
- [ ] Quick Scan completes in under 5 min
- [ ] Deep Dive completes in under 30 min

## Build & Validation

| Step | Owner |
|------|-------|
| Spec review | Kieran |
| Skill implementation | Gav (pipeline) + Bee (routing) |
| Test runs | Gav (3 depths: quick, standard, deep) |
| Kieran review | Verify pipeline consistency, error handling |
| Adam smoke test | `/research "test"` from BeeChat + Telegram |
| KB integration verification | Bee (search for output 1 week later) |