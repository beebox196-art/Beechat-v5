# Spec Review Synthesis — BC5-SPEC-004

**Date:** 2026-05-08  
**Synthesised by:** Bee (coordinator)  
**Reviews:** Q (implementation), Mel (UX), Kieran (safety/completeness)

---

## Consensus

All three reviewers **approve Phase 1** (topic context injection) with specific conditions. All three **recommend deferring Phase 2** (resume context) or significantly simplifying it. Phase 3 (agent-side convention) is approved as-is.

**Bottom line:** Ship Phase 1 as a backend-only change with zero new UI controls. Validate it works. Then add UI chrome. Defer Phase 2.

---

## Critical Issues (Must Fix Before Build)

### 1. Use `[TOPIC-CONTEXT]` marker, not `[SESSION-CONTEXT]`
**Source:** Q  
**Problem:** The auto-reset flow already uses `[SESSION-CONTEXT]`. Reusing it creates ambiguity for the agent and for `fetchLocalHistory` which filters on that prefix.  
**Fix:** Use distinct markers:
- `[SESSION-CONTEXT]` — auto-reset (keep as-is)
- `[TOPIC-CONTEXT]` — topic context injection (new)
- `[RESUME-CONTEXT]` — resume button (future)

### 2. Replace RPC-based `needsContextInjection()` with in-memory tracking
**Source:** Q, Kieran  
**Problem:** The spec proposes calling `fetchHistory(limit: 5)` on every send to detect fresh sessions. This adds 100-500ms latency per send and has a TOCTOU race condition.  
**Fix:** Use an in-memory `contextInjectedKeys: Set<String>` that tracks which sessions have already received context. Insert after injection, clear on session reset. Same pattern as existing `resetCooldownCount`.

### 3. Fix auto-reset / context injection ordering
**Source:** Q, Kieran  
**Problem:** The `justAutoReset` flag doesn't persist across `sendMessage` calls. After auto-reset completes, the flag is gone. If context injection logic checks this flag, it might inject on the 2nd message post-reset (during cooldown).  
**Fix:** Context injection must happen **inside** the same `sendMessage` call as auto-reset, AFTER the `effectiveText` modification, and ONLY if auto-reset did NOT fire for this call. The `contextInjectedKeys` set approach inherently handles this — it's checked after any auto-reset logic.

### 4. Define `TopicMetadata` struct and update `upsertColumns`
**Source:** Q  
**Problem:** The spec references `parsedMetadata` and a JSON structure for `metadataJSON` but doesn't define the Swift struct. Also, `Topic.upsertColumns` doesn't include the new `projectPath` column.  
**Fix:**
```swift
struct TopicMetadata: Codable {
    var activeFocus: String?
    var tags: [String]?
    var autoContext: Bool? // Phase 2, default true
}
```
Add `Column("projectPath")` to `upsertColumns`.

### 5. Handle `metadataJSON` parsing errors gracefully
**Source:** Kieran  
**Problem:** If existing `metadataJSON` contains malformed JSON, `parsedMetadata` must return nil, not crash.  
**Fix:** Use `try? JSONDecoder().decode(...)` — returns nil on failure, falls back to context header without activeFocus/tags.

### 6. Show full `sendMessage` signature change
**Source:** Kieran  
**Problem:** The spec proposes adding `topic: Topic?` parameter but doesn't list all call sites.  
**Fix:** Add `topic: Topic? = nil` as an optional parameter with default nil. This means existing call sites don't need changes — only the UI layer needs to pass it.

---

## Important Recommendations (Should Fix)

### 7. Phase 2 should be deferred or simplified to button-only
**Source:** Q, Mel, Kieran (all three)  
**Problem:** Phase 2 references a non-existent `chat.inject` RPC method. The spec contradicts itself (recommends button in open questions but auto-trigger in implementation). The "Loading context..." UI adds complexity. Phase 1's context header already gives the agent enough orientation.  
**Fix:** Defer Phase 2. If it ships later, make it a button-only feature — a "📍 Pick up where we left off" card in the empty-state view. No auto-trigger, no special UI state, just a regular `chat.send` with `[RESUME-CONTEXT]` prefix.

### 8. Phase 1 ships with ZERO new UI controls
**Source:** Mel  
**Problem:** Adding a "Project Folder" field to the new-topic sheet creates UI complexity before the backend change is validated.  
**Fix:** Phase 1 = backend only. The context injection uses the topic name (which already exists) and optionally `projectPath` (which defaults to nil). Users see the agent "just knowing" what they're working on. No new fields, no new buttons. Phase 1.5 adds the UI chrome later.

### 9. iOS compatibility for `projectPath`
**Source:** Kieran  
**Problem:** A macOS filesystem path like `/Users/openclaw/Projects/...` is meaningless on iOS. BeeChat v5 has iOS adaptation planned.  
**Fix:** For Phase 1, document that `projectPath` is macOS-only. For future platform abstraction, consider using a logical project name or a URL scheme. The `projectPath` field can stay as-is for now since Phase 1 ships with no UI to set it — it'll be populated programmatically or manually.

### 10. Gateway-unreachable fallback for context injection
**Source:** Kieran  
**Problem:** If `needsContextInjection()` can't reach the gateway (offline mode), what happens?  
**Fix:** With the in-memory set approach (recommendation #2), this is moot — we don't call the gateway at all. The set starts empty on app launch, so context is always injected on the first message after launch. This is correct behaviour.

---

## Nice-to-Have (Can Defer)

### 11. Add character limit to context header (~500 chars max)
**Source:** Kieran  
Prevents accidental bloat from long active focus or many tags. Low risk since Phase 1 doesn't expose UI for these fields.

### 12. Sanitise `projectPath` — strip trailing slashes, reject newlines
**Source:** Kieran  
Low risk since Phase 1 doesn't expose UI for this field.

### 13. Folder icon placement — inline with title text, not another dot
**Source:** Mel  
Phase 1.5 consideration. The sidebar is already crowded with dots. Use a small 📁 at 0.6 opacity inline with the title.

### 14. Use `NSOpenPanel` for folder picker (Phase 1.5)
**Source:** Mel  
Prevents typos, feels native. But Phase 1 has no UI, so this is a Phase 1.5 detail.

---

## Revised Implementation Plan

### Phase 1 (1.5–2 days, backend-only)

1. **Database migration** — Add `projectPath` column to `Topic` model, update `upsertColumns`
2. **`TopicMetadata` struct** — Define and add `parsedMetadata` computed property to `Topic`
3. **`contextInjectedKeys` in-memory set** — In `SyncBridge`, same pattern as `resetCooldownCount`
4. **`buildContextHeader()` method** — Pure function, uses `[TOPIC-CONTEXT]` marker
5. **Context injection in `sendMessage`** — After auto-reset block, before ledger creation. Only if `!contextInjectedKeys.contains(sessionKey) && topic != nil`. Insert key after injection. Clear on session reset.
6. **Update `fetchLocalHistory` filter** — Add `[TOPIC-CONTEXT]` to the exclusion prefixes
7. **Add `topic: Topic? = nil` parameter to `sendMessage`** — Default nil, no call-site changes needed
8. **Feature flag** — `topicContextInjection` in UserDefaults, defaulting to `true`

**No UI changes.** The context header uses the topic name from the existing `Topic` model.

### Phase 1.5 (1 day, UI chrome)

1. **New-topic sheet** — Add optional "Project Folder" field (NSOpenPanel picker)
2. **Sidebar** — Show 📁 icon inline with topic name for topics with `projectPath`
3. **Topic settings** — Edit project path and active focus
4. **Error handling** — Invalid path validation, offline gateway fallback

### Phase 2 (deferred)

- "📍 Pick up where we left off" empty-state card
- Button-only, no auto-trigger
- Sends `[RESUME-CONTEXT]` via `chat.send`
- Revisit only if user feedback demands it

### Phase 3 (no code, agent convention)

- Agent reads project `STATUS.md` / `CONTEXT.md` when project path is provided
- Already partially in place via AGENTS.md conventions

---

## Updated Risk Table

| # | Risk | Likel. | Impact | Mitigation | Owner |
|---|------|--------|--------|------------|-------|
| 1 | `[TOPIC-CONTEXT]` marker confuses agent | Low | Medium | Use distinct marker, test with multiple models | Q |
| 2 | Context injection on every message | Low | Medium | In-memory `contextInjectedKeys` set, cleared on reset | Q |
| 3 | Session key not assigned before first send | Low | Low | Existing `resolveSessionKey()` flow handles this | Q |
| 4 | Auto-reset + topic context double injection | Medium | Medium | Context injection AFTER auto-reset block, `contextInjectedKeys` set | Q |
| 5 | Topic metadata staleness | High | Low | Acceptable — stale > absent. Phase 1 has no UI for this. | — |
| 6 | Database migration failure | Very Low | Medium | Additive migration, nil default. Test v6→v7 path. | Q |
| 7 | Invalid `projectPath` | Medium | Low | Agent handles gracefully (file not found → skip) | — |
| 8 | `idempotencyKey` collision | Very Low | Very Low | No risk — UUID per send, independent of content | — |
| 9 | Resume context jarring (Phase 2, deferred) | High | Medium | Button-only, no auto-trigger. Deferred. | Mel |
| 10 | Project STATUS.md bloat | Low | Low | One file read per topic activation. Acceptable. | — |
| 11 | RPC latency from `fetchHistory` | — | — | **Eliminated** — in-memory set approach, no RPC call | Q |
| 12 | Context header + long message bloat | Very Low | Low | Headers are ~200 bytes vs 200k token window | — |
| 13 | `projectPath` iOS incompatibility | Medium | High (future) | Document as macOS-only for Phase 1. Plan abstraction for iOS. | Q |
| 14 | Multiple BeeChat instances same gateway | Low | Medium | Each instance tracks `contextInjectedKeys` independently | Q |
| 15 | `justAutoReset` flag lost on crash | Medium | Low | In-memory set approach: on app restart, context is injected on first send (correct behaviour) | — |

---

*This synthesis will be incorporated into the updated spec before build begins.*