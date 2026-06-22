# BeeChat-v5 Status

Updated: 2026-06-22 13:50 GMT+1

## Current Build

| Field | Value |
|---|---|
| App version | 0.9.0 |
| CFBundleVersion | 2026.06.16f |
| Branch | develop |
| HEAD | 0582aac |
| Deployed to | /Applications/BeeChatApp.app |
| Ad-hoc signed | Yes (arm64) |
| Smoke test | In progress (Adam) |

## Branching Model

- **main** = stable, production-ready. Only merge from develop after Adam approval + smoke test pass.
- **develop** = integration branch. All feature work lands here first.
- **fix/\*** = short-lived fix branches from develop. Merge back to develop via PR or direct merge.
- **feature/\*** = feature branches from develop. Merge back to develop.

**Rule:** Never stash features. Commit to branches. If a feature is WIP, commit with `WIP:` prefix. Stashes are invisible — commits are auditable.

**Merge to main:** Requires: 1) All tests pass, 2) Adam smoke test pass, 3) Kieran review (Standard/Critical tier), 4) Adam explicit approval.

## Deployed Build History

| Build | Date | Commit | Description |
|---|---|---|---|
| 2026.06.16f | Jun 16 22:30 | 0582aac | +BeeBoard Archive layer (pin archive/restore) |
| 2026.06.16e | Jun 16 22:00 | 94164d3 | +Mark as Unread context menu |
| 2026.06.16d | Jun 16 20:55 | 20ad14a | +orange dot fix (Session.totalTokens reset) |
| 2026.06.16 | Jun 16 20:41 | 467d128 | develop recovery build (0.9.0 baseline) |
| 2026.06.16b | Jun 16 19:59 | — | SP001 0.8.1 (protocol v4 fix, superseded) |
| 2026.06.12 | Jun 12 | 52234f7 | main baseline (0.7.8, SP001 parent) |

## Known Issues

| ID | Description | Severity | Status |
|---|---|---|---|
| KI-1 | Streaming bounce on new-message compile (minor, all topics) | Low | Accepted known issue |
| KI-2 | KeychainTokenStoreTests/SyncBridgeTests hang in headless env | Low | Pre-existing, needs MockTokenStore |
| KI-3 | Tap-to-reconnect on offline banner not implemented | Medium | ✅ FIXED — FR-002 built, reviewed, smoke-tested |
| KI-4 | BeeChatLogger not exported from BeeChatSyncBridge | Low | Forces print() in SyncBridge code |

## Feature Inventory (develop @ 94164d3)

- ✅ Protocol v4 handshake (minProtocol/maxProtocol = 4)
- ✅ Edit Topic context menu
- ✅ Reset Session context menu + manualReset totalTokens fix
- ✅ Save Topic Summary context menu (Phase 2)
- ✅ Mark as Unread / Mark as Read context menu
- ✅ Project context continuity
- ✅ Session publishing for iPhone sync (Gate 2F)
- ✅ v4 scroll approach (defaultScrollAnchor + 200ms throttle)
- ✅ Message Equatable (12-field auto-synth)
- ✅ PendingRequestMap Bool return
- ✅ D1 streaming content diff-guard
- ✅ Orange dot clears after manual reset
- ✅ BeeBoard Archive (archive/restore pins, Active/Archived view)
- ❌ D2 message list diff-guard (4-field manual compare still on develop)
- ✅ Tap-to-reconnect on offline banner (FR-002)

## BeeBoard — Current Build State

BeeBoard is a fully integrated feature of BeeChat-v5 (not a separate app). Lives in `Sources/BeeBoard/` as an SPM target within the BeeChat-v5 package. Connected to BeeChat via sidebar button and shared DatabaseManager.

### Capabilities (deployed on develop @ 0582aac)

- **Pin creation:** Create pins with title, content, tags, priority (P1/P2/P3), and colour
- **Pin types:** `note` (standard) and `rich` (structured content)
- **Pin groups:** Organise pins into named groups with colours
- **Pin priorities:** P1 (high/red), P2 (medium/yellow), P3 (low/green)
- **Pin tags:** JSON array of tags per pin (e.g., `["Revenue", "Openclaw"]`)
- **Board view:** Visual pin board with drag-to-position, pin width/height
- **Active/Archived views:** Segmented picker to switch between active pins and archived pins
- **Archive pin:** Right-click → "Archive Pin" moves pin to Archived view. Removes from active board without deleting
- **Restore pin:** Restore from Archived view with optional priority reassignment
- **Undo toast:** 3-second auto-dismiss undo on archive action (cancellable, idempotent)
- **Search:** Text search filters pins by title/content; persists across Active/Archived view switches
- **Migration:** `isArchived` boolean column added idempotently (Migration005, checks column exists before adding)
- **Double-tap to create:** Quick pin creation (active view only; disabled in archive view)

### Archive workflow

1. Right-click a pin → "Archive Pin"
2. Pin moves from Active view to Archived view
3. Undo toast appears (3s) — click to reverse
4. In Archived view: right-click → "Restore Pin" (with optional priority change)
5. Pin returns to Active view

**Purpose:** Archive is for dormant ideas — pins that may come back to life, not deleted. Stale live pins are fine as long-term idea parking. Archive keeps the active board clean without losing ideas.

### Known limitations (Kieran review, non-blocking)

- No tests for archive logic (no BeeBoard tests exist yet — feature is non-trivial)
- No toast for restore operations (inconsistent with archive flow)
- Undo timer not cancelled on `.onDisappear` (small leak, consistent with codebase pattern)
- Mixed group (some archived, some active) renders partial in archive view — edge case, fine for v1
- `matchingPinIds` is dead code (zero readers)

### Kieran review

**Verdict:** PASS (0 MAJOR, 3 MINOR, 8 NITs)
**Review file:** `Docs/Reviews/Cycles/beeboard-archive/KIERAN-REVIEW-BEEBOARD-ARCHIVE.md`

### BeeBoard pins tracked by external tooling

- `pin-extract.sh` script reads pins from BeeChat.sqlite for synthesis/monitoring
- Weekly synthesis BeeBoard Alignment Matrix uses pin-extract.sh output
- 26 pins currently active (10 P1, 9 P2, 6 P3, 1 new)

## Reviews Pending

| What | Reviewer | Status |
|---|---|---|
| BeeBoard Archive (0582aac) | Kieran | ✅ PASS |
| Mark as Unread (94164d3) | Kieran | Pending (minor, 3 files) |

## Feature Requests (Post-Stabilisation)

| ID | Feature | Notes | Owner |
|---|---|---|---|
| FR-1 | Font size scaling | Adjustable font size + proportional sidebar width. High-res display makes text too small. Minimal disruption — scale factor through ThemeManager tokens. | Mel (scope) |
| FR-2 | Tap-to-reconnect | Spec reviewed (Kieran PASS WITH CHANGES). Q building on `feature/FR-002-tap-to-reconnect` branch. 2 files, ~40 lines. | Q |
| FR-3 | D2 message list diff-guard | Replace 4-field manual compare | Q |

## Pre-Merge Checklist (develop → main)

- [ ] All tests pass (98/98, keychain hang excluded)
- [ ] Adam smoke test complete (all SC items)
- [ ] Mark as Unread deployed and verified
- [ ] BeeBoard Archive deployed and verified (feature complete, Kieran PASS — Adam to smoke test on next session)
- [ ] Kieran review of full diff since main@52234f7
- [ ] Adam explicit approval
- [ ] Branching discipline documented and agreed

## Stash Audit (2026-06-16)

Found 1 critical stash: `e1a10b9` — "Bounce+WS WIP stash: BeeBoard archive + minor FIX-004 uncommitted" on fix/connection-stability. Contains 14 files, 444 insertions including the complete BeeBoard Archive feature.

**Resolved:** BeeBoard Archive was recovered from the stash, ported to develop, and committed as 0582aac. Kieran review PASS. Feature is deployed on develop.

Lesson: Stashes are invisible. All work must be committed to branches, even WIP.