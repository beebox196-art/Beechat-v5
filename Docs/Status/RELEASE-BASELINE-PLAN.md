# Release Baseline Plan — BeeChat-v5 v0.9.1

**Created:** 2026-06-19
**Author:** Bee
**Status:** DRAFT — pending Adam approval

## Purpose

Adam wants a "line in the sand" — a stable release point we can build from. No more diversion development. This document defines what goes into the baseline and how we manage changes going forward.

## Current State (develop @ 012e7c5 + FR-002)

| Field | Value |
|---|---|
| Branch | `develop` |
| Stable since | Jun 16 (0582aac — BeeBoard Archive) |
| FR-002 branch | `feature/FR-002-tap-to-reconnect` (pending code review + smoke test) |
| Known issues | KI-1 (scroll bounce, low), KI-2 (test hang, low), KI-4 (logger export, low) |
| Feature count | 12 ✅ features on develop |

## Baseline Plan

### Step 1: Complete FR-002
- Kieran code review (in progress)
- Fix any blockers
- Adam smoke test (disconnect gateway → tap → verify messages flow)
- Merge to develop

### Step 2: Tag the baseline
```
git checkout develop
git tag v0.9.1 -m "Baseline release — FR-002 tap-to-reconnect, stable gateway, BeeBoard archive"
git push origin v0.9.1
```

### Step 3: Merge to main
- `git checkout main`
- `git merge develop --no-ff`
- Adam explicit approval required
- Tag main as `v0.9.1-release`

### Step 4: Lock down going forward

**Branch discipline:**
- `main` = production. Only merged from develop after: tests pass + Kieran review + Adam approval + smoke test.
- `develop` = integration. Feature branches merge here.
- `feature/*` = new features. Branch from develop, merge back via PR.
- No more stashes. No more WIP on develop. Everything gets a branch.

**Change record:**
Every merge to develop gets a line in `Docs/Status/CHANGELOG.md`:
```
| Date | Commit | Branch | Description | Reviewer | Smoke test |
```

**New features queue:**
- Adam's next feature (TBD — he mentioned he has one)
- FR-1 (font size scaling — Mel to scope)
- FR-3 (D2 message list diff-guard — Q)
- FIX-002 (sidebar interaction — verify if still relevant)
- FIX-003 (poll sleep diagnostics — verify if still relevant)

## Pre-Baseline Checklist

- [ ] FR-002 code review complete (Kieran)
- [ ] FR-002 blockers fixed (if any)
- [ ] FR-002 smoke test passed (Adam)
- [ ] FR-002 merged to develop
- [ ] All tests pass (98/98, keychain hang excluded)
- [ ] No uncommitted changes on develop
- [ ] Tag v0.9.1 on develop
- [ ] Merge develop → main
- [ ] Tag v0.9.1-release on main
- [ ] Deploy to /Applications/BeeChatApp.app
- [ ] CHANGELOG.md created

## Post-Baseline Rules

1. No more feature work on develop without a feature branch
2. Every feature gets a spec (FR-NNN or FIX-NNN) in `Docs/Specs/Active/`
3. Every feature gets Kieran review before merge
4. Every merge to develop gets a CHANGELOG entry
5. Every merge to main gets Adam's explicit approval
6. No more diversion development — features queue behind the next priority, not alongside it