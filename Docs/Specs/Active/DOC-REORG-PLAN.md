# DOC-REORG-001: BeeChat-v5 Documentation Reorganisation Plan

**Created:** 2026-05-26  
**Author:** Bee (coordinator)  
**Status:** APPROVED — Kieran review complete, awaiting Adam go-ahead to execute  
**Priority:** Medium — admin cleanup, no code impact  
**Review:** DOC-REORG-KIERAN-REVIEW.md — 7 required changes incorporated below

---

## Problem

The BeeChat-v5 project root has 54 .md files scattered at the top level, plus a duplicate `SPECS/` folder (22 files) sitting alongside `Docs/Specs/` (36 files). Reviews exist in three different locations (`REVIEW-*.md` at root, `SPECS/review-*.md`, and `Docs/Reviews/`). There's no way to distinguish current/active docs from historical ones, and no clear structure for finding what you need.

This makes it hard to:
- Understand the current build state at a glance
- Find the latest spec or review for a feature
- Know what's superseded vs still relevant
- Onboard new context (for agents or humans) quickly

## Goal

1. Clean root: only STATUS.md, README.md, HANDOFF.md, DEBUG.md stay at root
2. Everything else moves into `Docs/` with clear subfolder purpose
3. Group review cycles by topic (crash-hang, scroll-bounce, session-reset, compact-pins, whitespace-jump)
4. Separate Active vs Archive within each category
5. Consolidate the duplicate SPECS/ and Docs/Specs/ into one location
6. Kieran reviews every file for historical accuracy before we Archive — nothing gets buried without sign-off

## Proposed Target Structure

```
BeeChat-v5/
├── README.md                          # KEEP — project overview
├── STATUS.md                          # KEEP — current live status
├── HANDOFF.md                         # KEEP — inter-agent handoff
├── DEBUG.md                           # MOVE to Docs/Status/ after reorg (keep at root only while active debug is open)
│
├── Docs/
│   ├── Architecture/                  # KEEP AS-IS (4 files, already tidy)
│   ├── Design/                        # KEEP AS-IS (3 files, already tidy)
│   ├── Research/                       # KEEP AS-IS (4 files, already tidy)
│   ├── History/                        # KEEP AS-IS (3 files, already tidy)
│   │
│   ├── Specs/                          # All specifications
│   │   ├── Active/                     # Currently relevant specs
│   │   ├── Archive/                    # Superseded / completed specs
│   │   │   └── README.md              # Index of archived specs with superseded-by notes
│   │   └── (DOC-REORG-PLAN.md stays Active until execution complete, then Archive)
│   │
│   ├── Reviews/                        # All review & consensus docs
│   │   ├── INDEX.md                    # Reviews index by cycle and author
│   │   ├── Components/                # Component reviews (existing, from Apr 17)
│   │   ├── Cycles/                     # Review cycles grouped by topic
│   │   │   ├── crash-hang/
│   │   │   ├── scroll-bounce/
│   │   │   ├── session-reset/
│   │   │   ├── compact-pins/
│   │   │   ├── whitespace-jump/
│   │   │   ├── unread-indicator/      # Kieran: added missing cycle
│   │   │   ├── baseline/              # Kieran: added missing cycle
│   │   │   └── restoration/           # Kieran: step1/2/3 restoration reviews
│   │   ├── Final/                      # Final reviews (A/B/C/D steps)
│   │   ├── Consensus/                  # All CONSENSUS-*.md
│   │   └── Adversarial/                # Adversarial review files
│   │
│   ├── Diagnosis/                      # Diagnosis & evaluation reports
│   ├── Implementation/                 # Implementation notes & fix specs
│   ├── Analysis/                       # One-off assessments (dependency, type, legacy)
│   └── Status/                         # KEEP AS-IS
│
└── (no SPECS/ folder — merged into Docs/Specs/)
```

---

## Detailed File Mapping

### STAYS AT ROOT (4 files)
| File | Notes |
|------|-------|
| README.md | Project overview |
| STATUS.md | Live project status — update after reorg |
| HANDOFF.md | Inter-agent handoff state |

### MOVES TO Docs/Status/
| File | Target | Notes |
|--------|--------|-------|
| DEBUG.md | Docs/Status/ | Active debug log — root should be minimal (Kieran) |

### MOVES TO Docs/Specs/Active/
Files that define current or in-progress feature/fix specs:

| Source | Target | Notes |
|--------|--------|-------|
| SPEC-FIX-A-double-resume.md | Docs/Specs/Active/ | Active fix spec |
| SPEC-FIX-B-streaming-state.md | Docs/Specs/Active/ | Active fix spec |
| SPEC-FIX-C-poll-guard.md | Docs/Specs/Active/ | Active fix spec |
| SPEC-compact-pins.md | Docs/Specs/Active/ | Active feature spec |
| SPEC-reset-flow-refactor.md | Docs/Specs/Active/ | Active refactor spec |
| SPEC-scroll-fix.md | Docs/Specs/Active/ | Active fix spec |
| SPEC-session-reset-hybrid-final.md | Docs/Specs/Active/ | Active feature spec (final) |
| SPEC-session-reset-options.md | Docs/Specs/Active/ | Options doc for session reset |
| SPEC-whitespace-jump-fix.md | Docs/Specs/Active/ | Active fix spec |
| BEECHAT-RESTORATION-PLAN.md | Docs/Specs/Active/ | Active restoration plan |

### MOVES TO Docs/Specs/Archive/ (from root)
Specs that are completed, superseded, or from earlier phases:

| Source | Target | Notes |
|--------|--------|-------|
| DIAGNOSIS-protocol-v4-2026-05-15.md | Docs/Specs/Archive/ | Diagnosis protocol, dated |
| DIAGNOSIS-scroll-bounce-2026-05-10.md | Docs/Specs/Archive/ | Diagnosis, dated |

### MOVES TO Docs/Specs/Archive/ (from root SPECS/ folder)
All 22 files from `SPECS/` — these are earlier iterations of specs and reviews that have been superseded by final versions:

| Source | Target | Notes |
|--------|--------|-------|
| SPECS/blank-space-issue.md | Docs/Specs/Archive/ | Early issue doc |
| SPECS/blank-space-kieran-review.md | Docs/Specs/Archive/ | Superseded review |
| SPECS/blank-space-q-diagnosis.md | Docs/Specs/Archive/ | Superseded diagnosis |
| SPECS/concurrent-sessions-fix.md | Docs/Specs/Archive/ | Earlier fix |
| SPECS/jump-to-latest-button-fix.md | Docs/Specs/Archive/ | Earlier fix spec |
| SPECS/jump-to-latest-issue.md | Docs/Specs/Archive/ | Issue doc |
| SPECS/jump-to-latest-kieran-diagnosis.md | Docs/Specs/Archive/ | Superseded |
| SPECS/jump-to-latest-q-diagnosis.md | Docs/Specs/Archive/ | Superseded |
| SPECS/jump-to-latest.md | Docs/Specs/Archive/ | Main spec, superseded |
| SPECS/message-windowing.md | Docs/Specs/Archive/ | Earlier spec |
| SPECS/openclaw-429-enhancements.md | Docs/Specs/Archive/ | Enhancement spec |
| SPECS/review-kieran-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-kieran-jump-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-kieran-jump-v3-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-kieran-jump-v4-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-kieran-jump.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-kieran-scroll-bounce.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-kieran-v2.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-kieran.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-mel-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-mel-jump-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-mel-jump-v3-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-mel-jump-v4-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-mel-jump.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-mel-v2.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-mel.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-q-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-q-jump-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-q-jump-v3-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-q-jump-v4-final.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-q-jump.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-q-scroll-bounce.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-q-v2.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-q.md | Docs/Specs/Archive/ | Review cycle |
| SPECS/review-synthesis.md | Docs/Specs/Archive/ | Synthesis review |
| SPECS/scroll-bounce-fix-review.md | Docs/Specs/Archive/ | Review doc |
| SPECS/scroll-bounce-fix.md | Docs/Specs/Archive/ | Fix spec |
| SPECS/scroll-bounce-issue.md | Docs/Specs/Archive/ | Issue doc |
| SPECS/topic-context-persistence.md | Docs/Specs/Archive/ | Spec doc |

### MOVES TO Docs/Reviews/Cycles/
Review files grouped by topic cycle:

**crash-hang/**
| Source | Target |
|--------|--------|
| REVIEW-KIERAN-crash-hang.md | Docs/Reviews/Cycles/crash-hang/ |
| REVIEW-Q-crash-hang.md | Docs/Reviews/Cycles/crash-hang/ |

**scroll-bounce/**
| Source | Target |
|--------|--------|
| REVIEW-KIERAN-scroll-bounce.md | Docs/Reviews/Cycles/scroll-bounce/ |
| REVIEW-Q-scroll-bounce.md | Docs/Reviews/Cycles/scroll-bounce/ |

**session-reset/**
| Source | Target |
|--------|--------|
| CONSENSUS-session-reset-kieran.md | Docs/Reviews/Cycles/session-reset/ |
| CONSENSUS-session-reset-kieran-final.md | Docs/Reviews/Cycles/session-reset/ |
| CONSENSUS-session-reset-mel.md | Docs/Reviews/Cycles/session-reset/ |
| CONSENSUS-session-reset-mel-final.md | Docs/Reviews/Cycles/session-reset/ |
| CONSENSUS-session-reset-q.md | Docs/Reviews/Cycles/session-reset/ |
| CONSENSUS-session-reset-q-final.md | Docs/Reviews/Cycles/session-reset/ |

**compact-pins/**
| Source | Target |
|--------|--------|
| REVIEW-compact-pins-kieran.md | Docs/Reviews/Cycles/compact-pins/ |
| REVIEW-compact-pins-mel.md | Docs/Reviews/Cycles/compact-pins/ |
| CONSENSUS-compact-pins-kieran.md | Docs/Reviews/Cycles/compact-pins/ |
| CONSENSUS-compact-pins-mel.md | Docs/Reviews/Cycles/compact-pins/ |

**whitespace-jump/**
| Source | Target |
|--------|--------|
| REVIEW-whitespace-jump-fix-kieran.md | Docs/Reviews/Cycles/whitespace-jump/ |
| REVIEW-whitespace-jump-fix-mel.md | Docs/Reviews/Cycles/whitespace-jump/ |

**crash-hang + scroll-bounce consensus (shared date)**
| Source | Target |
|--------|--------|
| CONSENSUS-crash-hang-2026-05-10.md | Docs/Reviews/Cycles/crash-hang/ |
| CONSENSUS-scroll-bounce-2026-05-10.md | Docs/Reviews/Cycles/scroll-bounce/ |

### MOVES TO Docs/Reviews/Final/
| Source | Target | Notes |
|--------|--------|-------|
| REVIEW-FINAL-A.md | Docs/Reviews/Final/ | Final review step A |
| REVIEW-FINAL-A-KIERAN.md | Docs/Reviews/Final/ | Kieran's review of step A |
| REVIEW-FINAL-B.md | Docs/Reviews/Final/ | Final review step B |
| REVIEW-FINAL-BC-KIERAN.md | Docs/Reviews/Final/ | Kieran's review of B/C |
| REVIEW-FINAL-D.md | Docs/Reviews/Final/ | Final review step D |
| REVIEW-FINAL-D-KIERAN.md | Docs/Reviews/Final/ | Kieran's review of step D |
| REVIEW-IMPL-A.md | Docs/Reviews/Final/ | Implementation review A |
| REVIEW-IMPL-B.md | Docs/Reviews/Final/ | Implementation review B |
| REVIEW-IMPL-C.md | Docs/Reviews/Final/ | Implementation review C |
| REVIEW-IMPL-D.md | Docs/Reviews/Final/ | Implementation review D |

### MOVES TO Docs/Reviews/Adversarial/
| Source | Target | Notes |
|--------|--------|-------|
| REVIEWS/Kieran-scroll-fix-adversarial.md | Docs/Reviews/Adversarial/ | Adversarial review |
| Docs/Reviews/kieran-gate-2f-merge-adversarial.md | Docs/Reviews/Adversarial/ | Move from wrong location |

### Docs/Reviews/ REORGANISE
Keep existing component reviews, move step reviews into restoration cycle (Kieran correction — these are NOT component reviews):

| Source | Target | Notes |
|--------|--------|-------|
| Docs/Reviews/COMPONENT-*.md | Docs/Reviews/Components/ (keep existing) | Already well-named |
| Docs/Reviews/kieran-step1-step2-review.md | Docs/Reviews/Cycles/restoration/ | Restoration review, not component |
| Docs/Reviews/kieran-step3-review.md | Docs/Reviews/Cycles/restoration/ | Restoration review, not component |
| Docs/Reviews/kieran-macos-cleanup-eval.md | Docs/Reviews/Adversarial/ | Cleanup evaluation |
| Docs/Reviews/q-step1-step2-review.md | Docs/Reviews/Cycles/restoration/ | Restoration review, not component |
| Docs/Reviews/q-gate-2f-merge-audit.md | Docs/Reviews/Adversarial/ | Audit review |
| Docs/BASELINE-REVIEW-KIERAN.md | Docs/Reviews/Cycles/baseline/ | Kieran's baseline review (was orphaned in Docs/) |

### Docs/ — orphaned files (Kieran identified these as missed)

| Source | Target | Notes |
|--------|--------|-------|
| Docs/BASELINE-PLAN.md | Docs/Specs/Active/ | Active baseline plan |
| Docs/RESPONSE-PERSISTENCE-RESEARCH.md | Docs/Research/ | Research doc, belongs with other research |

### MOVES TO Docs/Diagnosis/
| Source | Target | Notes |
|--------|--------|-------|
| EVALUATION-crash-hang-2026-05-10.md | Docs/Diagnosis/ | Dated evaluation |
| EVALUATION-scroll-bounce-2026-05-10.md | Docs/Diagnosis/ | Dated evaluation |

### MOVES TO Docs/Implementation/
| Source | Target | Notes |
|--------|--------|-------|
| IMPL-FIX-A.md | Docs/Implementation/ | Fix implementation A |
| IMPL-FIX-B.md | Docs/Implementation/ | Fix implementation B |
| IMPL-FIX-C.md | Docs/Implementation/ | Fix implementation C |
| IMPLEMENTATION-compact-pins.md | Docs/Implementation/ | Compact pins impl |

### MOVES TO Docs/Analysis/
| Source | Target | Notes |
|--------|--------|-------|
| DEPENDENCY_ANALYSIS.md | Docs/Analysis/ | One-off dependency analysis |
| LEGACY_CLEANUP_ASSESSMENT.md | Docs/Analysis/ | Legacy cleanup assessment |
| TYPE_CONSOLIDATION_ASSESSMENT.md | Docs/Analysis/ | Type consolidation analysis |
| WEAK_TYPES_ASSESSMENT.md | Docs/Analysis/ | Weak types assessment |
| WEAK_TYPE_ANALYSIS.md | Docs/Analysis/ | Weak type analysis |

### Docs/Specs/ — ACTIVE (Kieran classified)

| File | Reason |
|------|--------|
| C2-AGENT-ACTIVITY-PANEL.md | Active spec, awaiting review |
| COMPOSER-OVERHAUL.md | Active spec, updated with review findings |
| EVAL-DICTATION-OPTIONS.md | Active evaluation, no implementation yet |
| FEAT-010-CLICKABLE-FILE-LINKS.md | Implementation in progress |
| FOLDER-FAVOURITES-SPEC.md | Active feature spec |
| SESSION-KEY-ALIGNMENT-REFACTOR.md | v5 FINAL status, ready for build |
| SESSION-RESET-FLOW.md | Current session reset flow description |
| DIAG-001-delete-topic-not-working.md | P1 diagnostic, still needs investigation |
| FIX-001-DEDUP-GUARD.md | Revised spec, Kieran review passed |
| FIX-002-sidebar-interaction.md | P0, core functionality still broken |
| FIX-003-POLL-SLEEP-BEE-DIAGNOSTICS.md | Awaiting review |
| TOPIC-DELETE-SAFETY.md | DRAFT awaiting Kieran review |
| DOC-REORG-PLAN.md | This plan — moves to Archive after execution |

### Docs/Specs/ — ARCHIVE (Kieran classified)

| File | Reason |
|------|--------|
| BECHAT-CHANNEL-PLUGIN-SPEC.md | Superseded — architecture pivoted |
| COMPONENT-COMPLIANCE-AUDIT.md | Completed — audit done against old architecture |
| CONSOLIDATED-TEAM-REVIEW.md | Historical — reviewed superseded plugin spec |
| EPHEMERAL-SESSIONS.md | Superseded by SESSION-RESET-FLOW + SPEC-session-reset-hybrid-final |
| FEAT-002-THINKING-BEE-INDICATOR.md | Superseded by THINKING-BEE-PARKED |
| FEAT-004-SESSION-RESET.md | Superseded by SESSION-RESET-FLOW + SPEC-session-reset-hybrid-final |
| FEAT-005-TALK-MODE.md | Parked — no active implementation (tag for future) |
| FEAT-005-TALK-MODE-REVIEW.md | Review of parked feature |
| FIX-001-delete-topic-context-menu.md | Superseded by DIAG-001 |
| HOTFIX-001-GRDB-crash.md | Completed — crash is fixed |
| HOTFIX-002-force-unwrap-crash.md | Completed — crash is fixed |
| KIERAN-REVIEW-UNREAD-SPEC.md | Superseded by v2 |
| KIERAN-REVIEW-UNREAD-SPEC-v2.md | Completed — feedback incorporated into v2 spec |
| MESSAGE-DISPLAY-UX.md | P2 backlog — no active implementation |
| MVP-COMPLETION-PLAN.md | Historical — MVP phase completed |
| NEO-REVIEW-UNREAD-SPEC.md | Superseded by v2 |
| NEO-REVIEW-UNREAD-SPEC-v2.md | Completed — feedback incorporated |
| P2-POLISH-SPEC.md | Historical — P2 subsumed by later work |
| PHASE-4-UI-SPEC.md | Historical — Phase 4 completed |
| REFACTOR-001-standard-macos-patterns.md | Superseded — incorporated into later fix specs |
| SIMPLIFIED-CLAWCHAT-PATH.md | Historical — architecture decision, implemented differently |
| TEAM-CONSENSUS-SIMPLIFIED-PATH.md | Historical — consensus reached, implemented |
| THINKING-BEE-PARKED.md | Parked — keep for reference if resumed |
| TOPIC-BLOAT-SPEC.md | Verify overlap with TOPIC-DELETE-SAFETY; likely archive |
| UNREAD-INDICATOR-SPEC.md | Superseded by v2 |
| UNREAD-INDICATOR-SPEC-v2.md | Latest version but pending team review — keep accessible |

### Unread indicator reviews → Docs/Reviews/Cycles/unread-indicator/

| Source | Target |
|--------|--------|
| Docs/Specs/KIERAN-REVIEW-UNREAD-SPEC.md | Docs/Reviews/Cycles/unread-indicator/ |
| Docs/Specs/KIERAN-REVIEW-UNREAD-SPEC-v2.md | Docs/Reviews/Cycles/unread-indicator/ |
| Docs/Specs/NEO-REVIEW-UNREAD-SPEC.md | Docs/Reviews/Cycles/unread-indicator/ |
| Docs/Specs/NEO-REVIEW-UNREAD-SPEC-v2.md | Docs/Reviews/Cycles/unread-indicator/ |

(Kieran flagged: these are reviews masquerading as specs — they belong in review cycles, not in Specs/)

---

## Execution Plan

### Phase 1: Create folder structure (Bee)
- Create all target directories under `Docs/`
- No files moved yet — just the skeleton
- Create `Docs/Specs/Archive/README.md` with archive index template
- Create `Docs/Reviews/INDEX.md` with cycle + author index template

### Phase 2: Cross-reference grep (Bee) — KIERAN REQUIRED ADDITION
- Before any moves: `grep -r '\[.*\](.*\.md' Docs/ SPECS/ *.md` to find all internal doc links
- Also: `grep -r 'Docs/' BeeChat/ --include='*.swift'` to verify no Swift source references doc paths
- Record all cross-references so they can be updated after moves

### Phase 3: Move files (Bee/Q) — MUST USE `git mv`
- Use `git mv` for every file move (not raw `mv` + `git add`) to preserve git history
- Execute all moves per the mapping above
- Update all internal cross-references found in Phase 2
- Remove the empty `SPECS/` and `REVIEWS/` root folders
- Verify no broken references

### Phase 4: Update STATUS.md (Bee)
- Update STATUS.md to reflect new doc structure
- Add a "Documentation Map" section pointing to key active docs
- Update README.md if it references old paths
- Update any references in HANDOFF.md

### Phase 5: Verify (Kieran)
- Kieran spot-checks that everything is in the right place
- Confirms no content was lost
- Verifies all cross-references resolve correctly
- Signs off

### Phase 6: Git commit (Bee/Q)
- Single commit: `chore: reorganise documentation structure`
- No code changes — pure file moves
- After commit, move DOC-REORG-PLAN.md to `Docs/Specs/Archive/`

---

## Principles

1. **No content is deleted** — everything moves, nothing is removed
2. **Kieran decides Active vs Archive** for specs — not Bee or Q
3. **Root stays clean** — only STATUS, README, HANDOFF, DEBUG at root
4. **Group by topic, then by type** — review cycles live together
5. **Date-stamped files keep their dates** — we don't rename for the sake of it
6. **One source of truth per topic** — no more SPECS/ vs Docs/Specs/ split
7. **Use `git mv`** — preserves git history and `git log --follow`
8. **Active → Archive convention** — when a spec is implemented and verified, the implementing agent moves it to Archive
9. **Archive README** — every archived spec listed with superseded-by note

---

## Resolved Questions (Kieran review)

1. **DEBUG.md** → Moves to `Docs/Status/` (Kieran: root should be minimal)
2. **HANDOFF.md** → Stays at root (operational, rewritten every session)
3. **Swift source doc references** → Verify with grep before moving (Phase 2)
4. **Charles involvement** → Not needed for structural reorg, Kieran sign-off sufficient
5. **Unread indicator reviews** → Move to `Docs/Reviews/Cycles/unread-indicator/` (they're reviews, not specs)
6. **Baseline review** → Move to `Docs/Reviews/Cycles/baseline/`
7. **Restoration step reviews** → Move to `Docs/Reviews/Cycles/restoration/` (not Components/)
8. **Parked specs** → Tag with `<!-- parked: may resume -->` so they're findable

---

## Kieran Review Summary

Full review at: `Docs/Reviews/DOC-REORG-KIERAN-REVIEW.md`

**7 required changes (all incorporated above):**
1. Add 5 missing files to mapping (BASELINE-PLAN, BASELINE-REVIEW-KIERAN, RESPONSE-PERSISTENCE-RESEARCH, C2-AGENT-ACTIVITY-PANEL, DOC-REORG-PLAN itself)
2. Fix step review mapping — restoration cycle, not Components/
3. Add unread-indicator and baseline review cycles
4. Add Archive README and Reviews INDEX
5. Specify `git mv` in execution plan
6. Add cross-reference grep step before moves
7. Move DEBUG.md to Docs/Status/ instead of keeping at root