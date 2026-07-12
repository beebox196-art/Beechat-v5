# Active Specs Index — BeeChat-v5

**Last Updated:** 2026-06-20
**Total Active:** 8 specs (+ 2 re-org plans + this index)

## Active Architecture Specs

| Spec | Description | Status |
|------|-------------|--------|
| `single-webview-transcript-plan.md` | Option B — single-WebView transcript; phased route (B-0…B-5) with gates, bridge protocol, deletion ledger | APPROVED DIRECTION (Adam 2026-07-12), gates pending |

## Active Feature Specs

| Spec | Description | Status |
|------|-------------|--------|
| `FR-002-TAP-TO-RECONNECT.md` | Tap status bar to reconnect when offline | ✅ MERGED v0.9.1 |
| `FR-003-RESEARCH-PIPELINE.md` | Server-side research pipeline triggered by `/research` command | ✅ MERGED v0.9.2 |
| `FOLDER-FAVOURITES-SPEC.md` | Favourite folders in sidebar | Feature request, pending scope |
| `BASELINE-PLAN.md` | Baseline stabilisation plan | Draft, pending approval |

## Active Diagnostics

| Spec | Description | Status |
|------|-------------|--------|
| `DIAG-001-delete-topic-not-working.md` | P1 diagnostic for topic deletion | Active investigation |

## Active Fix Specs

| Spec | Description | Status |
|------|-------------|--------|
| `FIX-002-sidebar-interaction.md` | Sidebar interaction — standard macOS patterns | P0, needs verification if still relevant |
| `FIX-003-POLL-SLEEP-BEE-DIAGNOSTICS.md` | Poll spin loop + thinking Bee state | Needs verification |
| `SESSION-KEY-ALIGNMENT-REFACTOR.md` | Session key alignment refactor | v5 FINAL, ready for build |
| `TOPIC-DELETE-SAFETY.md` | Topic delete safety spec | DRAFT since Apr, urgent portion superseded by FR-004 |
| `FR-004-URGENT-DELETE-CONFIRM.md
FR-005-RESET-MARKER-FEEDBACK.md` | Urgent confirm-gate for the 3 delete paths | DRAFT, for Kieran review |

## Re-org Plans (Archive after execution)

| File | Notes |
|------|-------|
| `DOC-REORG-PLAN.md` | Original re-org — executed |
| `DOC-REORG-V2-COMPLETION.md` | V2 completion plan — executing |

## Archive Summary

Moved to `Docs/Specs/Archive/` during re-org (Jun 19):
- Implemented: FIX-001, GATE-2F (×4), SPEC-FIX-A/B/C, SPEC-compact-pins, SCROLL-BOUNCE-FIX, TOPIC-PROJECT-CONTINUITY, FEAT-010, FEAT-011, TOPIC-SUMMARY-PIPELINE, BEECHAT-RESTORATION-PLAN
- Superseded: SESSION-RESET-FLOW, SPEC-session-reset-options, SPEC-reset-flow-refactor, SPEC-scroll-fix, SPEC-session-reset-hybrid-final, SPEC-whitespace-jump-fix
- Parked: C2-AGENT-ACTIVITY-PANEL, COMPOSER-OVERHAUL, EVAL-DICTATION-OPTIONS