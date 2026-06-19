# Q Review: Topic Summary Pipeline (Phase 2)

**Reviewed by:** Q (developer lens: buildability & technical feasibility)
**Date:** 2026-05-31T20:25:00+01:00
**Spec reviewed:** `TOPIC-SUMMARY-PIPELINE.md`
**Phase 1 reference:** `TOPIC-PROJECT-CONTINUITY.md` (approved, v4)

---

## Summary Verdict: CONDITIONAL

The spec is conceptually sound and builds on real Phase 1 infrastructure, but it has **two critical gaps** that block immediate implementation:

1. **The primary trigger (LCM compaction hook) does not exist in the BeeChat-v5 codebase.** There is no compaction event, no callback registration point, and no gateway event type for this. The spec assumes infrastructure we don't have.
2. **The spec proposes spawning a sub-agent from inside a macOS app actor.** BeeChat-v5 has no agent-spawning capability — that's an OpenClaw gateway/server concern. The app communicates via JSON-RPC to a separate gateway; it cannot itself spawn `sessions_spawn` subagents.

These are not nitpicks. They are fundamental architecture questions that determine whether this is a BeeChat-only change or requires upstream OpenClaw work. The spec acknowledges this in the "compaction hook fallback" section but doesn't resolve it.

With those resolved (see critical issues below), the rest of the spec is implementable.

---

## Critical Issues (must fix before build)

### C1: No compaction hook exists in the gateway or app

**The spec's primary trigger is "OpenClaw's LCM compaction fires an internal event when a session is compacted."** I searched the entire BeeChat-v5 codebase — no `compaction`, `compacted`, or LCM-related code exists. `GatewayEvent` enum has no compaction variant. `SyncBridge` has no callback registration for compaction. `RPCClient` has no RPC method for it.

**Reality:** LCM compaction is an OpenClaw server-side concern. The gateway protocol (Section 4.3 says "gateway can register a callback") would require:
- A new gateway event type (e.g., `session.compacted`)
- An upstream change to OpenClaw core to fire this event
- A new `RPCClient` method or gateway subscribe path

The spec's own "poll `sessionsPluginState` every 5 minutes" fallback is actually the more realistic path — **but there is no `sessionsPluginState` in the codebase either.** The `sessions.list` RPC exists and returns `SessionInfo` (key, label, agentId, totalTokens), but there's no compaction marker field.

**Fix:** Make the quiet-period timer + manual "Save Topic" the **only** triggers for Phase 2. Remove compaction hook entirely. If/when OpenClaw adds a compaction webhook/event, it can be wired in later. This removes the dependency on upstream changes and unblocks implementation now.

### C2: Agent spawning is not an app capability

**Section 4.2 says:** "Gateway spawns a lightweight sub-agent with the topic's compacted LCM summary." But BeeChat-v5 has no way to spawn subagents. `sessions_spawn` is an OpenClaw tool, not a BeeChat RPC method. The macOS app is a client, not a server.

The extraction prompt workflow (Section 3.3) requires an LLM to read compacted conversation data and extract structured items. The app cannot do this itself — it would need to:
- Send the compacted summary text to the gateway
- Have the gateway spawn a subagent
- The subagent calls `TopicSummaryWriter.write()` — which is Swift code on the Mac

**This means the file write happens on the Mac, but the extraction happens on the server.** The current spec mixes these concerns: `TopicSummaryExtractor` is described as both a spawned agent AND something that calls `TopicSummaryWriter.write()` (Swift). A spawned agent cannot call Swift code directly.

**Fix:** Two options:
- **Option A (simpler):** Do the extraction **on the Mac**. Send the compacted summary to a local model (or just use the gateway's `chat.send` with a structured prompt), parse the response in Swift, then write via `TopicSummaryWriter`. No subagent needed — just a chat call with a system prompt.
- **Option B (cleaner but requires gateway change):** The gateway spawns the agent, the agent returns structured JSON (decisions/corrections/state), the Mac receives this via a new gateway event and writes via `TopicSummaryWriter`. Requires a new gateway event type and RPC subscribe.

**Recommendation: Option A for Phase 2.** It's fully implementable within BeeChat-v5 without upstream changes. Use `chat.send` with the extraction prompt (Section 3.3) to a session, capture the response text, parse it in Swift, and write. This is ~50 lines of new code vs. needing a new gateway protocol.

### C3: `TopicSummaryWriter` Swift API doesn't match its responsibilities

The spec's `TopicSummaryWriter` signature:

```swift
public static func write(
    topicId: String,
    topicName: String,
    projectPath: String?,
    workspacePath: String,
    summaryContent: String
) -> String?
```

This is a **pure Swift utility** that writes to disk. But Section 4.2 says the spawned sub-agent "calls `TopicSummaryWriter.write()`." **A spawned OpenClaw agent cannot call Swift code.** The sub-agent runs in OpenClaw's runtime with `read`/`write`/`exec` tools — it writes files directly via its own tool, not via BeeChat's Swift enum.

There are two file-writing paths here and they're conflated:
1. **Swift writes** (for manual "Save Topic" UI trigger) — `TopicSummaryWriter` is correct
2. **Agent writes** (for spawned subagent) — the agent uses its own `write` tool

The merge logic is the tricky part. If the Swift utility does merging, the spawned agent can't use it. If the spawned agent does merging via its `write` tool, the Swift utility needs different logic. They diverge.

**Fix:** Consolidate. All writes go through `TopicSummaryWriter` (Swift). The extraction step (whether Option A or B above) returns structured data, and `TopicSummaryWriter` handles the file I/O + merging. This keeps merge logic in one place.

---

## Warnings (should fix, not blockers)

### W1: Workspace path assumption is hardcoded and wrong for Phase 1 patterns

Section 3.2 says unbound topics go to `workspace/docs/topics/unbound/` and Section 4.1 hardcodes:

```swift
private static let unboundDir = "/Users/openclaw/.openclaw/workspace/docs/topics/unbound/"
```

But Phase 1's `ProjectContextReader` validates paths against `/Users/openclaw/Projects/`. Topic summary files are **not** in the project path — they're a sibling concern. The `validatePath` method would reject the workspace path. The spec says "Never error or skip because a topic lacks a project binding" but the existing path validation from Phase 1 would block this.

**Fix:** `TopicSummaryWriter.validatePath()` needs a **different** allowed prefix set — include both `/Users/openclaw/Projects/` (for project-bound) AND `/Users/openclaw/.openclaw/workspace/` (for unbound). Or better: validate against a configurable allowed-roots set.

### W2: Merge logic is underspecified

Section 4.1 says "Merges with existing summary (update timestamp, append new decisions, don't duplicate existing entries)" but doesn't specify **how** deduplication works. Decision text like "Going with SQLite" could appear with slight variations ("Use SQLite" vs "Going with SQLite") and naive string matching would create duplicates.

**Fix:** At minimum, do exact-string dedup. At best, use a normalized key (lowercased, trimmed, first 50 chars) for dedup. Document the merge algorithm explicitly. The 4KB cap in Section 8 means merge quality matters — noisy duplicates eat the budget fast.

### W3: Quiet-period timer at 30-minute scan interval is expensive for what it does

Scanning all topics every 30 minutes, checking last-message timestamps, and spawning extraction agents for anything >2h old is fine for small topic counts. But it will fire on **every** topic that's been inactive, including ones that were already summarized. Need a "last summarized" timestamp to avoid re-summarizing the same conversation repeatedly.

**Fix:** Store `lastSummarizedAt` on the topic (in `metadataJSON`) or in the summary file's "Last updated" timestamp. The quiet-period scan should skip topics where `lastSummarizedAt` is more recent than `lastActivityAt`.

### W4: "No new memory structures" is contradicted by the spec itself

Section 2 goal #4 says "No new memory structures" but Section 3.2 creates `docs/topics/{topic-id}-summary.md` — a new file type per topic that didn't exist before. This is fine, it's just a new convention. But it means the Phase 1 `ProjectContextReader` **must be updated** to include these topic summary files in its context file list. The spec says this in Section 7 but doesn't list it in the "Files to Modify" table.

**Fix:** Add `ProjectContextReader.swift` to the "Files to Modify" table with the specific change: add `docs/topics/{topic-id}-summary.md` as a conditional read when `topicId` is provided.

### W5: The extraction prompt is good but lacks structured output guarantee

Section 3.3's extraction prompt is well-crafted but returns free-form markdown. The Swift code that parses this response needs to handle variations. If the agent returns a slightly different format, the parser breaks.

**Fix:** Either:
- Require a **strict JSON output format** from the extraction agent (easier to parse in Swift)
- Or use regex-based extraction with fallback patterns (more fragile)

JSON is cleaner. The prompt can say: "Output JSON with keys: decisions[], corrections[], state_changes[], open_questions[]. Return empty arrays if nothing found."

### W6: 4KB summary cap might be too tight for active topics

Section 8 caps at 4KB keeping "last 5 decisions and 3 open questions." But real project discussions can have more durable items than that. A complex spec review session could produce 8+ decisions. The cap silently discards information.

**Fix:** Bump to 8KB. The context budget is 100K+ tokens — 8KB is 2K tokens, negligible. If summaries are well-structured (Section 3.3 extraction), they'll be dense and useful.

---

## Observations (nice-to-have, future considerations)

### O1: Manual "Save Topic" is the MVP

Honestly, if you ship **only** the manual "Save Topic" UI trigger + `TopicSummaryWriter` + `buildContextHeader` extension, you get 80% of the value. Adam knows when something important happened and can hit Save. The automation (compaction, quiet-period) is nice but adds significant complexity for incremental benefit.

### O2: Topic summary files could double as the `ACTIVITY.md` that Phase 1 deferred

Phase 1's Approach B (Auto Write-Back) was deferred. The topic summary files created by this spec serve the same purpose: they capture durable knowledge from conversations. If the extraction prompt is good, there's no separate need for `ACTIVITY.md`.

### O3: The spec doesn't address what happens when a topic's project binding changes after a summary exists

If topic T1 was bound to Project A, got summarized, then re-bound to Project B — the summary file lives in `Project A/docs/topics/`. Phase 1's `ProjectContextReader` for Project B won't find it. This is an edge case but not impossible.

### O4: `TopicSummaryExtractor` as described is really just a prompt + API call

The spec describes `TopicSummaryExtractor` as a new component (Section 4.2, Section 6 file list). But its entire job is: take text → send to LLM with a prompt → parse response → write file. This could be a single method on `SyncBridge` or a free function. A separate component file is fine for organization, but it shouldn't be over-engineered.

### O5: No iOS path for summaries

The spec mentions iOS delegation in the risk table: "iOS calls gateway RPC to request summary extraction from the Mac." But there's no RPC method for this in the current `RPCClientProtocol`. Would need a new `topic.summaryExtract(topicId:)` RPC call.

---

## Answers to Specific Questions

### 1. Can this be built with the existing BeeChat-v5 codebase?

**Partially.** `TopicSummaryWriter` (Swift file I/O with merge), the "Save Topic" UI, and the `buildContextHeader` extension are all buildable within BeeChat-v5. The **compaction hook trigger** and **subagent spawning** are NOT available in the current codebase — they require either upstream OpenClaw changes or a re-architecture to do extraction locally via `chat.send`.

### 2. Does it require changes to OpenClaw's gateway protocol or core?

**Yes, if you want the compaction-trigger path.** A new gateway event type and RPC subscribe for compaction events would be needed. The quiet-period timer + manual trigger path does NOT require gateway changes — it's entirely app-side.

### 3. Are the file I/O operations (TopicSummaryWriter) sound?

**Almost.** Path validation needs adjustment (W1 — must allow workspace root for unbound topics). Merge logic needs explicit dedup algorithm (W2). The synchronous, non-throwing, actor-safe design is correct. The 4KB cap is defensible but tight (W6 → recommend 8KB). File locking with `.atomic` write is a good choice for concurrency.

### 4. Is the extraction prompt approach practical? Token/cost concerns?

**Practical, yes.** The prompt is well-crafted and narrow. ~2K tokens input + ~500 tokens output is correct for the estimate. At typical pricing, that's fractions of a cent per extraction. **However**, the subagent spawning approach won't work from the Mac app. Use Option A (chat.send with extraction prompt) to keep it app-side and avoid the spawning complexity.

### 5. Are the unit tests and integration tests feasible?

**Yes, with adjustments.** The unit tests for `TopicSummaryWriter` are straightforward with temp directories. The integration tests for the extraction prompt need a live LLM call (or a mocked `chat.send` response). The context injection test is just verifying `buildContextHeader` output contains the expected section. The "iOS delegation" manual test is not feasible until a new RPC method exists.

### 6. Does it correctly build on Phase 1?

**Yes, but with one missing link.** Phase 1's `ProjectContextReader` needs to be extended to read topic summary files when a `topicId` is available. The spec mentions this in Section 7 but doesn't reflect it in the implementation plan. The `buildContextHeader` extension is correctly scoped as an additive change.

### 7. Can this be done more simply?

**Yes. Start with manual trigger only.** Ship:
1. `TopicSummaryWriter.swift` — file I/O + merge
2. "Save Topic" context menu — UI trigger
3. `buildContextHeader` extension — inject summary on re-entry
4. `ProjectContextReader` update — read summary files

That's 3-4 hours of work, zero gateway changes, zero upstream dependencies. The compaction hook and quiet-period timer are Phase 2.5 additions.

### 8. Technical risks, edge cases, gotchas?

| Risk | Concrete scenario | Severity |
|---|---|---|
| **No compaction event** | Spec's primary trigger doesn't exist. Entire automation layer is blocked. | High |
| **Subagent can't call Swift** | Extraction agent writes its own file, bypassing merge logic. Duplicate or corrupted summaries. | High |
| **Merge without dedup** | "Decided on SQLite" + "Going with SQLite" appear as two decisions. Summary degrades over time. | Medium |
| **Summary file in wrong project** | Topic re-bound to new project. Old summary lives in old project folder, never read. | Low |
| **Race: two saves simultaneously** | Manual save + quiet-period save fire at same time. `.atomic` write helps but merge reads a stale file. | Low |
| **Extraction prompt false positive** | "Let's explore SQLite" (brainstorming) extracted as a decision. Summary file accumulates noise. | Medium |
| **Token budget on re-entry** | Summary file injected + Phase 1 project files injected. Combined could exceed budget for large projects. | Low (already guarded by 50KB cap) |

---

## Implementation Notes (expected file changes)

### New files
| File | Purpose |
|---|---|
| `Sources/BeeChatSyncBridge/Utilities/TopicSummaryWriter.swift` | File I/O, merge logic, path validation (expanded allowed prefixes) |
| `Sources/BeeChatSyncBridge/Utilities/TopicSummaryExtractor.swift` | Extraction prompt construction, `chat.send` call, response parsing |

### Modified files
| File | Change |
|---|---|
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Add `triggerTopicSummary(topicId:)` async method; add quiet-period timer setup |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` (`buildContextHeader`) | Add `[TOPIC-SUMMARY]` section after `[PROJECT-CONTEXT]` when summary file exists |
| `Sources/BeeChatSyncBridge/Utilities/ProjectContextReader.swift` | Add optional `topicId` parameter; when provided, also read `docs/topics/{topicId}-summary.md` |
| `Sources/BeeChatSyncBridge/Utilities/ProjectFileProvider.swift` | Add summary file to the list of files read (or keep as separate read — either works) |
| `Sources/App/UI/ViewModels/TopicViewModel.swift` | Add `saveTopic()` async method (delegates to SyncBridge) |
| `Sources/App/UI/Components/SessionRow.swift` | Add "Save Topic" context menu button |
| `Sources/BeeChatSyncBridge/RPCClient.swift` | (If Option B) Add `topicSummaryExtract` RPC method |
| `Sources/BeeChatGateway/Protocol/GatewayEvent.swift` | (If Option B) Add `topicSummaryReady` event case |

### Test files
| File | Purpose |
|---|---|
| `Tests/BeeChatSyncBridgeTests/TopicSummaryWriterTests.swift` | Write, merge, dedup, path validation, size cap tests |
| `Tests/BeeChatSyncBridgeTests/TopicSummaryExtractorTests.swift` | Prompt construction, response parsing (mock LLM) |
| `Tests/BeeChatSyncBridgeTests/BuildContextHeaderTopicSummaryTests.swift` | Verify `[TOPIC-SUMMARY]` injection when file exists |

---

## Revised Implementation Order (simpler first)

1. **`TopicSummaryWriter`** — Pure Swift, no dependencies, testable immediately
2. **`buildContextHeader` upgrade** — Add `[TOPIC-SUMMARY]` injection
3. **`ProjectContextReader` update** — Read summary files when `topicId` available
4. **Manual "Save Topic" UI** — Context menu + `TopicSummaryExtractor` via `chat.send`
5. **Quiet-period timer** — 30-minute scan with `lastSummarizedAt` dedup
6. **Tests** — Unit + integration
7. **(Future)** Compaction hook — when/if OpenClaw adds the event

**Estimated effort (revised):** 4-5 hours for steps 1-4 (manual-only). 2-3 additional hours for step 5 (quiet-period). Compaction hook: TBD depending on OpenClaw API.
