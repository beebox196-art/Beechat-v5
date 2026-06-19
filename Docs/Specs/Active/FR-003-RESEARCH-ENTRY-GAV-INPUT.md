# FR-003: Research Entry Box — Gav Input

**Author:** Gav (Research & Morale)
**Date:** 2026-06-19
**Status:** Assessment complete — ready for Adam's review
**Type:** Feature input / research operations assessment

---

## 1. Is This Worthwhile?

**Yes, with conditions.**

The core problem is real: Adam drops links into Telegram, Bee or I pick them up ad-hoc, research depth varies wildly depending on who's awake and what model is running. Sometimes you get a 2-minute web_search summary, sometimes a 20-minute deep dive. There's no consistency, no tracking, and no way to go back and find what was researched three weeks ago.

A structured entry point solves three actual problems I face:

1. **Depth inconsistency.** Right now "research this" could mean anything from a single search to a multi-source synthesis. A depth selector forces an explicit choice.
2. **No persistence.** Research done in chat lives in the chat scroll. It's not searchable, not indexed, not connected to the knowledge base. I write digests to `/Users/openclaw/Desktop/Gavins Research Reports/` but one-off research requests scatter to the wind.
3. **No routing.** Adam drops a link, I might not see it for hours. Sag might pick up the same topic independently. There's no deduplication, no awareness of what's already been researched.

**But — and this is important — this is only worthwhile if the pipeline underneath is real.** A nice UI wrapper over `web_search` is useless. The value is in standardising the research *process*, not the input box. If the pipeline is half-baked, the UI just makes it easier to produce inconsistent research faster.

---

## 2. Ideal Research Pipeline

Here's what I actually do when Adam asks me to research something, formalised:

### Stage 1: Intake & Triage (automated, <30s)
- **Input:** Link, topic, or idea from Adam
- **Auto-detect:** URL? → fetch and extract content. Topic? → search queries. Idea? → expand to search terms.
- **Dedup check:** Search existing knowledge base + recent digests for overlap. If I researched this last Tuesday, say so.
- **Output:** Research brief with auto-generated search plan, ready for Adam to adjust depth/parameters.

### Stage 2: Collection (depth-dependent, 2-20 min)
- **Web search:** Primary signal (web_search for broad, firecrawl for JS-heavy pages)
- **X/Twitter:** Check Sag's latest scout files for relevant content. If the topic is AI-adjacent, Sag probably already has signal.
- **Reddit:** Targeted subreddits depending on topic (not always r/LocalLLaMA — match to subject)
- **Knowledge base:** Query Beelinks for existing internal context
- **Cross-reference:** Items appearing in 2+ sources get higher confidence

### Stage 3: Analysis & Synthesis (depth-dependent, 3-15 min)
- Source extraction: key claims, data points, quotes
- Conflict detection: do sources agree?
- Assessment: is this actionable, worth watching, or noise?
- Connection to existing knowledge: how does this fit what we already know?

### Stage 4: Output Generation (automated, <1 min)
- **HTML document:** Standardised format (same CSS as AI Digest reports — `shared/report-style.css`)
- **Knowledge base entry:** Markdown summary written to knowledge base with tags, source links, date
- **Memory entry:** Brief note in memory/digests/ for searchability
- **Optional:** Telegram notification with summary + link to full report

### Stage 5: Follow-up (optional, Adam-triggered)
- "Go deeper on X" → re-enters pipeline with narrower focus
- "Monitor this" → adds to a watch list for future digests to pick up

---

## 3. User-Settable Parameters

Keep it simple. Too many options = decision paralysis. I'd recommend **three controls**:

### Research Depth (3 levels — no more)

| Level | Name | What It Does | Time | Cost |
|-------|------|--------------|------|------|
| 1 | **Quick Scan** | 3-5 web searches, Sag check, single-source synthesis. "Is this worth caring about?" | ~2-3 min | Low |
| 2 | **Standard** | 8-12 searches across web + Reddit + X, multi-source synthesis, knowledge base cross-ref. "What's the full picture?" | ~8-12 min | Medium |
| 3 | **Deep Dive** | 20+ searches, firecrawl on key pages, Beelinks graph, conflict analysis, competitive landscape. "Give me everything." | ~15-25 min | High |

**Default to Level 2.** Most of Adam's requests are Standard depth. Quick Scan for "is this real?" checks. Deep Dive for strategic decisions.

### Output Format (2 options)

| Format | When |
|--------|------|
| **HTML Report** | Default. Same style as AI Digest. Opens in browser. |
| **Brief (chat)** | For Quick Scan only. Just return the summary in chat, no HTML file. |

### Tagging (optional, free text)

Let Adam add tags/topics so the research is findable later. Examples: `topcon`, `polymarket`, `competitor`, `tooling`. Auto-suggest from existing knowledge base tags.

### What NOT to include as a user option

- **Model selection:** This should be automatic. Quick Scan → fast model. Deep Dive → MiniMax-M3 or Grok 4.3. Don't make Adam think about models.
- **Source selection:** Don't let users pick "search Reddit only" or "skip Twitter." The pipeline should be smart enough to weight sources by topic. A research request about indie SaaS should hit Reddit hard; a request about AI benchmarks should weight X/Twitter.
- **Time limit:** The depth level IS the time control. Adding a separate time limit is redundant and creates conflicts.

---

## 4. Practical Considerations

### API Costs

This is the real constraint. My current workflow is bounded:
- MWF digest: ~15-20 min on MiniMax-M3, one run
- Ad-hoc research: variable, usually 5-10 min on whatever model is active

A research entry box could **significantly increase costs** if used frequently. Estimates:

| Depth | Searches | Estimated tokens | Cost per run (approx) |
|-------|----------|-----------------|----------------------|
| Quick Scan | 3-5 | ~5K output | £0.02-0.05 |
| Standard | 8-12 | ~15K output | £0.10-0.20 |
| Deep Dive | 20+ | ~40K output + firecrawl calls | £0.40-0.80 |

At 5 requests/day at Standard depth: ~£1/day, ~£30/month. Manageable but not free.

**Recommendation:** No upfront cost wall, but log costs per run and surface a weekly total. If Adam starts spending £100+/week on research, that should be visible. Don't block — just make it observable.

### Time

- Quick Scan: 2-3 min — fast enough to feel responsive
- Standard: 8-12 min — this is the "go get a coffee" zone
- Deep Dive: 15-25 min — this is "I'll check back later"

**The UI must set expectations.** Show estimated time when depth is selected. Don't pretend a Deep Dive will be done in 2 minutes.

### Model Selection (automatic)

| Depth | Model | Why |
|-------|-------|-----|
| Quick Scan | Default (whatever's active) | Speed over depth |
| Standard | MiniMax-M3 | Good synthesis, cost-effective |
| Deep Dive | Grok 4.3 + MiniMax-M3 | Grok for X/search, MiniMax for synthesis |

### Storage

- HTML reports: `/Users/openclaw/Desktop/Gavins Research Reports/` (or a dedicated `research/` subfolder)
- Knowledge base entries: `.openclaw/workspace/knowledge/Research/`
- Memory: `.openclaw/workspace/memory/research/` (new — separate from digest memory)
- Index: A simple `research-index.json` tracking all runs with title, date, depth, tags, file path

**Keep the index simple.** Don't build a database. A JSON file updated on each run is fine.

### Concurrency

If Adam fires 3 research requests in quick succession, what happens? Options:
1. **Queue them** — simplest, but frustrating if #1 is a Deep Dive and #2 is a Quick Scan
2. **Parallel with priority** — Quick Scan jumps ahead, Standard/Deep Dive queue
3. **Just run them all in parallel** — works until API rate limits hit

**Recommendation:** Queue with Quick Scan priority. One Deep Dive at a time. Up to 2 Quick Scans in parallel.

---

## 5. Fit With Existing Workflow

This is where it gets interesting. The research entry box doesn't replace my existing workflow — it sits alongside it and can feed into it.

### Current Workflow
```
Sag (4x/day) → SSD storage → Gav reads MWF → AI Digest (HTML + memory)
                          ↓
Adam ad-hoc → Telegram → Gav picks up → variable quality research
```

### With Research Entry Box
```
Sag (4x/day) → SSD storage → Gav reads MWF → AI Digest (unchanged)
                          
Adam → Research Entry Box → Structured pipeline → HTML report + KB entry
                                                    ↓
                                              Future digests can reference
```

**Key integrations:**

1. **Sag scout files:** The pipeline should check Sag's latest files before running web searches. If Sag already captured relevant X/Twitter signal, use it instead of re-searching. This saves time and API cost.

2. **AI Digest cross-reference:** When the pipeline runs, it should check if the topic appeared in recent digests. If I already covered something on Monday, the research entry output should reference that, not re-research it.

3. **Knowledge base growth:** Research entry outputs go into the same knowledge base that future digests pull from. This means ad-hoc research compounds — today's deep dive becomes context for next week's digest.

4. **Watch list:** If Adam tags something as "monitor," it should feed into my discovery system. I already have a topic rotation in the AI Digest discovery engine. Research entry "monitor" tags could add to that rotation.

5. **MWF schedule unchanged:** The digest continues as-is. Research entry box is on-demand, not scheduled. They serve different purposes — digest is broad sweep, research entry is targeted deep dive.

### What Changes For Me

Honestly? Not much day-to-day. The digest keeps running. What changes is:
- Ad-hoc requests become structured instead of chaotic
- I spend less time figuring out "how deep does Adam want this?" 
- Research outputs are findable instead of lost in chat scroll
- I can reference past research when writing digests

---

## 6. What Makes This Actually Useful vs. A Fancy UI Wrapper

This is the most important section. Here's what separates a real tool from a coat of paint:

### Must-Have (without these, don't build it)

1. **Deduplication against existing research.** Before running anything, check the knowledge base and recent reports. If I researched "Topcon positioning APIs" two weeks ago, tell Adam that and offer to go deeper rather than starting from scratch. This is the single most valuable feature.

2. **Source quality tracking.** Not all sources are equal. A claim from karpathy's Twitter is different from a claim from a random blog. The pipeline should weight sources and flag low-confidence claims. My digest already does this implicitly; the research entry should do it explicitly.

3. **Persistent, searchable output.** HTML report + knowledge base entry + memory file. If I can't find the research three weeks later, the system failed. The output must be indexed and searchable.

4. **Connection to existing knowledge.** Every research output should link to related entries in the knowledge base. "This relates to the AI Digest from 2026-06-17 which covered similar ground." This is what makes research compound over time.

5. **Sag integration.** Check Sag's scout files first. This is free signal — Sag already ran 4 times today, why duplicate that work?

### Nice-to-Have (build these in v2)

- **Research history view** in BeeChat — see past research requests, their depth, tags, outputs
- **Re-run with new sources** — "research this again, it's been 2 weeks, what's changed?"
- **Auto-routing to team** — if research output is code-related, offer to send to Q; if design-related, offer to send to Mel
- **Cost dashboard** — weekly/monthly research spend visible in BeeChat

### Red Flags (if these happen, the feature has failed)

- Adam still drops research requests in Telegram instead of using the entry box → the UX is wrong
- Research outputs are inconsistent in quality → the pipeline isn't enforcing depth levels properly
- Research outputs aren't findable 2 weeks later → storage/indexing is broken
- The pipeline re-searches things Sag already captured → Sag integration isn't working
- API costs spike unexpectedly → no cost observability

---

## 7. Honest Assessment — What's Over-Engineered

**The checkboxes/dialog for research type.** Adam's proposal mentions "type of response required" as a user option. I'd push back on this. The output format should be determined by the depth level, not a separate selector. Quick Scan → chat brief. Standard/Deep Dive → HTML report. Done. Adding a "type of response" selector creates a combinatorial explosion of pipeline configurations that we'll never properly test.

**HTML as the only output.** HTML is fine for standalone reports, but for Quick Scan depth, a chat response is better. Don't generate an HTML file for a 2-minute scan — that's ceremony, not value.

**"Ingestion into knowledge base" as automatic.** This needs to be more thoughtful. Not every research output deserves a knowledge base entry. A Quick Scan that concludes "this is noise" should not pollute the knowledge base. Only Standard and Deep Dive outputs get KB entries. Quick Scan outputs stay in chat (or a lightweight research log).

---

## 8. What's Missing From Adam's Proposal

1. **No mention of what happens when research conflicts with existing knowledge.** If the pipeline discovers that our previous understanding was wrong, what happens? Does it flag the conflict? Update the KB? Create a correction entry? This needs a defined behaviour.

2. **No feedback loop.** How does Adam rate the research quality? Without a "this was useful / this was shallow / this missed the point" signal, the pipeline can't improve. A simple 👍/👎 after each run would be enough.

3. **No mention of source provenance.** Every claim in the output should link to its source. Not "according to various sources" — actual links. My digest does this; the research entry must too.

4. **No mobile consideration.** Adam uses BeeChat on macOS, but he drops links from Telegram on his phone. If the research entry box is only accessible from the macOS app, he'll still drop things in Telegram when he's on mobile. Consider: a Telegram command like `/research [topic] --depth standard` that feeds into the same pipeline. Same backend, different entry point.

5. **No archival/retention policy.** Research outputs accumulate. After 6 months, do we keep everything? Prune Quick Scans? This needs a decision, even if the answer is "keep everything, storage is cheap."

---

## 9. Recommended Build Priority

If Q is building this, here's the order I'd suggest:

| Phase | What | Why |
|-------|------|-----|
| 1 | Backend pipeline: depth levels, search plan, source collection, synthesis, HTML output | This is the engine. Without it, the UI is useless. |
| 2 | Knowledge base integration: dedup check, KB entry creation, indexing | This is what makes research compound. |
| 3 | BeeChat UI: entry box, depth selector, progress indicator, output viewer | The interface to the engine. |
| 4 | Sag integration: check scout files before web search | Cost saver + quality booster. Can come after MVP. |
| 5 | Telegram entry path: `/research` command → same pipeline | Mobile accessibility. |
| 6 | Feedback loop, cost tracking, history view | Polish. |

---

## 10. Summary

**Verdict:** Build it, but build the pipeline first, UI second. The value is in the process standardisation, not the input box.

**Keep it to 3 depth levels, 2 output formats, optional tags.** Don't over-option it.

**The single most valuable feature is deduplication against existing research.** If you only build one thing from this list, build that.

**The single biggest risk is cost runaway.** Make costs visible, not blocked.

**Integrate with Sag.** Free signal is sitting on the SSD. Use it.

**Don't build a database.** JSON index + HTML files + knowledge base entries. That's enough until it isn't.

---

*Gav — 2026-06-19*