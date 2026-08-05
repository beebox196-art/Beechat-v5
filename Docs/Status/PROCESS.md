# BeeChat-v5 Branching & Development Process

Established: 2026-06-16
Authority: Bee (proposed), Adam (approved)

## Why This Exists

On 2026-06-16, we discovered two fully-implemented features (Mark as Unread, BeeBoard Archive) that existed only in stashes or on side branches — never committed to develop, never documented, lost when the baseline changed. This process prevents that from happening again.

## Branching Model

```
main (stable, production)
  ↑ merge only after checklist complete
develop (integration, all work lands here)
  ↑ merge from fix/* and feature/*
fix/* (short-lived, from develop)
feature/* (feature branches, from develop)
```

## Rules

1. **All work goes on a branch from develop.** Never work directly on main.
2. **Commit early, commit often.** WIP commits use `WIP:` prefix. No feature code in stashes.
3. **Stashes are for temporary uncommitted tweaks, not features.** If it took more than 10 minutes to write, it needs a commit.
4. **Every feature gets a commit.** Even if incomplete. Even if it's ugly. Commits are auditable; stashes are invisible.
5. **Merge to develop = integration.** Merge to main = release.
6. **Main is locked.** Only Bee or Adam can merge develop → main.
7. **Delete merged branches.** After merge to develop, delete the source branch. Tag it first if unsure.

## Validation Tiers

| Tier | When | Required |
|---|---|---|
| Trivial | Typo, config, single-line | Build pass → commit |
| Standard | Multi-file, new component | Build + test + Kieran review → commit |
| Critical | Architecture change, external integration | Build + test + Kieran review + Adam approval → commit |

## Deploy Checklist

1. `swift build -c release` succeeds
2. `swift test` all pass (keychain hangs excluded, documented)
3. Commit to develop with descriptive message
4. Kill running app, copy binary to /Applications/BeeChatApp.app
5. Update CFBundleVersion (incrementing letter: 2026.06.16a, b, c...)
6. Ad-hoc sign: `codesign --force --deep --sign - /Applications/BeeChatApp.app`
7. Verify: `codesign --verify /Applications/BeeChatApp.app`
8. Relaunch: `open /Applications/BeeChatApp.app`
9. Update STATUS.md build history table
10. Adam smoke test

## Review Process

1. Q (or author) completes work, commits to develop
2. Kieran reviews diff against last known-good state
3. Findings must be addressed before next deploy
4. Re-review if findings were significant
5. Review doc saved to `Docs/Reviews/`

## ⭐ Development Workflow (Adam-approved 2026-08-05) — the standing process

Adam codified the exact delivery loop that works well. This is the process for all BeeChat work going forward (supersedes loose interpretations):

```
1. Bee writes the spec
2. Kieran + Q validate the spec is sound
3. Once all agreed → dispatch to Q to build
4. Kieran checks the work is done and correct
5. Bee validates before coming back to Adam
6. At a MAJOR piece of work / MILESTONE MOMENT only:
   → Bee creates a detailed review prompt as a .md file
   → Adam copies it manually to Claude/Fable (the external super-checker)
   → Claude/Fable responds: sign-off OR improvements/corrections
```

### Rules (binding)
- **The super-checker is MANUAL.** Bee writes the `.md` prompt; Adam copies it to Claude/Fable. No automation, no invented sub-agents.
- Fable/Claude is invoked at **major milestones only**, not per-task — it's the external final review gate.
- E5 evidence rule still applies within the loop: implementer cannot sign their own gate.
- This process guarantees work is done properly with the minimum of errors, and every gate has a second-party verifier.

### Where this is tracked
- Option B programme tracker: `/Users/openclaw/Desktop/BEECHAT-BUILD-PROGRESS.html` (Evidence tab + footer) — the single source of truth for gate sign-off.
- Evidence files: `Docs/Reviews/optionb/<GATE-ID>-evidence.md` per E1–E7.

## Build Record

Every deploy gets a row in `Docs/Status/STATUS.md` build history table. Fields: build version, date, commit hash, description.

No build without a record. No record without a build.

## Feature Inventory

Maintained in STATUS.md. Every feature that lands on develop gets a line. Status: ✅ done, 🔄 in progress, ❌ not started, ⛔ blocked.

## Stash Audit

Run weekly or before any branch recovery: `git stash list` + inspect. Any feature code in a stash must be committed to a branch immediately or explicitly documented as discarded.