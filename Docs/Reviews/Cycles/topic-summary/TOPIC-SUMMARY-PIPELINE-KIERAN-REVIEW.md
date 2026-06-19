# Kieran Review: Topic Summary Pipeline (Phase 2)

**Reviewed:** 2026-05-31T20:19:00+01:00
**Reviewer:** Kieran (adversarial reviewer)
**Spec:** `TOPIC-SUMMARY-PIPELINE.md`
**Parent spec:** `TOPIC-PROJECT-CONTINUITY.md` (Phase 1 — reviewed and approved)

---

## Verdict: CONDITIONAL

The spec is directionally right — riding on LCM compaction and existing project files is the correct architectural instinct. But several critical assumptions are hand-waved, the 4KB cap is mentioned in the risk table but absent from the actual design, and the compaction hook is treated as a given when it may not exist. The extraction prompt is too brittle for production use. Fix the critical items before build.

---

## Critical Issues (must fix before build)

### C1: Compaction hook existence is assumed, not verified

Section 4.3 says "OpenClaw's LCM compaction fires an internal event. The gateway can register a callback on this event." **Can it?** The spec doesn't cite any OpenClaw API, method name, or event type. This is the primary trigger — the entire pipeline hinges on it — and the spec provides zero evidence that this callback mechanism exists or is accessible from gateway/plugin code.

The poll fallback (5-minute poll of `sessionsPluginState`) is equally vague. What's the "compaction marker"? What field in `sessionsPluginState` indicates a session has been compacted? The spec doesn't define the signal to look for.

**Demand:** Before implementation starts, Adam or Bee must confirm the compaction hook exists in the current OpenClaw version. Either:
- Show the actual API/callback registration point (method name, event name), OR
- Implement Phase 2 on the poll fallback + manual trigger only, and treat the compaction hook as a future upgrade.

Building on a trigger that may not exist is a waste of hours.

### C2: 4KB summary cap is in the risk table but absent from the design

Section 8 (Risk Assessment) says "Cap summary file at 4KB. Oldest entries get trimmed." Section 3.2 (Summary Format), Section 3.3 (Extraction Rules), and Section 4.1 (TopicSummaryWriter) **never mention this cap.** The writer's merge logic is described as "append new decisions, don't duplicate existing entries" with no mention of size enforcement.

This is a classic spec bug: a mitigation was added to the risk table but never propagated into the actual design. Without explicit cap logic in the writer, the summary file will grow without bound on long-running topics.

**Demand:** The 4KB cap (or whatever limit) must be specified in Section 3.2 and implemented in `TopicSummaryWriter.write()`. Define the trimming policy precisely: which sections get trimmed first? How many decisions are retained? What happens when a single decision exceeds the cap?

### C3: Extraction prompt is too brittle for real conversations

The extraction prompt (Section 3.3) asks the agent to look for phrases like "let's do X", "agreed on", "we decided", "going with." **Real decisions don't announce themselves with neat signal phrases.** Consider:

```
User: Should we use SQLite or Core Data for the local cache?
Agent: Given the app is macOS-only and you want minimal dependencies, SQLite is simpler.
User: Fine, let's do that then.
```

This contains "let's do that" — the prompt would catch it. But what about:

```
User: I think the polling interval is too aggressive at 30 seconds.
Agent: 30s is indeed high. What feels right?
User: Let's back it off a bit.
Agent: How about 5 minutes?
User: Yeah, that works.
```

The decision (5-minute polling interval) is spread across four turns. There's no clean "we decided" phrase. The agent would have to *infer* the decision from conversational context. The prompt says to look for explicit phrases, but this decision would likely be missed.

Conversely, false positives are easy:

```
User: Let's do lunch after this meeting.
Agent: Sure!
```

"Let's do" → false positive decision extraction. The prompt says to look for that exact phrase pattern.

**Demand:** The extraction prompt needs a relevance filter, not just a phrase matcher. Rewrite to:
- Require the decision to be *about the project* (project name must appear in context)
- Require a *specific, actionable* outcome (not just "let's do something")
- Include negative examples in the prompt ("Do NOT extract: social plans, tool preferences, debugging attempts that didn't converge")
- Test against at least 5 real conversation transcripts before shipping

### C4: TopicSummaryWriter has no concurrency guard beyond a hand-waved "file locking"

Section 8 says "`TopicSummaryWriter` uses file locking (`.atomic` write with exclusive lock). Second writer retries." Section 4.1 (the actual Swift API definition) **doesn't mention locking at all.** It's a synchronous `write()` method that takes `summaryContent` as a string. Where does the merge happen? Inside the method? In the spawned agent before calling write?

If three triggers fire simultaneously (compaction + quiet-period + manual save for the same topic), you get three spawned agents, each reading the current summary, merging, and writing. Without a proper mutex or optimistic-concurrency check, the last writer wins and the other two updates are silently lost.

**Demand:** Define the concurrency model explicitly. Options:
- **Serial queue:** One summary write per topic at a time. Queue extras, drop duplicates.
- **Optimistic concurrency:** Read file, compute diff, write with file existence check. Retry on mismatch.
- **Append-only log + periodic compaction:** Each trigger appends a timestamped entry to a `.log` file. A background process compacts into the summary. Eliminates merge conflicts entirely.

Pick one and specify it in the design, not just the risk table.

---

## Warnings (should fix, not blockers)

### W1: Unbound directory is hardcoded to a user-specific path

Section 4.1: `private static let unboundDir = "/Users/openclaw/.openclaw/workspace/docs/topics/unbound/"`

This is hardcoded to a specific user and machine. If Adam moves his workspace, changes machines, or if the workspace path is configurable at runtime, this breaks. The method signature takes `workspacePath` as a parameter but then ignores it in favor of the hardcoded default.

**Fix:** Use the `workspacePath` parameter. Remove the hardcoded default, or make it a configurable default that can be overridden at runtime.

### W2: [TOPIC-SUMMARY] context injection has no budget guard

Phase 1 has a 50KB combined context budget guard (Kieran Warning-3 from Phase 1 review). Phase 2 appends `[TOPIC-SUMMARY]` to the context header (Section 3.4) but **doesn't account for its size in the budget calculation.**

If the summary file hits the 4KB cap (C2), that's 4KB added to every topic re-entry message. Combined with Phase 1's 16KB project context injection, you're at 20KB before the conversation even starts. That's fine in isolation but the budget guard needs to know about this new section.

**Fix:** Include `[TOPIC-SUMMARY]` content in the combined context-size guard. If summary + project context + auto-reset exceeds 50KB, trim summary first (it's most likely to be stale), then project context, then auto-reset.

### W3: Quiet-period scan at 30 minutes may miss the 2-hour window edge case

Section 4.4: "Every 30 minutes, scan active topics for last-message timestamp. If >2 hours since last message, trigger extraction."

Edge case: A topic has its last message at T+0:00. The scan runs at T+0:30 (30 min, no trigger), T+1:00 (60 min, no trigger), T+1:30 (90 min, no trigger), T+2:00 (120 min — exactly at threshold, may or may not trigger depending on `>=` vs `>`). If the scan at T+2:00 doesn't trigger (strict `>`), the topic waits until T+2:30.

This is minor but reveals a deeper issue: **the quiet-period timer and compaction trigger can both fire for the same topic within minutes of each other**, producing duplicate summaries. The merge logic needs deduplication (mentioned briefly in the extraction prompt but not specified).

**Fix:** Add a "last summary written" timestamp to the summary file. The quiet-period scan should skip topics that were summarized within the last 30 minutes. This prevents duplicate extractions.

### W4: Agent spawn cost is underestimated

Section 8 says "Summary extraction is lightweight (~2K tokens input, ~500 tokens output). Triggered at most a few times per topic per day."

For a single topic, sure. But consider Adam's workflow: he might have 10-20 active topics. If a quiet-period scan triggers summaries for 5 topics simultaneously, that's 5 agent spawns. Each spawn involves:
- Gateway overhead (session creation, context setup)
- Model inference (even "lightweight" models cost something)
- File I/O

At 3 topics per day × 15 active topics = 45 spawns per day. That's non-trivial. And it doesn't account for bulk compaction (if Adam clears his inbox or resets sessions, triggering mass compaction).

**Fix:** Add a spawn rate limit. Maximum N summary extractions per minute. Queue excess. Also consider batching: if multiple topics are due for quiet-period summary in the same 30-minute window, process them in a single spawned agent with a batch extraction prompt.

### W5: Summary format is append-only but merge logic is underspecified

The summary format has sections: Last State, Decisions, Open Questions, Recent Activity. The extraction prompt says "Merge with existing summary if one exists (update timestamp, append new decisions, don't duplicate existing entries)."

But what does "merge" actually mean for each section?
- **Last State:** Replace entirely? Or append?
- **Decisions:** Append new ones. Check for duplicates by exact string match? What if the same decision is rephrased?
- **Open Questions:** How does a question get *removed* when it's answered? Does it move to a "Resolved Questions" section? Or does it linger forever?
- **Recent Activity:** Append? Cap at N entries?

Without precise merge semantics, the merge implementation will be inconsistent.

**Fix:** Define per-section merge rules:
- Last State → replace (always reflects current state)
- Decisions → append, dedup by fuzzy match (same decision rephrased)
- Open Questions → append new, remove when answered (how does the extractor know it's answered?), cap at 5
- Recent Activity → append, cap at last 10 entries

### W6: iOS delegation for summary writes is mentioned in verification but not in the architecture

Section 9 (Manual Tests) includes "iOS delegation — From the iPhone app, trigger 'Save Topic.' Verify the Mac writes the summary file." But Section 4.2 only says "SyncBridge spawns TopicSummaryExtractor via sessions_spawn (or gateway RPC if running on iOS)." There's no actual iOS → Mac RPC design.

Phase 1 solved this with the `ProjectFileProvider` protocol. Phase 2 needs an equivalent for summary writes.

**Fix:** Add a `TopicSummaryWriterProvider` protocol (parallel to Phase 1's approach). macOS implements direct file write. iOS implements gateway RPC. Both call sites use the protocol.

---

## Observations (nice-to-have, future considerations)

### O1: Simpler alternative — just save the LCM compacted summary

The entire extraction pipeline exists because we want *structured* durable knowledge (decisions, corrections, state). But the LCM compaction already produces a summary of the conversation. **What if we just saved that summary directly as the topic file, without the extraction step?**

Pros:
- No spawned agent needed for extraction (the summary already exists)
- No extraction prompt to maintain or debug
- No false positive/negatives from extraction
- Captures everything, not just what the extractor thinks is "durable"

Cons:
- Less structured — no separated decisions/corrections sections
- May include noise that the extraction step would filter out
- Larger file sizes

**80/20 assessment:** Saving the raw LCM summary gets you topic continuity (the primary goal — "when Adam returns, the agent knows what was discussed") at near-zero implementation cost. The extraction step adds structure but also adds complexity, cost, and failure modes. Consider shipping with raw LCM summary first, then adding extraction as an enhancement once the pipeline is stable.

### O2: The summary file should be human-editable

If Adam opens a topic summary file and finds garbage, he should be able to edit it directly. The current format supports this (it's plain markdown), but the spec should explicitly state: "Summary files are designed for both agent and human consumption. Adam can edit them directly at any time."

### O3: Consider a "summary quality feedback" loop

If the agent reads a topic summary and finds it unhelpful, there's no feedback mechanism. A simple approach: the agent could flag summaries that seem stale or unhelpful (e.g., if the summary says "we decided X" but the conversation immediately contradicts X). Over time, this data could improve the extraction prompt.

### O4: The manual "Save Topic" trigger is the most reliable part of this spec

Compaction hooks may not exist. Quiet-period timers may fire at awkward times. But Adam knows when something important happened. The manual save trigger should be the most polished part of the UX, not an afterthought. Consider making it a keyboard shortcut (Cmd+S on the topic) in addition to the context menu.

---

## Summary of Required Changes Before Build

| # | Issue | Section | Effort |
|---|---|---|---|
| C1 | Verify compaction hook exists or defer to poll/manual | 4.3 | Investigation |
| C2 | Propagate 4KB cap into design + writer spec | 3.2, 4.1 | 30 min |
| C3 | Rewrite extraction prompt with relevance filter + negative examples | 3.3 | 1 hour |
| C4 | Define explicit concurrency model for summary writes | 4.1 | 30 min |
| W1 | Use `workspacePath` parameter, remove hardcoded default | 4.1 | 5 min |
| W2 | Add [TOPIC-SUMMARY] to context budget guard | 3.4 | 15 min |
| W3 | Add "last summary written" timestamp + dedup window | 4.4 | 15 min |
| W4 | Add spawn rate limit + consider batch extraction | 4.2 | 30 min |
| W5 | Define per-section merge semantics | 3.2 | 15 min |
| W6 | Add iOS → Mac RPC design for summary writes | 4.2 | 30 min |

**Recommendation:** Fix C1-C4, address W1-W6 in implementation, then build. The simpler alternative (O1 — save raw LCM summary) is worth a serious conversation with Adam before committing to the full extraction pipeline.
