# FR-003 Code Review

**Reviewer:** Kieran
**Date:** 2026-06-20
**Status:** Approve with conditions

## Summary

The FR-003 build implements the research pipeline panel UI and pipeline skill scaffold. The Swift changes (ResearchPanel.swift, MainWindow.swift, ComposerViewModel.swift) are clean, follow existing patterns, and build successfully. The pipeline skill (SKILL.md, report.html, ingest.py) is well-structured and covers most spec requirements. Two conditions need to be addressed before merge: quote escaping in the payload constructor and a missing KB-conflict check in the pipeline definition. Neither is a blocker — both are fixable in under 30 minutes.

The implementation is notably faithful to the spec. ResearchPanel matches AgentActivityPanel's sheet pattern exactly. `sendPayload` correctly routes through the existing send chain without creating a new path. The pipeline skill covers all 8 error scenarios from the spec. ingest.py is safe, non-destructive, and handles partial failure correctly.

**Build verification:** `swift build` — Build complete (0.08s), no errors, no warnings.

---

## Swift UI Findings

### F1: Quote escaping in payload construction (Major)

**File:** `ResearchPanel.swift`, `submitResearch()` method (line 175-181)

```swift
let payload = "/research \(depthFlag) \"\(trimmedTopic)\"\(tagsFlag)"
```

If the topic text contains double quotes (e.g., `Topcon "Positioning" Market`), the payload becomes:

```
/research --depth standard "Topcon "Positioning" Market"
```

The nested unescaped quotes will break Bee's command parsing — the parser will see the topic as `Topcon ` and the rest as garbage. This is a realistic scenario — users will paste article titles that contain quotes.

**Fix:** Escape double quotes in the topic text before constructing the payload:

```swift
let escapedTopic = trimmedTopic.replacingOccurrences(of: "\"", with: "\\\"")
let payload = "/research \(depthFlag) \"\(escapedTopic)\"\(tagsFlag)"
```

**Severity:** Major — this will hit real users on day one. Easy fix.

### F2: ResearchDepth.accessibilityLabel is defined but never used (Minor)

**File:** `ResearchPanel.swift`, lines 18-24

The `ResearchDepth` enum defines an `accessibilityLabel` computed property with detailed descriptions ("Quick Scan — 2 to 3 minutes, chat brief", etc.), but it's never wired to the Picker segments. VoiceOver will only read the display names ("⚡ Quick", "Standard", "🔬 Deep") — the time estimates are lost.

**Fix:** Add `.accessibilityLabel(depth.accessibilityLabel)` to each segment in the Picker's `ForEach`:

```swift
ForEach(ResearchDepth.allCases, id: \.self) { depth in
    Text(depth.displayName)
        .tag(depth)
        .accessibilityLabel(depth.accessibilityLabel)
}
```

**Severity:** Minor — accessibility degradation, not a functional bug.

### F3: No newline trimming in tags payload (Minor)

**File:** `ResearchPanel.swift`, `submitResearch()` (line 178-179)

```swift
let tagsFlag = tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    ? ""
    : " --tags \(tagsText.trimmingCharacters(in: .whitespacesAndNewlines))"
```

This trims for the emptiness check and for the flag value, which is correct. But if the tags field contains internal newlines (e.g., user pastes "topcon,\ncompetitor"), the newline would end up in the payload. The `TextField` is single-line so this is unlikely, but a paste could introduce it.

**Fix:** Consider replacing internal newlines: `tagsText.replacingOccurrences(of: "\n", with: " ")` before constructing the flag. Or accept the risk since `TextField` on macOS doesn't accept multi-line input.

**Severity:** Minor / Nit — low probability, easy to address.

### F4: Missing trailing newline at end of file (Nit)

**File:** `ResearchPanel.swift` — no trailing newline (git diff shows `\ No newline at end of file`).

**Fix:** Add trailing newline.

**Severity:** Nit — convention only.

### F5: Sheet pattern matches AgentActivityPanel exactly (Pass)

ResearchPanel follows the AgentActivityPanel pattern:
- Same header structure (`HStack` with title + `Spacer` + `Done` button)
- Same `.padding(.horizontal, themeManager.spacing(.xl))` + `.padding(.vertical, themeManager.spacing(.lg))`
- Same `Divider().background(themeManager.color(.borderSubtle))` after header
- Same `.frame(minWidth:idealWidth:minHeight:)` sizing
- Same `.background(themeManager.color(.bgSurface))`

No deviation. Clean.

### F6: sendPayload routing is correct (Pass)

`ComposerViewModel.sendPayload(_ text: String)` correctly:
- Trims and validates non-empty input
- Calls `onMessageSent?()` before the async work (fires thinking indicator synchronously)
- Wraps `messageViewModel?.sendMessage(text:)` in a `Task` (correct — `sendPayload` is sync but `sendMessage` is async)
- Uses the same `messageViewModel?.sendMessage(text:)` call as `send()` — no new message path
- `ComposerViewModel` is `@MainActor`, so `onMessageSent?()` fires on the main actor (same as `send()`)
- The `Task { }` inherits `@MainActor` context, so `sendMessage` is called on the main actor

The `send()` method is `async` and called from `composerSend()` which wraps it in `Task { await composerViewModel.send() }`. `sendPayload` is sync and called from `submitResearch()` (a button action closure, can't be async). Both reach `messageViewModel?.sendMessage(text:)` on the main actor. Functionally equivalent.

No new communication path created. No shared package changes. No AppState mutation.

### F7: Keyboard shortcuts are non-conflicting (Pass)

- `Cmd+Shift+R` — opens research panel. No conflict with existing shortcuts:
  - `Cmd+N` — new topic
  - `Cmd+Delete` — delete topic
  - `Cmd+Left/Right` — topic navigation (TODO, not wired)
  - `Cmd+Return` — default action in sheet (via `.keyboardShortcut(.defaultAction)`)
  - `Escape` — cancel action in sheet (via `.keyboardShortcut(.cancelAction)`)
- `.keyboardShortcut(.defaultAction)` on the submit button correctly maps to `Cmd+Return` in a sheet context — standard macOS behavior for "submit from a form with a multi-line text field"
- `.keyboardShortcut(.cancelAction)` on Done correctly maps to `Escape` — standard sheet dismissal
- No conflict with the New Topic dialog (which also uses `.cancelAction` and `.defaultAction`) because only one sheet is presented at a time

### F8: Topic guard is correct (Pass)

The research button is disabled when `messageViewModel.selectedTopicId == nil`:

```swift
.disabled(messageViewModel.selectedTopicId == nil)
```

This matches the spec requirement: "Research button disabled when no topic selected." The button is greyed out, same as the delete button's conditional appearance pattern. An alternative would be to hide the button entirely (like the delete button), but disabling is more discoverable — the user can see the feature exists but needs a topic.

### F9: TextEditor placeholder overlay works correctly (Pass)

The ZStack overlay pattern is the standard SwiftUI workaround for `TextEditor`'s lack of native placeholder support:
- Placeholder `Text` is shown when `topicText.isEmpty`
- `.allowsHitTesting(false)` on the placeholder prevents it from stealing focus from the `TextEditor`
- Placeholder padding (`+4` offset) aligns it with the `TextEditor` content
- Border changes from `borderSubtle` (empty) to `accentPrimary` (has content) — subtle focus/content indicator
- `@FocusState` auto-focuses the `TextEditor` on `.onAppear`

This is the correct pattern. It matches the approach described in Mel's UX review.

### F10: Depth picker is properly bounded (Pass)

Three segments via `ResearchDepth` enum (`CaseIterable`), displayed with `.pickerStyle(.segmented)`:
- `⚡ Quick` / `Standard` / `🔬 Deep`
- Default `.standard` pre-selected
- Uses `.tag(depth)` for correct selection binding
- `id: \.self` on `ForEach` — correct for enum cases

No edge cases — the enum is fixed at three cases, can't be empty, can't overflow.

### F11: Sheet closes correctly on submit AND on Done (Pass)

- `submitResearch()` calls `composerViewModel.sendPayload(payload)` then `dismiss()` — sheet closes on submit
- Done button calls `dismiss()` — sheet closes without submitting
- `Escape` (via `.cancelAction` on Done) closes the sheet

All three dismissal paths work. The `@Environment(\.dismiss)` is the correct modern SwiftUI dismissal mechanism.

### F12: Sidebar layout — 6 buttons at minimum width (Pass with note)

At minimum sidebar width (180px), the HStack now has 6 permanent buttons + 1 conditional (delete). With `spacing: 12`:
- 6 icons × ~20px + 5 gaps × 12px = ~180px
- This is exactly at the minimum — it will fit but with no margin
- The 7th button (delete, conditional) would make it ~200px — over minimum

However, the delete button uses `.transition(.opacity)` and only appears when a topic is selected. At 180px sidebar width, 6 buttons fit exactly. The delete button would cause slight overflow, but SwiftUI's HStack will compress rather than clip. The `.font(themeManager.font(.body))` on the research button matches the existing buttons (BeeBoard, Theme) — not smaller.

**Assessment:** Fits at ideal width (240px) with room to spare. Tight at minimum (180px) but won't break. Acceptable for MVP. If it looks cramped in testing, the research button could use `.font(.system(size: 13))` instead of `.body`, but that would be inconsistent with the other buttons.

### F13: No memory leaks or retain cycles (Pass)

- `ComposerViewModel` holds `weak` references to `syncBridge` and `messageViewModel`
- `ResearchPanel` receives `composerViewModel` as `@Bindable` — it doesn't own it (MainWindow owns it as `@State`)
- `onMessageSent` closure in MainWindow uses `[weak syncBridgeObserver]` — no retain cycle
- `submitResearch()` doesn't capture self in any escaping closure (the `Task` in `sendPayload` captures `messageViewModel` which is already weak)

No retain cycles. Clean.

### F14: @MainActor / threading concerns with Task in sendPayload (Pass)

- `ComposerViewModel` is `@MainActor` — all its methods run on the main actor
- `sendPayload` is a sync method on `@MainActor`, so it runs on the main actor
- `onMessageSent?()` fires synchronously on the main actor — correct (thinking indicator starts immediately)
- The `Task { }` inside `sendPayload` inherits the `@MainActor` isolation context
- `messageViewModel?.sendMessage(text:)` is `@MainActor` (class is annotated) — called on main actor via the inherited context
- `SyncBridge.sendMessage()` is called from within `MessageViewModel.sendMessage()` — it handles its own async dispatch

No threading issues. The `Task` is the correct pattern for calling async code from a sync context on `@MainActor`.

---

## Pipeline Skill Findings

### P1: Missing "conflict with existing KB entries" check in SKILL.md (Major)

**File:** `SKILL.md`, Stage 3: Analysis & Synthesis

The spec says:

> **Conflict with existing knowledge:** If research findings contradict existing KB entries, flag the conflict explicitly in the HTML report ("⚠️ Conflicts with prior knowledge: [link to KB entry]"). Create a correction entry if Adam confirms the new finding is correct.

SKILL.md Stage 3 has:
- Step 2: "Conflict detection: Do sources agree? Flag contradictions explicitly with ⚠️" — this is conflict *between sources*
- Step 4: "Knowledge connection: How does this fit what we already know? Link to related KB entries" — this is linking, not conflict detection

The missing piece: checking whether new findings **contradict existing KB entries** and flagging them. The HTML template has a `.conflict-warning` section ready, but SKILL.md doesn't instruct the agent to populate it with KB conflicts.

**Fix:** Add a step to Stage 3:

```markdown
6. **KB conflict check:** Compare key findings against existing KB entries (via `wiki_search`).
   If a finding contradicts an existing KB entry, flag it in the HTML report using the
   conflict-warning template section: "⚠️ Conflicts with prior knowledge: [link to KB entry]".
   Note: a correction entry is only created if Adam confirms the new finding is correct —
   do NOT auto-correct the KB.
```

**Severity:** Major — this is a spec requirement that was missed. The HTML template has the infrastructure for it, but the pipeline instructions don't tell the agent to do it.

### P2: HTML template placeholders have no injection guidance (Minor)

**File:** `templates/report.html`

The template uses `{{PLACEHOLDER}}` syntax for variable substitution. The comment says "Replace all {{PLACEHOLDERS}} with actual content" but doesn't warn about HTML injection. If a research topic contains `<script>` tags or HTML entities, and the agent naively substitutes them, the resulting HTML report could contain injected markup.

**Risk assessment:** Low — the agent generating the report is an LLM, not a string templating engine. It's unlikely to produce malicious HTML. But if a source title or topic contains HTML entities (e.g., `Topcon & Positioning`), naive substitution could produce broken HTML.

**Fix:** Add a comment to the template:

```html
<!--
  NOTE: When replacing placeholders, escape HTML special characters
  (& → &amp;, < → &lt;, > → &gt;) in user-provided content (title, tags, topic).
  Source URLs and KB paths should NOT be escaped — they go in href attributes.
-->
```

**Severity:** Minor — low probability, but good defensive practice. The LLM agent will likely handle this correctly anyway.

### P3: ingest.py does not verify HTML report exists before processing (Minor)

**File:** `scripts/ingest.py`, `main()` function

The `--html-path` argument is required, but ingest.py never checks that the file exists. If Gav calls ingest.py with a wrong path (typo, missing directory), the KB entry will be written with a dangling `html_path` reference. The user will click the link in the KB entry and get a file-not-found.

**Fix:** Add a check at the start of `main()`:

```python
html_path = Path(args.html_path)
if not html_path.exists():
    print(f"WARNING: HTML report not found at {args.html_path}", file=sys.stderr)
    # Continue anyway — KB entry is still useful even if report is missing
    # Status stays "partial" since the report link is broken
    status = "partial"
    errors.append(f"HTML report not found at {args.html_path}")
```

**Severity:** Minor — defensive check, not a correctness bug. The script doesn't read the HTML file, so it won't crash — but the KB entry would have a broken link.

### P4: ingest.py writes memory entry to memory/digests/ — potential namespace collision (Minor)

**File:** `scripts/ingest.py`, `write_memory_entry()` function

The memory entry is written to `memory/digests/YYYY-MM-DD-research-{research_id}.md`. This is the same directory as AI Digest files. If a research and a digest share the same date and topic slug, the filenames could collide (digest: `2026-06-20-ai-digest.md`, research: `2026-06-20-research-2026-06-20-ai-digest.md`). The `research-` prefix makes collision unlikely but not impossible.

**Assessment:** Low risk — the `research-` prefix and `{research_id}` (which includes the topic slug) make collision very unlikely. The `memory/digests/` directory is already used for time-based knowledge entries, so research entries fit there semantically. Acceptable.

**Severity:** Minor / Nit — no fix needed, but worth noting.

### P5: ingest.py exit code is always 0 (Pass — by design)

The script always exits with code 0, even on partial failure. This is correct per spec: "Failure handling: log error, set status 'partial', do NOT fail the run." The calling agent should check stdout for "PARTIAL:" vs "OK:" to determine status, not the exit code.

### P6: ingest.py is safe to run — no destructive operations (Pass)

Verified via AST analysis:
- No `subprocess`, `os.system`, `eval`, `exec`, or `compile` calls
- Only file operations: `write_text` (3 calls — KB entry, memory entry, index update)
- No file deletion, no file modification (only creation/overwrite)
- Uses `mkdir(parents=True, exist_ok=True)` — safe directory creation
- JSON index is read → append → write (atomic enough for single-writer scenario)

No destructive operations. Safe to run.

### P7: ingest.py partial status handling is correct (Pass)

The script tracks status through the `status` variable:
- Starts as `"complete"`
- Downgraded to `"partial"` if KB entry write fails
- Downgraded to `"partial"` if memory entry write fails
- Downgraded to `"partial"` if index update fails
- Multiple failures all set `"partial"` (not `"failed"`) — correct per spec

The `errors` list accumulates failure messages for stdout reporting. The final stdout output reports "PARTIAL:" with the error list, or "OK:" if all succeeded. Exit code is always 0.

This matches the spec: "HTML report and chat summary still delivered. KB ingestion is secondary — failure doesn't fail the run. Log the failure in research-index.json with status: 'partial'."

### P8: research-index.json schema is complete (Pass)

The index entry written by ingest.py includes all required fields from the spec:
- `id` ✅ — `make_research_id()` generates `YYYY-MM-DD-topic-slug`
- `title` ✅
- `date` ✅ — from `--date` arg or `datetime.now().isoformat()`
- `depth` ✅ — from `--depth` arg
- `tags` ✅ — parsed from `--tags` arg
- `status` ✅ — `"complete"` or `"partial"`
- `html_path` ✅ — from `--html-path` arg
- `kb_entry_path` ✅ — set to `knowledge/Research/{filename}` or `None` on failure
- `cost_gbp` ✅ — from `--cost-gbp` arg (default 0.0)
- `duration_seconds` ✅ — from `--duration-seconds` arg (default 0)
- `sources_count` ✅ — from `--sources-count` arg or computed from `--sources` list
- `dedup_of` ✅ — from `--dedup-of` arg (default None)

All fields from the spec schema are present. The `cost_gbp` and `duration_seconds` default to 0, which means the calling agent must provide accurate values — the script doesn't estimate them.

### P9: HTML template has all required sections (Pass)

Required sections per spec: Summary → Key Findings → Detailed Analysis → Sources → Knowledge Base Links

Template sections:
1. Header (title, date, meta) ✅
2. Status bar (topic, depth, tags, status, sag) ✅
3. Conflict warning (commented example) ✅
4. Summary (with verdict) ✅
5. Key Findings (with confidence levels) ✅
6. Detailed Analysis ✅
7. Sources (with source type labels) ✅
8. Knowledge Base Links ✅
9. Footer (research ID) ✅

All required sections present. The template includes helpful HTML comments showing the pattern for each section.

### P10: Dedup logic in SKILL.md is sound (Pass)

The dedup procedure covers:
- Title matching (case-insensitive substring) ✅
- Tag overlap ✅
- AI digest file check (last 7 days) ✅
- `wiki_search` for KB entries ✅
- Age-based decision tree (< 7 days, 7-30 days, > 30 days) ✅
- `dedup_of` field for cross-referencing ✅

The decision tree is well-defined: exact recent = offer "go deeper", exact old = proceed with cross-ref, partial overlap = proceed with cross-ref, no match = normal.

### P11: Model selection and fallback rules are correct (Pass)

SKILL.md specifies:
- Quick Scan: Active model (speed)
- Standard: Active model (search) + MiniMax-M3 (synthesis)
- Deep Dive: Grok 4.3 (search) + MiniMax-M3 (synthesis)
- Fallback: "If a preferred model is unavailable, fall back to the default active model. Model selection is preferred, not hard — never fail a run because a specific model was unavailable."

This matches the spec's clarification (which Kieran's prior review recommended): "Model selection is preferred, not hard."

### P12: Sag integration path is correct (Pass)

SKILL.md specifies:
- Sag file location: `/Volumes/SSD Storage/Sag-Scout/YYYY-MM-DD.md` ✅
- Date ranges per depth: Quick=today, Standard=3 days, Deep=7 days ✅
- Check procedure: list files, read, search for topic mentions ✅
- Use Sag instead of re-searching if captured ✅
- Credit Sag as source ✅
- Graceful degradation if SSD not mounted ✅

The degradation path is explicit: "Skip Sag check, proceed with web_search and x_search, note in report." This matches the spec's error handling requirement.

### P13: Cost logging is present (Pass)

SKILL.md specifies cost logging in `data/research-index.json` with `cost_gbp` field. The spec says "estimated based on token count × model rate" — SKILL.md says the same. ingest.py accepts `--cost-gbp` as a parameter and writes it to the index.

The £50/week threshold flag is mentioned in SKILL.md: "If weekly spend exceeds £50, flag in digest for Adam's awareness." This matches the spec.

### P14: All 8 error scenarios from spec are covered in SKILL.md (Pass)

| Spec scenario | SKILL.md coverage |
|---|---|
| Dead link (404) | ✅ "Report 'link dead' in chat, suggest searching topic instead" |
| No results found | ✅ "Report 'no results' in chat, suggest broader search terms" |
| Partial results | ✅ "Return what was found, flag incomplete coverage in report" |
| API rate limit | ✅ "Wait and retry (existing web_search behaviour)" |
| Pipeline crash | ✅ "Report error in chat, log failure in research-index.json with status: 'failed'" |
| Sag files unavailable | ✅ "Degrade gracefully — skip Sag, proceed with web search, note in report" |
| wiki_apply or memory write fails | ✅ "HTML report and chat summary still delivered. KB ingestion is secondary. Log failure in research-index.json with status: 'partial'" |
| Ambiguous/broad input | ✅ "Default to Quick Scan with note: 'Topic is broad — running Quick Scan...'" |

All 8 error scenarios are covered.

---

## Spec Compliance

### Swift UI Requirements

| Spec requirement | Status | Notes |
|---|---|---|
| Sheet (`.sheet`) presented from MainWindow | ✅ | `.sheet(isPresented: $showResearchPanel)` |
| Sheet size: minWidth 460, ideal 480, minHeight 340 | ✅ | `.frame(minWidth: 460, idealWidth: 480, minHeight: 340)` |
| Header: "🔍 Research" title + "Done" button | ✅ | Matches AgentActivityPanel exactly |
| Keyboard: `Cmd+Shift+R` to open panel | ✅ | `.keyboardShortcut("r", modifiers: [.command, .shift])` |
| Keyboard: `Cmd+Return` to submit | ✅ | `.keyboardShortcut(.defaultAction)` on submit button |
| Keyboard: `Escape` to close | ✅ | `.keyboardShortcut(.cancelAction)` on Done button |
| Focus: Text field auto-focuses on appear | ✅ | `@FocusState` + `.onAppear { isTopicFieldFocused = true }` |
| Text field: multi-line TextEditor with placeholder overlay | ✅ | ZStack pattern with `.allowsHitTesting(false)` placeholder |
| Depth selector: segmented Picker, 3 segments, Standard pre-selected | ✅ | `@State selectedDepth: ResearchDepth = .standard` |
| Tags field: optional, free text TextField, comma-separated | ✅ | `TextField("topcon, competitor, market", text: $tagsText)` |
| Submit button: full-width accent, disabled when empty | ✅ | `.disabled(!canSubmit)`, `canSubmit` checks whitespace-trimmed emptiness |
| Empty topic guard: button disabled when no topic selected | ✅ | `.disabled(messageViewModel.selectedTopicId == nil)` |
| Send via `ComposerViewModel.sendPayload()` | ✅ | `composerViewModel.sendPayload(payload)` |
| Preserves thinking indicator | ✅ | `onMessageSent?()` fires before Task |
| Sheet closes on submit | ✅ | `dismiss()` after `sendPayload()` |
| Sidebar button: magnifyingglass icon | ✅ | `Image(systemName: "magnifyingglass")` |
| Sidebar button uses compact icon | ✅ | `.font(themeManager.font(.body))` — same as other buttons |
| VoiceOver labels complete | ⚠️ | Most labels present, but `ResearchDepth.accessibilityLabel` unused (F2) |
| No shared package changes | ✅ | Only `Sources/App/` modified |
| No AppState changes | ✅ | All state is local `@State` |
| No new message types | ✅ | Payload is plain text |

### Pipeline Skill Requirements

| Spec requirement | Status | Notes |
|---|---|---|
| SKILL.md defines pipeline | ✅ | Full 5-stage pipeline |
| Command syntax documented | ✅ | `/research --depth quick "topic" --tags a,b` |
| Three depth levels with correct time/cost | ✅ | Quick 2-3min/£0.05, Standard 8-12min/£0.15, Deep 15-25min/£0.60 |
| Model selection table with fallback | ✅ | "Preferred, not hard — fall back to default" |
| Sag integration with date ranges | ✅ | Quick=today, Standard=3d, Deep=7d |
| Sag graceful degradation | ✅ | "Skip Sag, proceed with web_search, note in report" |
| Dedup check before research | ✅ | Title match, tag overlap, digest check, wiki_search |
| Dedup age-based decision tree | ✅ | <7d, 7-30d, >30d branches |
| HTML report with all sections | ✅ | Summary, Key Findings, Detailed Analysis, Sources, KB Links |
| Source provenance (every claim links to source) | ✅ | Stated in SKILL.md + HTML template comments |
| Chat brief for Quick Scan | ✅ | "5-10 bullet points, verdict, no HTML file" |
| KB entry for Standard/Deep only | ✅ | "Run ingest.py after writing HTML report" |
| research-index.json with full schema | ✅ | All 12 fields present |
| Cost logging | ✅ | `cost_gbp` in index + £50/week flag |
| Concurrency model | ✅ | 1 Deep, 2 Quick parallel, Standard queues |
| All 8 error scenarios | ✅ | All covered in error handling table |
| Conflict with existing KB entries | ❌ | Missing from SKILL.md (P1) |
| Retention policy | ✅ | Not in SKILL.md, but spec says "keep everything" — conscious omission |
| ingest.py contract | ✅ | Runs after Standard/Deep, reads args, writes KB+memory+index, partial on failure |
| HTML template with shared CSS | ✅ | Template has inline CSS matching AI Digest style |
| Output directory: ~/Desktop/Research Reports/ | ✅ | Documented in SKILL.md |

### Files Changed

| Spec file | Status | Lines |
|---|---|---|
| `Sources/App/UI/Components/ResearchPanel.swift` | ✅ New | 184 lines (spec estimated 80-100, actual 184 — larger but justified by accessibility, theme tokens, placeholder overlay) |
| `Sources/App/UI/MainWindow.swift` | ✅ Modified | +17 lines (spec estimated ~8) |
| `Sources/App/UI/ViewModels/ComposerViewModel.swift` | ✅ Modified | +18 lines (spec estimated ~5) |
| `skills/research-pipeline/SKILL.md` | ✅ New | Full pipeline definition |
| `skills/research-pipeline/templates/report.html` | ✅ New | HTML template with CSS |
| `skills/research-pipeline/scripts/ingest.py` | ✅ New | 276 lines |
| `skills/research-pipeline/data/research-index.json` | ✅ New | `[]` (empty array) |

The Swift file is ~84 lines larger than estimated (184 vs 100). This is expected — Mel's UX review correctly predicted "80-100 lines" was optimistic and "realistically, with accessibility, theme tokens, and the placeholder overlay, expect 80-100 lines." The actual count of 184 includes the `ResearchDepth` enum (24 lines) and thorough accessibility labels. Not over-engineered — just thorough.

---

## Verdict

**Approve with two conditions.**

### Conditions (fix before merge)

**C1: Escape double quotes in payload construction (F1)**
ResearchPanel.swift `submitResearch()` — escape `"` in topic text before constructing the `/research` payload. One-line fix. Without this, any topic containing quotes will break Bee's command parser.

**C2: Add KB conflict check to SKILL.md (P1)**
Stage 3 needs a step 6 instructing the agent to compare findings against existing KB entries via `wiki_search` and flag contradictions using the HTML template's `.conflict-warning` section. This is a spec requirement that was missed.

### Non-blocking recommendations

1. **F2:** Wire `ResearchDepth.accessibilityLabel` to the Picker segments for full VoiceOver support.
2. **P2:** Add HTML escaping guidance to the report template comment.
3. **P3:** Add HTML report existence check to ingest.py `main()`.
4. **F4:** Add trailing newline to ResearchPanel.swift.

### What's clean

- Build compiles with zero errors and zero warnings
- Sheet pattern matches AgentActivityPanel exactly — no deviation
- `sendPayload` is the right design — no new message path, preserves thinking indicator
- No retain cycles, no threading issues, no memory leaks
- All keyboard shortcuts non-conflicting
- ingest.py is safe, non-destructive, handles partial failure correctly
- All 8 error scenarios from spec are covered in SKILL.md
- research-index.json schema is complete with all 12 fields
- HTML template has all required sections with helpful pattern comments
- Model selection has fallback rules
- Sag integration with graceful degradation is correct
- No shared package changes, no AppState changes, no new message types

The implementation is solid. The two conditions are small fixes — a one-line quote escaping fix and a 5-line addition to SKILL.md. Neither requires re-architecture or re-thinking. Address both and this is ready to merge.

---

*Kieran — 2026-06-20*