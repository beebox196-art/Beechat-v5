# BeeChat-v5 Status

Updated: 2026-06-19 15:00 GMT+1

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
- [ ] BeeBoard Archive deployed and verified
- [ ] Kieran review of full diff since main@52234f7
- [ ] Adam explicit approval
- [ ] Branching discipline documented and agreed

## Stash Audit (2026-06-16)

Found 1 critical stash: `e1a10b9` — "Bounce+WS WIP stash: BeeBoard archive + minor FIX-004 uncommitted" on fix/connection-stability. Contains 14 files, 444 insertions including the complete BeeBoard Archive feature. **Port in progress.**

Lesson: Stashes are invisible. All work must be committed to branches, even WIP.