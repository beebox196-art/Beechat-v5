# FR-003: Research Entry Box — Kieran Adversarial Review

**Date:** 2026-06-19
**Reviewer:** Kieran (adversarial)
**Status:** Needs reshaping before spec approval
**Verdict:** The goal is sound. The proposed mechanism is over-engineered and architecturally misplaced. Reshape below.

---

## 1. Is This the Right Approach?

### The goal is right. The mechanism is wrong.

Adam wants: *drop a link/topic → get standardised research output → ingest into knowledge base.* That's a good goal. The current ad-hoc dispatch (drop link in Telegram → Bee routes to Gav → hope the output format is useful) has no consistency, no tracking, and no guarantee of depth. Formalising this is worth doing.

But a **dedicated UI component inside BeeChat with a dialog of checkboxes** is the wrong shape for the problem. Here's why:

**BeeChat is a thin client.** It's a WebSocket client to OpenClaw. It sends messages, receives messages, and renders them. It doesn't run agents. It doesn't run research pipelines. It doesn't produce HTML documents. All of that happens server-side via OpenClaw agents. Building a separate input mechanism in the Swift UI — with its own dialog, its own option controls, its own state management — to ultimately just send a text payload through the same WebSocket pipe is unnecessary surface area.

**The research pipeline already exists.** Gav runs ai-digest MWF. Sag runs Twitter scout 4x daily. The deep-research-pro skill exists. The firecrawl skill exists. What's missing is not the ability to do research — it's a **structured trigger and standardised output format**. That's a process problem, not a UI problem.

### The simpler way

Instead of a separate research entry box with a dialog of checkboxes, do this:

1. **A slash command or keyword trigger in the existing composer.** Type `/research <link or topic>` in the normal chat box. Bee parses it, routes to Gav with parameters.
2. **Parameters passed as natural language or simple flags.** `/research --depth deep --format html "Topcon positioning market"`. Or even simpler: `/research "Topcon positioning market"` with defaults, and Bee asks one clarifying question if needed.
3. **Gav executes the pipeline server-side** using existing skills (web_search, firecrawl, deep-research-pro) and returns a standardised HTML document.
4. **Output gets ingested into the knowledge base** via the existing wiki/memory infrastructure.

This requires **zero new Swift UI components.** It's a routing rule in Bee (or a new skill), a parameter spec, and an output template. The UI is already there — it's the chat box.

---

## 2. Architecture Concerns

### 2.1 Where does this live?

| Layer | What it should do | What Adam's proposal puts here |
|---|---|---|
| **BeeChat (Swift)** | Render messages, send text via WebSocket | Research entry box, option dialog, checkbox state, pipeline configuration UI |
| **OpenClaw Gateway** | Route messages to agents, manage sessions | (nothing new) |
| **Bee (coordinator agent)** | Parse intent, dispatch to Gav, manage pipeline | (implicitly, but not specified) |
| **Gav (research agent)** | Execute research, produce output | (implicitly, but not specified) |
| **Knowledge base** | Store outputs, make them searchable | (mentioned but not specified) |

The proposal puts the complexity in the wrong layer. BeeChat should be dumb. The intelligence should live where the agents are.

### 2.2 The WebSocket is a text pipe

BeeChat communicates with OpenClaw via WebSocket. It sends text messages and receives text/structured events. A "research entry box with a dialog of checkboxes" ultimately just encodes user selections into a text payload that goes through the same pipe. The checkboxes are a UI tax on what is fundamentally a text command.

If you want a nicer interface later — a proper "Research" panel with dropdowns — that's a v2 concern. For MVP, the composer is sufficient.

### 2.3 State management

The proposal implies BeeChat needs to track:
- Research request state (pending, in-progress, complete)
- Selected options (depth, type, format)
- Output destination (which knowledge base folder)

This is state that belongs server-side. BeeChat already has enough state management challenges with session keys, topic mapping, and streaming indicators (see FIX-003, DIAG-001). Adding research workflow state to the Swift app increases the cross-stream risk (shared packages touching both Mac and iOS) for no benefit.

### 2.4 Shared package contamination risk

Per CROSS-STREAM-SAFEGUARDS.md, any new logic in shared packages must build and test on both Mac and iOS. If the research entry box touches BeeChatSyncBridge or BeeChatPersistence (e.g., new message types, new event routing), it needs dual validation. That's a significant cost for a feature that could be a text command.

---

## 3. Scope Risks

### 3.1 Over-engineered

| Proposed feature | Necessary for MVP? | Verdict |
|---|---|---|
| Separate research entry box | No — use existing composer | Over-engineered |
| Dialog with checkboxes for level/depth/type | No — use flags or natural language | Over-engineered |
| "Pre-set managed process of evaluation" | Yes — but this is a server-side skill, not a UI concern | Right goal, wrong layer |
| Standardised HTML output | Yes | Keep |
| Ingestion into knowledge base | Yes — but needs concrete spec | Keep, specify |
| "Uniform, consistent research output" | Yes — this is a template/pipeline spec | Keep, make it a skill |

### 3.2 Missing from the proposal

- **Where does the HTML document live?** File path? Cloud? Wiki? Memory? The proposal says "ingestion into knowledge base" but doesn't specify the mechanism. Is it `wiki_apply`? Is it a file write? Is it a memory entry?
- **How does the user find past research?** If output goes to a knowledge base, how does someone search it from BeeChat? Or do they need to go to the filesystem/wiki? The proposal has no retrieval story.
- **What about Sag's Twitter data?** Research isn't just web search. Sag already collects Twitter/X data 4x daily. Should the research pipeline incorporate Sag's scout files? The proposal doesn't mention the existing research infrastructure at all.
- **Cost and time.** Deep research takes 15-20 minutes (per ai-digest skill). The proposal doesn't address that the user will wait a long time, or how progress is communicated.
- **Failure handling.** What happens when research fails? Partial results? Dead links? No results? The proposal has no error path.
- **Deduplication.** If Adam researches the same topic twice, what happens? Does the knowledge base deduplicate? Does it version?
- **Link following.** Adam says "drop a link." Does the pipeline follow the link first (web_fetch) then research the topic? Or research the topic broadly? This is unspecified.

### 3.3 What could go wrong

1. **Feature creep.** "Dialog with checkboxes" will inevitably grow. Next month: "add a priority dropdown." Next quarter: "add a research history panel." Each addition touches Swift UI code, requires builds, requires testing. Meanwhile, a slash command never changes.
2. **Pipeline rigidity.** A "pre-set managed process" sounds good until the first time the research doesn't fit the template. Research is inherently exploratory. Over-standardising the process will produce formulaic outputs that miss unexpected findings.
3. **Context loss.** If the research is triggered from a separate UI component, it loses the conversational context. Adam drops a link in the chat → Bee says "I'll research that" → Gav produces a document. That flow is natural. A separate entry box breaks that continuity.
4. **Mobile impact.** If any of this touches shared packages, it needs to work on iOS too. The iOS app doesn't need a research entry box — it needs the same chat-driven trigger.

---

## 4. Alternative Approaches

### 4.1 Slash command (recommended MVP)

**Mechanism:** User types `/research <topic or link>` in the existing composer. Bee parses the command, dispatches to Gav with default parameters. Gav runs the pipeline, returns a summary in chat + writes the full HTML document to a known location.

**Optional parameters:**
```
/research "Topcon positioning market share"           — defaults (medium depth, HTML output)
/research --depth deep "Topcon positioning market"    — deep research
/research --depth quick "latest AI news today"        — quick scan
/research --format brief "quantum computing 2026"     — short summary, no HTML
```

**Why this is better:**
- Zero new Swift UI code
- Works on both Mac and iOS (it's just text)
- Parameters are extensible without app changes
- Conversational context preserved
- Bee can ask clarifying questions in chat
- Progress updates arrive as messages (natural streaming)
- No shared package contamination

**What BeeChat needs:** Nothing. The composer already sends text. The response already renders as messages. The only new work is server-side: a research skill + output template.

### 4.2 Dedicated agent with a skill (recommended full vision)

Create a **research skill** in OpenClaw (not a BeeChat feature):

```
skills/research-pipeline/
├── SKILL.md           — Pipeline definition, parameters, output format
├── templates/
│   └── report.html    — Standardised HTML output template
├── scripts/
│   └── ingest.sh      — Push output to knowledge base (wiki/memory)
└── data/
    └── history.json    — Deduplication + research log
```

Bee routes `/research` triggers to Gav. Gav follows the skill. Output goes to:
- HTML file: `/Users/openclaw/Desktop/Research Reports/YYYY-MM-DD-topic.html` (or wiki)
- Chat summary: sent back through the WebSocket as a message
- Knowledge base: `wiki_apply` or `memory` entry with source citation

This keeps all the intelligence server-side where it belongs.

### 4.3 Rich UI as v2 (only if warranted)

If, after using the slash command for a month, Adam finds the text flags fiddly, *then* consider a UI panel. But build it as a Mac-only overlay (in `Sources/App/`), not in shared packages. And even then, the panel just constructs the same text command — it doesn't add new state to the app.

**Test:** if the slash command works well, the UI panel is unnecessary. If it doesn't, the panel is a convenience, not a requirement.

---

## 5. MVP vs Full Vision

### MVP (1-2 days work, zero Swift changes)

1. **Create `research-pipeline` skill** in OpenClaw:
   - Define parameters: depth (quick/medium/deep), format (brief/html), topic
   - Define output template: standardised HTML with sections (Summary, Key Findings, Sources, Analysis)
   - Define ingestion: write HTML to known path + create wiki/memory entry with citation
2. **Add a routing rule for Bee:** `/research <text>` → dispatch to Gav with the skill
3. **Gav executes:** web_search + firecrawl + (optionally) Sag's scout files → synthesise → write HTML → return chat summary
4. **Test end-to-end:** Adam types `/research "test topic"` in BeeChat → gets summary in chat → finds HTML file on disk

That's it. No new Swift code. No new UI components. No shared package risk. No cross-stream validation needed.

### Full Vision (if MVP proves useful)

1. **Research history view** in BeeChat sidebar (Mac-only, reads from knowledge base)
2. **Rich parameter panel** (Mac-only, constructs slash command from UI controls)
3. **Scheduled research** (cron-triggered research on recurring topics)
4. **Sag integration** (incorporate Twitter/X data from scout files into research output)
5. **Deduplication** (check knowledge base for existing research on same topic before re-running)
6. **Multi-agent research** (Gav + Sag + deep-research-pro in parallel for deep dives)

---

## 6. Summary Assessment

| Question | Answer |
|---|---|
| Is the goal worth pursuing? | **Yes.** Standardised research output is genuinely useful. |
| Is a separate UI entry box the right mechanism? | **No.** Use the existing composer with a slash command. |
| Is the proposed architecture correct? | **No.** Research logic belongs server-side in OpenClaw, not in BeeChat's Swift layer. |
| Is the proposal over-engineered? | **Yes.** Checkbox dialogs and separate input boxes for what is fundamentally a text command + server-side pipeline. |
| What's missing? | Output destination spec, retrieval story, error handling, deduplication, Sag integration, progress communication. |
| What's the right MVP? | A research skill + slash command routing. Zero Swift changes. 1-2 days. |
| What's the right full vision? | Skill-driven pipeline with optional Mac-only UI conveniences added only if the slash command proves insufficient. |

---

## 7. Recommendation

**Do not build a research entry box in BeeChat.**

Build a `research-pipeline` skill in OpenClaw. Trigger it via slash command from the existing composer. Standardise the output template server-side. Ingest results into the knowledge base through the existing wiki/memory infrastructure.

If Adam wants a UI panel later, it's a Mac-only convenience that constructs the same text command. But that's v2, and only if the slash command isn't enough.

The principle: **intelligence server-side, BeeChat stays thin.**

---

*Review by Kieran — 2026-06-19*