# FR-003 Research Pipeline — Kieran Review (Cycle 2)

**Date:** 2026-06-19
**Reviewer:** Kieran (adversarial)
**Spec:** `Docs/Specs/Active/FR-003-RESEARCH-PIPELINE.md`
**Prior review:** `Docs/Specs/Active/FR-003-RESEARCH-ENTRY-KIERAN-REVIEW.md`
**Gav input:** `Docs/Specs/Active/FR-003-RESEARCH-ENTRY-GAV-INPUT.md`
**Verdict:** **Approve with conditions.** No BLOCKER-level issues. Two conditions to address before implementation starts; the rest are recommendations.

---

## 1. Architectural Alignment — Does the spec implement my recommendation?

**Yes, faithfully.** The spec adopts every architectural recommendation from my first review:

| Recommendation | Spec implementation |
|---|---|
| Slash command trigger, not UI entry box | ✅ `/research` in composer + Telegram |
| Server-side skill, not Swift UI | ✅ `research-pipeline` skill in OpenClaw |
| Zero Swift changes for MVP | ✅ Explicitly stated, Files Changed table confirms |
| Intelligence in OpenClaw, BeeChat stays thin | ✅ Bee routing only, Gav executes |
| Optional Mac-only UI as v2 (Phase 5) | ✅ Deferred to Phase 5, only if warranted |
| Don't build a database | ✅ JSON index |
| Dedup before re-searching | ✅ Stage 1, step 2 |

The spec correctly places the pipeline in the OpenClaw skill layer, routes through Bee, and keeps BeeChat as a text pipe. No shared package contamination. No Swift UI work. This is the right architecture.

---

## 2. Pipeline Design — Is it sound? Gaps from Gav's input?

The pipeline is well-structured. Gav's five-stage model (Intake → Collection → Analysis → Output → Follow-up) is preserved almost verbatim. The depth-level matrix (Quick/Standard/Deep) maps cleanly to search counts and source coverage.

### What made it in from Gav's input

- ✅ Three depth levels with correct search volumes
- ✅ Source weighting and confidence assessment
- ✅ Sag integration (check before web search)
- ✅ Cost observability (log, don't block)
- ✅ Concurrency model (one Deep Dive, two Quick Scans parallel)
- ✅ KB entry only for Standard/Deep (not Quick Scan — Gav explicitly recommended this)
- ✅ Telegram entry path (Gav flagged mobile as a gap in the original proposal)
- ✅ Feedback loop (👍/👎) — present in Phase 5, which is the right place

### Gaps — things Gav raised that didn't fully make it into the spec

**1. Source provenance requirement (minor gap).** Gav said: "Every claim in the output should link to its source. Not 'according to various sources' — actual links." The spec mentions "Every claim links to its source" in the KB entry section but doesn't enforce it in the HTML report section. The HTML report should have the same requirement — it's the primary output Adam sees.

**2. Conflict with existing knowledge (minor gap).** Gav raised: "If the pipeline discovers that our previous understanding was wrong, what happens?" The spec has conflict detection *between sources* (Stage 3, step 2) but doesn't address conflict with *existing KB entries*. This is a smaller gap than Gav implies — the simplest correct behaviour is "flag it in the report" — but the spec should state that explicitly.

**3. Retention policy (acknowledged omission).** Gav mentioned no archival/retention policy. The spec doesn't address it either. This is fine for MVP — "keep everything, storage is cheap" is the right default — but should be noted as a conscious decision, not an accidental omission.

**4. Watch list / monitor integration (deferred correctly).** Gav's "monitor this" follow-up and watch list integration with AI Digest is present in Stage 5 but lightly specified. That's acceptable — it's a Phase 5 feature, and over-specifying it now would be premature.

---

## 3. BLOCKER-Level Issues

**No blockers.** The spec is implementable as written. The conditions below are "fix before starting" quality, not "this won't work" quality.

---

## 4. Conditions (fix before implementation)

### C1: `research-index.json` needs a schema

The spec says "Simple JSON, not a database" — which is the right call. But it doesn't define the schema. Without a schema, the dedup check (Stage 1, step 2) and cost logging (Cost Management section) are underspecified.

**Required fields at minimum:**
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

Without `dedup_of`, the dedup feature can't work. Without `cost_gbp`, cost tracking can't aggregate. The skill needs to know what to write.

**Fix:** Add a "Research index schema" subsection to the spec with the required fields. Gav's ingest script will write them; the dedup check will read them.

### C2: `ingest.py` scope is unclear

The spec lists `scripts/ingest.py` as "Push output to knowledge base (wiki + memory)" but doesn't say what it does beyond that. Questions the implementer (Gav) will have:

- Does ingest.py run after every run, or only Standard/Deep?
- Does it call `wiki_apply`, `memory` write, or both?
- Does it create the KB markdown file, or does Gav write it during synthesis and ingest.py just indexes it?
- What's the input format — does it read the HTML, a separate JSON, or inline args?

**Fix:** Add 3-4 lines to the Implementation section describing ingest.py's contract: when it runs, what it reads, what it writes, what it calls. This is the single script that bridges research output and knowledge base — it needs to be unambiguous.

---

## 5. MVP Scope Assessment

**Scope is right.** Not too big, not too small.

**What's in MVP (Phase 1-4):**
- Skill definition + routing (Phase 1)
- KB integration + dedup (Phase 2)
- Sag integration (Phase 3)
- Telegram entry path (Phase 4)

**What's deferred (Phase 5):**
- UI panels, history view, cron research, multi-agent, cost dashboard, feedback loop

This is correct. Phase 1-4 is the minimum viable pipeline: trigger → research → output → persist. Phase 5 is polish. The phasing means Gav can build the core skill first and validate it before adding integration layers.

**One concern:** Phase 2 (KB integration) and Phase 3 (Sag integration) are listed as separate phases but are both part of the MVP. If Gav builds Phase 1 and tests it, then adds Phase 2, then adds Phase 3 — that's three iterations of the same skill. Consider whether Phase 1-3 should be built as one unit (the skill is incomplete without dedup and Sag). This is a build sequencing question, not a scope question. The scope is fine.

**Telegram entry path as Phase 4 is correct.** It's the same pipeline, different trigger. Building it last in the MVP set means the pipeline is validated via BeeChat first (easier to debug), then extended to Telegram (which should just work if the pipeline is sound).

---

## 6. Error Paths and Edge Cases

### Covered well

- Dead link (404) → report, suggest search
- No results → report, suggest broader terms
- Partial results → return what was found, flag incomplete
- API rate limit → wait and retry
- Pipeline crash → report error, log failure
- Duplicate topic → report existing, offer "go deeper"

These are the right six. They cover the realistic failure modes of a research pipeline.

### Missing or underspecified

**1. Sag files unavailable / SSD not mounted.** The spec assumes Sag's SSD is accessible. If it's not (drive disconnected, path changed), the pipeline should degrade gracefully — skip Sag, proceed with web search, note in report that Sag was unavailable. Not a blocker, but the skill should handle it without crashing.

**2. `wiki_apply` or memory write fails.** The KB ingestion path (Stage 4) assumes writes succeed. If `wiki_apply` fails (wiki locked, disk full), the HTML report should still be written and the chat summary still sent. KB ingestion is an enhancement, not a blocker for output delivery. The spec should state priority: HTML + chat first, KB second, and KB failure doesn't fail the run.

**3. Extremely long topics or ambiguous input.** What if Adam types `/research "ai"`? One word, extremely broad. The pipeline should either ask for clarification or default to a Quick Scan with a note that the topic is broad. The spec doesn't address pathologically short or ambiguous inputs. Minor, but worth a one-liner in error handling.

**4. Concurrent dedup race.** If Adam fires two `/research` on the same topic within seconds of each other, the dedup check in the second might run before the first has written its index entry. Both start fresh. This is a real but low-impact edge case — the worst outcome is duplicate research, not data corruption. Acceptable for MVP. Worth noting but not worth solving.

---

## 7. Success Criteria Assessment

### Testable and sufficient — mostly

The 10 success criteria are concrete and measurable. Each one has a clear pass/fail:

| # | Criterion | Testable? | Notes |
|---|---|---|---|
| 1 | Response time per depth | ✅ | Clear thresholds (3/12/25 min) |
| 2 | HTML report at expected path, opens, uses CSS | ✅ | Binary check |
| 3 | KB entry created with tags, source links, date | ✅ | Verify via memory_search |
| 4 | Telegram works identically | ✅ | Same checks from Telegram |
| 5 | Dedup message on re-search | ✅ | Run same topic twice |
| 6 | Sag files checked (visible in sources) | ✅ | Inspect report source list |
| 7 | Cost logged in index | ✅ | Inspect research-index.json |
| 8 | Progress message sent at start | ✅ | Observe chat |
| 9 | Error cases handled gracefully | ✅ | Test each error path |
| 10 | Research findable 2 weeks later | ⚠️ | This is a time-delayed test |

**Criterion 10 is a time-delayed test.** You can't verify it on day one. It's the right criterion — "if you can't find it later, the system failed" — but it needs a scheduled verification, not a build-day check. Suggest: verify the *mechanism* on build day (KB entry exists, is indexed, memory_search returns it), then schedule a 2-week follow-up to confirm it's still findable.

### Missing success criteria

**11. Source provenance in HTML report.** Every claim in the HTML report should link to its source. This should be a success criterion, not just a design note. Gav explicitly called this out as a must-have.

**12. HTML report renders correctly in browser.** Criterion 2 says "opens in browser, uses standard CSS" but doesn't mention readability. The report should be readable — not just CSS-linked but actually formatted correctly (sections, headings, links work). A quick visual check, not a full QA pass.

---

## 8. Other Observations

### Model selection table is sensible but unenforceable

The spec says Deep Dive uses "Grok 4.3 (search) + MiniMax-M3 (synthesis)". This is a configuration detail that will change as models evolve. The skill should document this as the *current* recommendation, not a hard requirement. If MiniMax-M3 is unavailable one day, the pipeline should fall back to the default model rather than fail. The spec doesn't say "fall back" — it implies hard model selection. Worth clarifying: "preferred model, fall back to default if unavailable."

### Cost estimates are reasonable but unverified

Gav's estimates (£0.05/£0.15/£0.60) are plausible but based on rough token counts. Actual costs will depend on search result sizes and synthesis length. The £50/week flag threshold is a good guardrail. No issue here — just noting that the estimates will need calibration against actual runs.

### Concurrency model is simple and correct

One Deep Dive at a time, two Quick Scans in parallel, Standard queues behind Deep Dive. This is the right balance — simple to implement, prevents API rate limit issues, and Quick Scans stay responsive. No concerns.

### Review checklist at the bottom is good practice

The 10-item review checklist is a good self-audit list. It's not part of the success criteria (which are the build-acceptance tests) — it's a post-build verification list. That separation is correct.

---

## 9. Summary

| Question | Answer |
|---|---|
| Does the spec implement my architectural recommendation? | **Yes, fully.** Slash command, server-side skill, zero Swift changes. |
| Is the pipeline design sound? | **Yes.** Five-stage model, three depths, correct source weighting. |
| Any gaps from Gav's input? | **Two minor:** source provenance in HTML, conflict with existing KB. Both small. |
| BLOCKER-level issues? | **No.** |
| Is the MVP scope right? | **Yes.** Phases 1-4 are the minimum viable pipeline. Phase 5 is correctly deferred. |
| Missing error paths? | **Three minor:** Sag unavailable, KB write failure, pathologically short input. All low-impact. |
| Success criteria testable? | **Yes, 9/10 immediately.** Criterion 10 needs a scheduled 2-week follow-up. Add 11 (provenance) and 12 (rendering). |

---

## 10. Recommendation

**Approve the spec with two conditions:**

1. **C1:** Add `research-index.json` schema (required fields, especially `dedup_of` and `cost_gbp`).
2. **C2:** Define `ingest.py`'s contract (when it runs, what it reads, what it writes, what it calls).

**Plus four non-blocking recommendations:**

1. State that KB ingestion failure doesn't fail the run (HTML + chat are primary output).
2. Add graceful degradation when Sag's SSD is unavailable.
3. Add source provenance as a success criterion (claims link to sources in HTML report).
4. Clarify model selection as "preferred, fall back to default if unavailable."

**The spec is ready for implementation once C1 and C2 are addressed.** The architecture is sound, the scope is right, and the pipeline design faithfully captures Gav's operational expertise without over-engineering.

---

*Kieran — 2026-06-19*