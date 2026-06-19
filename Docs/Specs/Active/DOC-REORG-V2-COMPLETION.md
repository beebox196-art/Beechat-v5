# DOC-REORG-V2: BeeChat-v5 Completion Plan

**Created:** 2026-06-19
**Author:** Bee (coordinator)
**Status:** PENDING — awaiting Adam go-ahead
**Predecessor:** DOC-REORG-001 (mostly executed, folder structure created, bulk files moved)

## Problem

DOC-REORG-001 was approved and mostly executed. The folder structure is in place, bulk files are moved, and Archive/Reviews are organised. However, several loose ends remain:

1. **5 loose review files** in `Docs/Reviews/` that belong in existing cycle folders
2. **39 Active specs**, many of which are completed/superseded and should be archived
3. **Root VISION.md** — should it stay or move?
4. **Docs/PROCESS.md** — loose file not in a subfolder
5. **No master index** for Active specs (hard to see what's actually current)
6. **Reviews INDEX.md** needs updating for recent review cycles (BeeBoard Archive, Gate 2F, backout)

## Loose Review Files → Cycles

| Current Location | Target | Notes |
|---|---|---|
| `Docs/Reviews/BACKOUT-IMPL-KIERAN-REVIEW.md` | `Docs/Reviews/Cycles/backout/` | Gate 2F backout review |
| `Docs/Reviews/BACKOUT-IMPL-Q-REVIEW.md` | `Docs/Reviews/Cycles/backout/` | Gate 2F backout review |
| `Docs/Reviews/KIERAN-BACKOUT-V2-REVIEW.md` | `Docs/Reviews/Cycles/backout/` | Gate 2F backout v2 review |
| `Docs/Reviews/Q-BACKOUT-V2-REVIEW.md` | `Docs/Reviews/Cycles/backout/` | Gate 2F backout v2 review |
| `Docs/Reviews/GATE-2F-FIX-KIERAN-REVIEW.md` | `Docs/Reviews/Cycles/gate-2f/` | Gate 2F fix review |
| `Docs/Reviews/GATE-2F-MAC-PUBLISH-KIERAN-REVIEW.md` | `Docs/Reviews/Cycles/gate-2f/` | Gate 2F publish review |
| `Docs/Reviews/GATE-2F-MAC-PUBLISH-Q-REVIEW.md` | `Docs/Reviews/Cycles/gate-2f/` | Gate 2F publish review |

Also create new cycle folders:
- `Docs/Reviews/Cycles/backout/` (4 files)
- `Docs/Reviews/Cycles/gate-2f/` (3 files + the 2 Gate 2F spec reviews already in Docs/Reviews/)

## Active Specs → Archive Audit

Of the 39 files in `Docs/Specs/Active/`, these should move to Archive:

| File | Reason | Status |
|---|---|---|
| `BEECHAT-RESTORATION-PLAN.md` | Superseded — restoration completed | Archive |
| `C2-AGENT-ACTIVITY-PANEL.md` | Superseded — not in current roadmap | Archive |
| `COMPOSER-OVERHAUL.md` | Stale — no implementation, 2026-05-05 | Archive (parked) |
| `EVAL-DICTATION-OPTIONS.md` | Evaluation complete, no implementation | Archive |
| `FEAT-010-CLICKABLE-FILE-LINKS.md` | Check if built; likely superseded | Verify then Archive |
| `FEAT-011-SEED-CLAude-oversight-folder.md` | One-off task, likely done | Verify then Archive |
| `FIX-001-DEDUP-GUARD.md` | Implemented and verified (in STATUS ✅) | Archive |
| `FIX-002-sidebar-interaction.md` | Check if still relevant | Verify |
| `FIX-003-POLL-SLEEP-BEE-DIAGNOSTICS.md` | Stale diagnostic, 2026-era | Verify then Archive |
| `GATE-2F-BACKOUT.md` | Completed — backout done | Archive |
| `GATE-2F-FIX-SAFE-RECONCILE.md` | Completed — fix applied | Archive |
| `GATE-2F-MAC-TOPIC-PUBLISH.md` | Completed — ✅ in STATUS | Archive |
| `GATE-2F-REST-OVER-TAILSCALE.md` | Completed — ✅ in STATUS | Archive |
| `SCROLL-BOUNCE-FIX.md` | Superseded — implemented (✅ v4 scroll) | Archive |
| `SESSION-KEY-ALIGNMENT-REFACTOR.md` | Status says "v5 FINAL, ready for build" — verify if built | Verify |
| `SESSION-RESET-FLOW.md` | Superseded by SPEC-session-reset-hybrid-final | Archive |
| `SPEC-FIX-A-double-resume.md` | Approved and implemented (✅ in STATUS) | Archive |
| `SPEC-FIX-B-streaming-state.md` | Approved and implemented (✅ in STATUS) | Archive |
| `SPEC-FIX-C-poll-guard.md` | Approved and implemented (✅ in STATUS) | Archive |
| `SPEC-compact-pins.md` | Implemented (✅ in STATUS) | Archive |
| `SPEC-reset-flow-refactor.md` | Superseded by hybrid-final | Archive |
| `SPEC-scroll-fix.md` | Superseded — v4 scroll approach is ✅ | Archive |
| `SPEC-session-reset-hybrid-final.md` | Check if this is the current reset mechanism | Verify |
| `SPEC-session-reset-options.md` | Superseded by hybrid-final | Archive |
| `SPEC-whitespace-jump-fix.md` | Check if implemented | Verify |
| `TOPIC-DELETE-SAFETY.md` | DRAFT since Apr, no movement | Verify then Archive/Park |
| `TOPIC-PROJECT-CONTINUITY.md` | ✅ in STATUS | Archive |
| `TOPIC-PROJECT-CONTINUITY-KIERAN-IMPL-REVIEW.md` | Review of completed feature → Reviews | Move to Reviews/Cycles/topic-continuity/ |
| `TOPIC-PROJECT-CONTINUITY-MEL-REVIEW.md` | Review of completed feature → Reviews | Move to Reviews/Cycles/topic-continuity/ |
| `TOPIC-PROJECT-CONTINUITY-REVIEW.md` | Review of completed feature → Reviews | Move to Reviews/Cycles/topic-continuity/ |
| `TOPIC-SUMMARY-PIPELINE.md` | Check if implemented | Verify |
| `TOPIC-SUMMARY-PIPELINE-KIERAN-REVIEW.md` | Review → Reviews | Move to Reviews/Cycles/topic-summary/ |
| `TOPIC-SUMMARY-PIPELINE-MEL-REVIEW.md` | Review → Reviews | Move to Reviews/Cycles/topic-summary/ |
| `TOPIC-SUMMARY-PIPELINE-Q-REVIEW.md` | Review → Reviews | Move to Reviews/Cycles/topic-summary/ |

**Truly Active (keep):**
| File | Reason |
|---|---|
| `BASELINE-PLAN.md` | Draft, pending approval |
| `DIAG-001-delete-topic-not-working.md` | Active diagnostic |
| `DOC-REORG-PLAN.md` | This re-org plan (move to Archive after completion) |
| `DOC-REORG-V2-COMPLETION.md` | This file (move to Archive after completion) |
| `FOLDER-FAVOURITES-SPEC.md` | Active feature request |
| `FR-002-TAP-TO-RECONNECT.md` | Current spec — pending review → build |
| `SESSION-RESET-FLOW.md` | Keep if it describes current behaviour (verify) |

After verification and moves, Active should have ~8-10 specs, down from 39.

## Root Files

| File | Action |
|---|---|
| `VISION.md` | Move to `Docs/Vision/` (create folder) — it's a vision doc, not a status file |
| `Docs/PROCESS.md` | Move to `Docs/Status/` — it's a process document |

## Reviews INDEX.md Update

Add these cycles:
- **backout** — 4 files (Kieran + Q reviews of Gate 2F backout)
- **gate-2f** — 3+ files (fix + publish reviews)
- **beeboard-archive** — already exists (1 file)
- **tap-to-reconnect** — FR-002 review (pending)

## Execution

1. Verify each spec status against STATUS.md and git history
2. `git mv` confirmed archive candidates
3. Create new cycle folders and move review files
4. Update Reviews/INDEX.md
5. Update Specs/Archive/README.md
6. Create Specs/Active/INDEX.md (one-line summary of each active spec)
7. Move VISION.md → Docs/Vision/, Docs/PROCESS.md → Docs/Status/
8. Single commit: `chore: complete doc re-org — archive completed specs, organise reviews`