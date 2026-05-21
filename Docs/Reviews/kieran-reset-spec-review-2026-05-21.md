# Adversarial Review — Session Reset Summary Injection Spec (v0.5.4)

**Reviewer:** Kieran
**Date:** 2026-05-21
**Status:** 🟡 CONDITIONAL APPROVE — 6 findings, 2 blockers, 4 improvements
**Spec:** `/Users/openclaw/Projects/BeeChat-v5/Docs/Fix-Specs/session-reset-summary-injection-spec.md`

---

## Executive Summary

The spec is a significant improvement over the previous raw-dump approach. Using `chat.inject` instead of prepending to the user message is the right call — it makes context visible, costs zero tokens, and avoids the race conditions inherent in `pendingResetContext`. The architecture direction aligns with what Adam approved: concise summary, no raw dump, visible reminder.

However, there are **2 blockers** that must be addressed before implementation, and **4 non-blocking but important findings** that should be resolved during build.

---

## 1. Alignment with Adam's Approved Direction

**Verdict: ✅ Aligned, with one caveat.**

The spec matches the approved direction:
- ✅ Concise summary via `chat.inject` — correct RPC, zero token cost
- ✅ No raw dump — `formatCombinedContext` is deleted entirely
- ✅ Visible reminder — `[SESSION-SUMMARY]` label appears in UI

**Caveat:** The summary target of "150–300 characters total" across 3 paragraphs is **too short to carry useful context**. Three paragraphs at ~250 chars averages ~83 chars per paragraph. That's ~15 words per paragraph. Example in spec is 308 chars — already over budget. This isn't a direction mismatch, but the numbers are internally inconsistent (Section 4 below).

---

## 2. Race Conditions & Edge Cases

### 2.1 BLOCKER: `chat.inject` During Active Stream

**Issue:** The auto-reset fires in a background `Task` from `sendMessage()`. If the user's message that triggered the reset generates a long response (tool use, streaming), `chat.inject` could fire **while a stream is in progress on the same session**.

The gateway docs state: "`chat.inject` appends an assistant note directly to the transcript and broadcasts it to the UI (no agent run)." But the docs don't specify behaviour when injected during an active run. Will it:
- Append after the current assistant turn? (good)
- Interrupt the current run? (bad)
- Get dropped because the session is mid-run? (bad)
- Corrupt the transcript ordering? (bad)

**Required:** The spec should either:
- (a) Abort generation before reset (the manual reset flow does this — `abortGeneration`), or
- (b) Wait for the current response to complete before injecting, or
- (c) Document why concurrent injection is safe

**Evidence:** The manual reset flow (Section 3.4) has `abortGeneration` guard. The auto-reset flow (Section 3.3) does not. This asymmetry is a bug waiting to happen.

### 2.2 Edge Case: Multiple Sessions, Single Topic Switch

**Finding:** Section 3.5 removes the `.onChange(of: selectedTopicId)` handler that cleared `pendingResetContext` on topic switch. This is correct — `pendingResetContext` is being deleted entirely. But the spec doesn't explicitly state what happens if auto-reset fires for Topic A while the user has already switched to Topic B.

Current code: auto-reset is keyed on `sessionKey`. If topics have different session keys, this is fine — each topic manages its own reset independently. If topics share a session key, the summary for Topic A gets injected into Topic B's session.

**Required:** Confirm that topic-to-session-key mapping is 1:1. If so, no action needed. If not, add a guard that the `resetKey` still matches the active topic before calling `chat.inject`.

### 2.3 Edge Case: Rapid User Sends During Auto-Reset

**Finding:** The spec removes the `didAutoReset` flag (Section 3.3, point 3). Previously this flag was used to skip topic context injection when auto-reset had prepended context. Now "topic context injection should always proceed."

If the user sends 3 messages rapidly:
1. Message 1 triggers auto-reset (usage ≥ 80%)
2. Messages 2, 3 arrive before reset completes
3. Summary is injected, then user messages 2, 3 are sent

Messages 2 and 3 are fine — they're normal user messages. But if the summary injection happens between message 1's processing and message 2, the assistant's response to message 1 will see the summary in context. Messages 2 and 3 will too. This is actually correct behaviour — the summary should be visible to all subsequent messages.

**Verdict:** Not a bug. The flag removal is correct. But the spec should explicitly document this as intentional, not an oversight.

---

## 3. Error Handling — `chat.inject` Fails After Reset

### 3.1 BLOCKER: Recovery Message Uses `try?` — Silent Failure

**Issue:** Section 4.1's fallback recovery message:
```swift
try? await rpcClient.chatInject(sessionKey: resetKey, message: recoveryMessage, label: "SESSION-SUMMARY")
```

If the primary inject fails, retry fails, AND the recovery message inject also fails (all via `try?`), the user has a wiped session with **zero context** and **no indication that anything went wrong**. The `try?` suppresses the error entirely.

**Required:** The recovery inject should be:
- (a) Not `try?` — let it throw so the catch block can log
- (b) Or: if it fails, set a flag that triggers the toast to say "Session reset — context not restored" instead of "Context carried forward"

The user should know when context was lost. A misleading "Context carried forward" toast when nothing was carried forward is worse than an honest error.

### 3.2 Improvement: Cooldown Shouldn't Update on Failed Reset

**Finding:** The cooldown and usage cache update happen inside the `if ok { ... }` block for the reset, which is correct. But the cooldown update (`resetCooldownCount[resetKey] = cooldown`) happens regardless of whether `chatInject` succeeded. This means a failed inject + successful reset will still suppress future auto-resets for N messages.

**Verdict:** Actually acceptable. The reset happened, so we should still cooldown to avoid hammering. The missing summary is degraded but the session is fresh. Not a blocker.

---

## 4. Summary Format Appropriateness

### 4.1 Finding: Character Budget vs. Paragraph Count Conflict

The spec says:
- "2–3 short paragraphs (target 150–300 characters total)"
- Paragraph 1: Topics
- Paragraph 2: Progress/Decisions
- Paragraph 3: Next steps

The example output is **308 characters** — already over the 300-char max. With 3 paragraphs at 300 chars total, each paragraph gets ~100 chars (~15-20 words). That's barely enough for "We discussed X. Decided Y." per paragraph.

**Recommendation:** Either:
- (a) Increase target to **200–400 characters** (still tiny in token terms — ~75-150 tokens), or
- (b) Reduce to **1–2 paragraphs** at 150-200 chars

At 300 chars, this is ~50-75 tokens. At 400 chars, it's ~75-100 tokens. The difference is negligible in the context window but significant for information density. I recommend **400 chars max, 1-2 paragraphs** — the third paragraph (next steps) is often guesswork for a rule-based extractor anyway.

### 4.2 Finding: Rule-Based Extraction May Produce Garbage

`formatSessionSummary` uses heuristic extraction (first sentence of user messages, last sentence of assistant messages). This will produce incoherent summaries when:
- User sends a code block with no prose
- Assistant responds with just "OK" or a tool call
- Conversation is mostly short back-and-forth ("yes", "no", "thanks")
- Messages are in a non-English language

The fallback for <3 messages or <50 chars is good, but the "3-29 messages with content" range could still produce gibberish.

**Recommendation:** Add a quality check after extraction. If the composed summary is just concatenated sentence fragments with no coherent flow, fall back to the minimal string: `"[SESSION-SUMMARY] Previous session covered recent topics. Full history available in memory files."`

This is better than a broken summary that misleads the agent.

---

## 5. Security & UX Concerns

### 5.1 UX: Label Duplication

Section 3.1 says the summary is prefixed with `[SESSION-SUMMARY]` in the formatted string. Section 3.3 passes `label: "SESSION-SUMMARY"` to `chatInject`. The gateway docs state: "The label parameter prefixes content with `[label]`."

So the resulting message will be:
```
[SESSION-SUMMARY] [SESSION-SUMMARY] We were discussing...
```

**Required:** Pick one. Either pass the prefix in the `message` and omit `label`, or omit the prefix from the message and use `label`. Don't do both. The spec acknowledges this ambiguity in Section 8.3 but punts the decision. It should be decided now.

**Recommendation:** Use `label: "SESSION-SUMMARY"` and don't prefix the message string. The gateway handles the formatting consistently.

### 5.2 Security: No New Attack Surface

The spec doesn't introduce any new security concerns. `chat.inject` is an existing gateway RPC, `sessions.reset` is existing, and the summary is locally generated. No user input flows into the summary (it's extracted from existing session messages, which are already in the transcript).

**Verdict:** ✅ No security concerns.

### 5.3 UX: Toast Timing

The "Context carried forward" toast fires on `didStopAutoReset`, which happens after the background Task completes. But if `chat.inject` takes a moment (network latency), the toast could appear before the summary is actually visible in the UI.

**Finding:** Minor. The summary will appear within a second or two. Not a blocker, but worth noting for QA.

---

## 6. `chat.inject` Approach Correctness

**Verdict: ✅ Correct.**

The gateway docs confirm:
- `chat.inject` appends an assistant note to the transcript
- Broadcasts to UI (no agent run)
- Zero token cost when used properly
- `label` parameter prefixes content with `[label]`

The spec's use of `chat.inject` is the right pattern. It's better than `chat.send` (which would trigger a new agent run) and better than prepending to the user message (which hides context and wastes tokens).

One note: the gateway docs say `chat.history` can truncate large fields. The summary at ~300 chars is well under any truncation threshold, so this is fine.

---

## 7. Code Completeness — Does the Spec Identify All Changes?

### 7.1 Verified Against Current Codebase

The spec correctly identifies all code that needs changing:

| Code Element | File | Spec Coverage |
|---|---|---|
| `pendingResetContext` property | `SyncBridge.swift:58` | ✅ Section 3.5 |
| `pendingResetContext` injection in `sendMessage` | `SyncBridge.swift:209` | ✅ Section 3.3 |
| `pendingResetContext` write in auto-reset | `SyncBridge.swift:251` | ✅ Section 3.3 |
| `pendingResetContext` guard in `manualReset` | `SyncBridge.swift:340` | ✅ Section 3.4 |
| `pendingResetContext` write in `manualReset` | `SyncBridge.swift:361` | ✅ Section 3.4 |
| `clearPendingResetContext` method | `SyncBridge.swift:373-379` | ✅ Section 3.5 |
| `clearPendingResetContext` call in `MainWindow` | `MainWindow.swift:206` | ✅ Section 3.5 |
| `formatCombinedContext` method | `SyncBridge.swift:432` | ✅ Section 3.1 |
| `[SESSION-CONTEXT]` filter in history fetch | `SyncBridge.swift:415` | ✅ Section 3.1 (filter list) |

### 7.2 Finding: Missing `[SESSION-CONTEXT]` Removal from History Filter

The history fetch filter at `SyncBridge.swift:415` excludes messages starting with `[SESSION-CONTEXT]`. Since we're deleting all `[SESSION-CONTEXT]` production code, this filter line becomes dead code. The spec's filter list in Section 3.1 includes `[SESSION-CONTEXT]` — this is fine as defensive coding (old sessions might still have these markers in SQLite), but the spec should note that this filter will eventually become unnecessary once old sessions age out.

**Verdict:** Not a blocker. Defensive filtering is fine.

### 7.3 Finding: `RPCClientProtocol` Stub Implementation Needed

The spec adds `chatInject` to `RPCClientProtocol`. Any mock/test implementations of this protocol (if they exist in the test target) will need stub implementations added. The testing checklist doesn't mention this.

**Required:** Add a line to the testing checklist: "Update any `RPCClientProtocol` mock implementations in test targets to include `chatInject` stub."

---

## 8. Blockers & Risks

### BLOCKER 1: No `abortGeneration` Guard in Auto-Reset Flow (Section 2.1)

Manual reset has it. Auto-reset doesn't. If auto-reset fires while a response is streaming, `chat.inject` could corrupt the transcript or interrupt the run. The auto-reset flow should call `abortGeneration(sessionKey:)` before resetting, matching the manual flow.

### BLOCKER 2: Recovery Message Swallows All Errors (Section 3.1)

Triple `try?` on the recovery path means total silent failure. User sees "Context carried forward" when nothing was carried. Must either propagate the error to the UI or use a different toast message when inject fails.

### Risk 1: Summary Quality May Be Poor

Rule-based extraction at 150-300 chars is fragile. If the summary is incoherent, the agent gets worse context than a raw dump (which at least contains the actual words). Mitigation: quality gate before composition, or fallback to minimal string.

### Risk 2: `chat.inject` May Behave Unexpectedly During Runs

Gateway docs don't specify behaviour. If it's unsafe during active runs, the spec needs a guard. If it's safe, the spec should document why.

### Risk 3: Label Duplication (Section 5.1)

If implemented as written, the summary gets `[SESSION-SUMMARY]` twice. Cosmetic but confusing.

---

## 9. Recommendations Summary

| # | Finding | Severity | Section | Action |
|---|---|---|---|---|
| 1 | No `abortGeneration` in auto-reset flow | **BLOCKER** | 2.1 | Add abort guard matching manual reset |
| 2 | Recovery message uses `try?` — silent triple failure | **BLOCKER** | 3.1 | Propagate error to UI or change toast |
| 3 | 150-300 chars too tight for 3 paragraphs | Improvement | 4.1 | Increase to 200-400 chars, reduce to 1-2 paras |
| 4 | Rule-based extraction may produce incoherent summaries | Improvement | 4.2 | Add quality gate before composition |
| 5 | Label duplication (`[SESSION-SUMMARY]` twice) | Fix | 5.1 | Pick one: message prefix OR label param |
| 6 | Missing test target protocol stub update | Improvement | 7.3 | Add to testing checklist |

---

## 10. Verdict

**CONDITIONAL APPROVE** — the spec is architecturally sound and represents a clear improvement over the current raw-dump approach. The `chat.inject` strategy is correct per gateway docs. All identified code changes are accurate.

However, the two blockers (abort guard, error propagation) must be addressed before implementation. The three improvements (character budget, quality gate, label dedup) should be resolved during the build.

Once blockers are fixed, this spec is ready for Q to implement.

---

*Kieran — adversarial reviewer. I break things so production doesn't have to.*
