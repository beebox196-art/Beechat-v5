# DOC-REORG-001: Kieran Adversarial Review

**Reviewer:** Kieran (adversarial)  
**Date:** 2026-05-26  
**Plan reviewed:** DOC-REORG-PLAN.md (DRAFT)  
**Verdict:** ⚠️ APPROVED WITH REQUESTED CHANGES

---

## 1. Docs/Specs/ Classification — Active vs Archive

Every file in `Docs/Specs/` classified, with reason.

### ACTIVE — Currently Relevant

| # | File | Reason |
|---|------|--------|
| 1 | `C2-AGENT-ACTIVITY-PANEL.md` | Active spec, status "awaiting Kieran review" |
| 2 | `COMPOSER-OVERHAUL.md` | Active spec, updated 2026-05-05 with review findings |
| 3 | `EVAL-DICTATION-OPTIONS.md` | Active evaluation, no implementation yet |
| 4 | `FEAT-010-CLICKABLE-FILE-LINKS.md` | Implementation in progress per status |
| 5 | `FOLDER-FAVOURITES-SPEC.md` | Active feature spec |
| 6 | `SESSION-KEY-ALIGNMENT-REFACTOR.md` | v5 FINAL status, ready for build |
| 7 | `DIAG-001-delete-topic-not-working.md` | P1 diagnostic, still needs investigation |
| 8 | `FIX-001-DEDUP-GUARD.md` | Revised spec, Kieran review passed |
| 9 | `FIX-002-sidebar-interaction.md` | P0, core functionality still broken — must stay active |
| 10 | `FIX-003-POLL-SLEEP-BEE-DIAGNOSTICS.md` | Active spec, awaiting review |
| 11 | `SESSION-RESET-FLOW.md` | Current session reset flow description |
| 12 | `TOPIC-DELETE-SAFETY.md` | DRAFT awaiting Kieran review |
| 13 | `DOC-REORG-PLAN.md` | This plan itself — stays active until executed, then moves to Archive |

### ARCHIVE — Completed, Superseded, or Historical

| # | File | Reason |
|---|------|--------|
| 14 | `BECHAT-CHANNEL-PLUGIN-SPEC.md` | Superseded — architecture pivoted to current plugin approach; historical reference only |
| 15 | `COMPONENT-COMPLIANCE-AUDIT.md` | Completed — audit done against old architecture, no longer actionable |
| 16 | `CONSOLIDATED-TEAM-REVIEW.md` | Historical — reviewed the now-superseded plugin spec |
| 17 | `EPHEMERAL-SESSIONS.md` | Superseded — evolved into `SESSION-RESET-FLOW.md` and `SPEC-session-reset-hybrid-final.md` |
| 18 | `FEAT-002-THINKING-BEE-INDICATOR.md` | Parked — superseded by `THINKING-BEE-PARKED.md` |
| 19 | `FEAT-004-SESSION-RESET.md` | Superseded — evolved into `SESSION-RESET-FLOW.md` + `SPEC-session-reset-hybrid-final.md` |
| 20 | `FEAT-005-TALK-MODE.md` | Future option, not active — no implementation planned |
| 21 | `FEAT-005-TALK-MODE-REVIEW.md` | Review of parked feature, not actionable |
| 22 | `FIX-001-delete-topic-context-menu.md` | Superseded by `DIAG-001-delete-topic-not-working.md` (the issue was re-diagnosed) |
| 23 | `HOTFIX-001-GRDB-crash.md` | Completed hotfix — GRDB crash is fixed |
| 24 | `HOTFIX-002-force-unwrap-crash.md` | Completed hotfix — force-unwrap crash is fixed |
| 25 | `KIERAN-REVIEW-UNREAD-SPEC.md` | Superseded by v2 review |
| 26 | `KIERAN-REVIEW-UNREAD-SPEC-v2.md` | Completed — feedback incorporated into `UNREAD-INDICATOR-SPEC-v2.md` |
| 27 | `MESSAGE-DISPLAY-UX.md` | P2 backlog item — not blocking, no active implementation |
| 28 | `MVP-COMPLETION-PLAN.md` | Historical — MVP phase completed |
| 29 | `NEO-REVIEW-UNREAD-SPEC.md` | Superseded by v2 review |
| 30 | `NEO-REVIEW-UNREAD-SPEC-v2.md` | Completed — feedback incorporated into `UNREAD-INDICATOR-SPEC-v2.md` |
| 31 | `P2-POLISH-SPEC.md` | Historical — P2 polish phase subsumed by later work |
| 32 | `PHASE-4-UI-SPEC.md` | Historical — Phase 4 completed |
| 33 | `REFACTOR-001-standard-macos-patterns.md` | Superseded — incorporated into later fix specs |
| 34 | `SIMPLIFIED-CLAWCHAT-PATH.md` | Historical — architecture decision recorded, implemented differently |
| 35 | `TEAM-CONSENSUS-SIMPLIFIED-PATH.md` | Historical — consensus was to adopt simplified path, now done |
| 36 | `THINKING-BEE-PARKED.md` | Parked — not active, but worth keeping for reference if resumed |
| 37 | `TOPIC-BLOAT-SPEC.md` | Check status — may be superseded by `TOPIC-DELETE-SAFETY.md`; archive if so |
| 38 | `UNREAD-INDICATOR-SPEC.md` | Superseded by v2 |
| 39 | `UNREAD-INDICATOR-SPEC-v2.md` | Active-ish — pending team review, but the spec itself is the latest version |

### Classification Notes

- **`UNREAD-INDICATOR-SPEC-v2.md`**: I've put this in Archive because v1 is clearly superseded, but v2 could arguably stay Active since it's "pending team review." The safe call: keep it in Archive but tag it `/* pending-review */` or add a note that it needs re-review before implementation. If the team is about to pick it up, move it back to Active.
- **`TOPIC-BLOAT-SPEC.md`**: May overlap with `TOPIC-DELETE-SAFETY.md`. If bloat management was subsumed into the delete-safety spec, archive it. If it covers different ground (e.g. topic pruning), it could stay Active. **Recommend keeping in Active** until confirmed it's covered elsewhere.
- **`FEAT-005-TALK-MODE.md`**: "Future option" is not the same as "archive." It's intentionally parked, not abandoned. I've put it in Archive but it should be tagged so it can be found if voice features come back on the roadmap.
- **`DOC-REORG-PLAN.md`**: Should stay in Active until execution is complete, then move to Archive.

---

## 2. Corrections to the File Mapping

### 2.1 Files Missing from the Plan

The plan does not account for these files:

| File | Location | Recommended Target | Reason |
|------|----------|---------------------|--------|
| `Docs/BASELINE-PLAN.md` | Docs/ (root level) | `Docs/Specs/Active/` | Active baseline plan, pending Adam approval |
| `Docs/BASELINE-REVIEW-KIERAN.md` | Docs/ (root level) | `Docs/Reviews/Components/` or `Docs/Reviews/Adversarial/` | Kieran's baseline review |
| `Docs/RESPONSE-PERSISTENCE-RESEARCH.md` | Docs/ (root level) | `Docs/Research/` | Research document, belongs with other research |
| `Docs/History/GATEWAY-PROBE-CAPTURE.json` | Docs/History/ | Leave in place | Non-md data capture, stays in History |
| `Docs/Status/HANDOFF-RESEARCH-2026-04-17.md` | Docs/Status/ | Leave in place | Already correctly placed |
| `Docs/Specs/C2-AGENT-ACTIVITY-PANEL.md` | Docs/Specs/ | `Docs/Specs/Active/` | **Not listed in the plan's file mapping at all** |
| `Docs/Specs/DOC-REORG-PLAN.md` | Docs/Specs/ | `Docs/Specs/Active/` | The plan itself — needs to survive the reorg |

**The plan's "Likely Active" list omits `C2-AGENT-ACTIVITY-PANEL.md` and `DOC-REORG-PLAN.md`.** These need to be added.

### 2.2 Misclassified or Borderline Files

| File | Plan says | My classification | Reason |
|------|-----------|-------------------|--------|
| `FIX-001-delete-topic-context-menu.md` | Archive | Archive ✅ | Correct — superseded by DIAG-001 |
| `UNREAD-INDICATOR-SPEC-v2.md` | Not classified | Archive with note ⚠️ | Superseded v1, but v2 still pending review |
| `TOPIC-BLOAT-SPEC.md` | Not classified | Active (tentative) | May still be relevant; verify overlap with TOPIC-DELETE-SAFETY |
| `FEAT-005-TALK-MODE.md` | Not classified | Archive (parked) | Not abandoned, but no active work |
| `DIAG-001-delete-topic-not-working.md` | Not classified | Active | P1 diagnostic, still open |
| `SESSION-RESET-FLOW.md` | Not classified | Active | Current flow description |
| `FIX-002-sidebar-interaction.md` | Not classified | Active | P0, core feature still broken |
| `FIX-003-POLL-SLEEP-BEE-DIAGNOSTICS.md` | Not classified | Active | Awaiting review |

### 2.3 `Docs/BASELINE-PLAN.md` and `Docs/BASELINE-REVIEW-KIERAN.md`

These are sitting at the top level of `Docs/` (not in any subfolder). The plan says to leave `Docs/Architecture/`, `Docs/Design/`, `Docs/Research/`, and `Docs/History/` "as-is" but doesn't address these two files sitting in `Docs/` root. They need a target:

- `Docs/BASELINE-PLAN.md` → `Docs/Specs/Active/` (it's an active plan, pending approval)
- `Docs/BASELINE-REVIEW-KIERAN.md` → `Docs/Reviews/Adversarial/` (Kieran's adversarial review)

### 2.4 `Docs/RESPONSE-PERSISTENCE-RESEARCH.md`

This file is in `Docs/` root (no subfolder). It should move to `Docs/Research/` where it belongs with the other research docs.

### 2.5 Review Files in `Docs/Reviews/` — Plan Mapping Check

The plan maps these `Docs/Reviews/` files:

| File | Plan says | My assessment |
|------|-----------|---------------|
| `kieran-step1-step2-review.md` | → Components/ | ⚠️ This is a restoration review, not a component review. Better in `Docs/Reviews/Adversarial/` or a new `Docs/Reviews/Restoration/` subfolder |
| `kieran-step3-review.md` | → Components/ | Same concern — these are step-based reviews of the restoration, not component reviews |
| `kieran-macos-cleanup-eval.md` | → Components/ | This is an evaluation, not a component review. Better in `Docs/Reviews/Adversarial/` or `Docs/Diagnosis/` |
| `q-step1-step2-review.md` | → Components/ | Same as kieran-step1-step2 — restoration review |
| `q-gate-2f-merge-audit.md` | → Adversarial/ | ✅ Correct — this is an audit/adversarial review |

**Recommendation:** The step reviews (step1/step2/step3) are part of a restoration review cycle, not component reviews. Create a `Docs/Reviews/Cycles/restoration/` subfolder, or at minimum don't put them in `Components/` where they'll be confused with the `COMPONENT-1/2/3-*` reviews which are about the persistence/gateway/sync-bridge components.

### 2.6 `REVIEWS/Kieran-scroll-fix-adversarial.md`

The plan correctly maps this to `Docs/Reviews/Adversarial/`. ✅

---

## 3. Duplicate / Collision Check

### 3.1 SPECS/ vs Docs/Specs/ Filename Collisions

**No collisions.** I verified: `comm -12` between the basenames of `SPECS/` and `Docs/Specs/` returns empty. All 22 files in `SPECS/` can be safely moved into `Docs/Specs/Archive/` without overwriting anything.

### 3.2 Root .md Files Moving Into Docs/ — Collision Risk

All root-level files being moved have unique names. No collisions with existing `Docs/` subfolder contents. ✅

### 3.3 Potential Semantic Duplicates (Same Topic, Different Names)

| Topic | Files | Risk |
|-------|-------|------|
| Session reset | `FEAT-004-SESSION-RESET.md`, `SESSION-RESET-FLOW.md`, `SPEC-session-reset-hybrid-final.md`, `SPEC-session-reset-options.md`, `EPHEMERAL-SESSIONS.md` | Not a file collision, but 5 files on one topic. After archiving the superseded ones, only `SESSION-RESET-FLOW.md` and the SPEC files should remain Active |
| Unread indicator | `UNREAD-INDICATOR-SPEC.md`, `UNREAD-INDICATOR-SPEC-v2.md`, `KIERAN-REVIEW-UNREAD-SPEC.md`, `KIERAN-REVIEW-UNREAD-SPEC-v2.md`, `NEO-REVIEW-UNREAD-SPEC.md`, `NEO-REVIEW-UNREAD-SPEC-v2.md` | After archiving v1 + reviews, only v2 spec stays. **Should these reviews go into a `Reviews/Cycles/unread-indicator/` folder instead of Archive?** |
| Fix-001 | `FIX-001-delete-topic-context-menu.md`, `FIX-001-DEDUP-GUARD.md`, `DIAG-001-delete-topic-not-working.md` | Two FIX-001s with different scopes. Not a collision since filenames differ, but the numbering conflict is confusing. Noted for future cleanup. |
| Thinking Bee | `FEAT-002-THINKING-BEE-INDICATOR.md`, `THINKING-BEE-PARKED.md` | Parked file effectively supersedes the spec. Archive both. |

### 3.4 Review Cycle Grouping — Missing Cycles

The plan groups reviews into cycles:
- crash-hang ✅
- scroll-bounce ✅
- session-reset ✅
- compact-pins ✅
- whitespace-jump ✅

**Missing review cycles that should exist:**

| Cycle | Files | Where |
|-------|-------|-------|
| **unread-indicator** | `KIERAN-REVIEW-UNREAD-SPEC.md`, `KIERAN-REVIEW-UNREAD-SPEC-v2.md`, `NEO-REVIEW-UNREAD-SPEC.md`, `NEO-REVIEW-UNREAD-SPEC-v2.md` | Currently in `Docs/Specs/` |
| **baseline** | `Docs/BASELINE-REVIEW-KIERAN.md` | Currently in `Docs/` root |
| **restoration** | `kieran-step1-step2-review.md`, `kieran-step3-review.md`, `q-step1-step2-review.md` | Currently in `Docs/Reviews/` |

The unread-indicator reviews are currently classified as "specs" but they're really reviews. They should move to `Docs/Reviews/Cycles/unread-indicator/`.

---

## 4. Content Loss Check

### 4.1 Would any content be lost?

**No.** The plan explicitly states "No content is deleted — everything moves, nothing is removed." I've verified:

- Every root `.md` file has a mapping target
- Every `SPECS/` file has a mapping target  
- Every `Docs/Specs/` file is accounted for (in my classification above)
- Every `Docs/Reviews/` file has a mapping target
- `REVIEWS/` root folder content is mapped

### 4.2 Near-miss: Files not in the plan

The plan missed 3 files that I've identified:
1. `Docs/BASELINE-PLAN.md` — must be moved, not left orphaned
2. `Docs/BASELINE-REVIEW-KIERAN.md` — must be moved
3. `Docs/RESPONSE-PERSISTENCE-RESEARCH.md` — must be moved

If these aren't moved, they'll be orphaned in `Docs/` root with no subfolder, which contradicts the plan's goal of clean structure.

### 4.3 Near-miss: `Docs/Specs/C2-AGENT-ACTIVITY-PANEL.md`

This file exists in `Docs/Specs/` but is not listed in the plan's "Likely Active" or "Likely Archive" lists. It must be classified.

### 4.4 `Docs/History/GATEWAY-PROBE-CAPTURE.json`

Not a `.md` file, so not in scope of this reorg. Leave it in place. ✅

---

## 5. Risks and Concerns

### 5.1 Execution Risk: Git History

**Risk:** Moving 50+ files in one commit makes `git blame` and `git log --follow` harder to use.  
**Mitigation:** Use `git mv` for every move. Git tracks renames. The single-commit approach is correct, but every move must be a proper `git mv` so `--follow` works. The plan says "pure file moves" which implies this, but it should be explicit: **use `git mv`, not `mv` + `git add`.**

### 5.2 Cross-Reference Risk

**Risk:** Internal doc links (relative paths like `[see](../Specs/FIX-002-sidebar-interaction.md)`) will break after the reorg.  
**Mitigation:** The plan mentions "Update any internal cross-references in docs" in Phase 3. This is critical. I recommend:
- Before moving, grep all `.md` files for relative links: `grep -r '\[.*\](.*\.md' Docs/ SPECS/ *.md`
- After moving, verify every link resolves
- Consider a CI check or pre-commit hook that validates internal links

### 5.3 Scope Creep Risk

**Risk:** The plan says "no code impact" which is correct for the move itself, but if cross-references exist in Swift source code or build files pointing to doc paths, those could break.  
**Mitigation:** Grep the Swift source for any doc path references: `grep -r 'Docs/' BeeChat/ --include='*.swift'`. I'd expect none, but worth verifying.

### 5.4 Active Docs in Archive

**Risk:** Some "Archive" docs may be referenced by active code or in-progress work. Specifically:
- `HOTFIX-001-GRDB-crash.md` and `HOTFIX-002-force-unwrap-crash.md` — if the app still has related TODO/FIXME comments referencing these, they should be findable
- `FIX-001-delete-topic-context-menu.md` was the original spec; if anyone searches for it by name, it needs to be discoverable in Archive

**Mitigation:** Add a `README.md` in `Docs/Specs/Archive/` that lists all archived specs with a one-line description and a note like "See Active/ for current specs." This is a cheap index that prevents lost docs.

### 5.5 Review Cycle Grouping May Obscure Relationships

**Risk:** Grouping reviews by cycle (crash-hang, scroll-bounce, etc.) is good for understanding a specific bug's history, but makes it harder to find "all Kieran reviews" or "all Q reviews."  
**Mitigation:** Consider adding a lightweight `Docs/Reviews/INDEX.md` that lists reviews by both cycle and author. Not complex — just a two-section markdown file.

### 5.6 `Docs/Specs/Active/` vs `Docs/Specs/Archive/` Maintenance

**Risk:** Over time, Active will accumulate completed specs that should move to Archive, but nobody will move them.  
**Mitigation:** Add a convention: when a spec is implemented and verified, the implementing agent moves it to Archive. Add this to the README in `Docs/Specs/`.

### 5.7 `DEBUG.md` at Root

**Risk:** The plan proposes keeping `DEBUG.md` at root "while active, move when resolved." This is fine but there's no mechanism to move it.  
**Mitigation:** Add a note in STATUS.md or HANDOFF.md: "When DEBUG.md is resolved, move to `Docs/Status/`." Or better: just put it in `Docs/Status/` from the start and add a symlink at root if needed. Root should be clean.

### 5.8 `HANDOFF.md` at Root

The plan recommends keeping HANDOFF.md at root. This makes sense — it's operational and agent-dependent. ✅ No concern.

---

## 6. Corrections Summary

| # | Issue | Fix |
|---|-------|-----|
| 1 | `Docs/BASELINE-PLAN.md` not mapped | → `Docs/Specs/Active/` |
| 2 | `Docs/BASELINE-REVIEW-KIERAN.md` not mapped | → `Docs/Reviews/Adversarial/` |
| 3 | `Docs/RESPONSE-PERSISTENCE-RESEARCH.md` not mapped | → `Docs/Research/` |
| 4 | `Docs/Specs/C2-AGENT-ACTIVITY-PANEL.md` not classified | → Active |
| 5 | `Docs/Specs/DOC-REORG-PLAN.md` not classified | → Active (until execution complete, then Archive) |
| 6 | Step reviews (step1/2/3) mapped to Components/ | → Create `Reviews/Cycles/restoration/` or use `Reviews/Adversarial/` |
| 7 | `kieran-macos-cleanup-eval.md` mapped to Components/ | → `Reviews/Adversarial/` or `Diagnosis/` (it's an evaluation, not a component review) |
| 8 | Unread indicator reviews not grouped into a cycle | → `Reviews/Cycles/unread-indicator/` |
| 9 | Baseline review not grouped into a cycle | → `Reviews/Cycles/baseline/` or `Reviews/Adversarial/` |
| 10 | No `README.md` proposed for `Docs/Specs/Archive/` | → Add archive index |
| 11 | No `INDEX.md` proposed for `Docs/Reviews/` | → Add author + cycle index |
| 12 | Plan should specify `git mv` not `mv` + `git add` | → Add to execution plan |
| 13 | Cross-reference validation not detailed enough | → Add grep-before-move step |

---

## 7. Proposed Additional Structure

### 7.1 `Docs/Specs/Archive/README.md`

```markdown
# Archived Specs

Superseded, completed, or historical specifications.
For current specs, see `../Active/`.

| Spec | Superseded By | Archived Date |
|------|---------------|---------------|
| ... | ... | ... |
```

### 7.2 `Docs/Reviews/INDEX.md`

```markdown
# Reviews Index

## By Cycle
- crash-hang/ — Crash and hang diagnosis cycle (May 10)
- scroll-bounce/ — Scroll bounce fix cycle (May 10)
- session-reset/ — Session reset design cycle
- compact-pins/ — Compact pins feature cycle
- whitespace-jump/ — Whitespace jump fix cycle
- unread-indicator/ — Unread indicator spec reviews
- baseline/ — Baseline/tagging review

## By Author
- Kieran: ...
- Q: ...
- Mel: ...
```

---

## 8. Open Questions — Resolved

| # | Question | My Recommendation |
|---|----------|-------------------|
| 1 | DEBUG.md at root or Docs/Status/? | **Docs/Status/** — root should be minimal. If agents need quick access, they know where to look. |
| 2 | HANDOFF.md at root or Docs/Status/? | **Root** — it's operational and rewritten every session. Keep it accessible. |
| 3 | Swift source doc references? | Verify with `grep -r 'Docs/' BeeChat/ --include='*.swift'` before moving. Expected: none. |
| 4 | Does Charles need to review? | Not for this reorg. It's structural, not content. Kieran sign-off is sufficient. |

---

## 9. Sign-off

**Status: ⚠️ APPROVED WITH CHANGES**

The plan is sound in principle. The structure makes sense, the Active/Archive split is the right call, and grouping reviews by cycle is better than the current flat mess. No content would be lost.

**Required changes before execution:**

1. Add the 5 missing files to the mapping (BASELINE-PLAN, BASELINE-REVIEW-KIERAN, RESPONSE-PERSISTENCE-RESEARCH, C2-AGENT-ACTIVITY-PANEL, DOC-REORG-PLAN itself)
2. Fix the step review mapping — don't put restoration reviews in `Components/`
3. Add `unread-indicator` and `baseline` review cycles
4. Add `README.md` to `Docs/Specs/Archive/` and `INDEX.md` to `Docs/Reviews/`
5. Specify `git mv` in the execution plan
6. Add a cross-reference grep step before Phase 3 moves
7. Consider `Docs/Status/` for DEBUG.md instead of root

**Optional improvements:**

- Add a convention for promoting Active → Archive (in the Active README)
- Verify no Swift source references to doc paths
- Tag parked specs (TALK-MODE, THINKING-BEE) so they're findable if resumed

Once these changes are incorporated, I'm happy to sign off on execution.

---

*Kieran — 2026-05-26*