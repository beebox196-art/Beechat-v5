# BeeChat Baseline Plan

**Date:** 2026-05-24 17:12 GMT+1
**Author:** Q (validated by subagent run)
**Status:** Draft — pending Adam approval

---

## 1. Current Working Baseline

| Item | Value |
|---|---|
| **Branch** | `develop` |
| **HEAD commit** | `55bb74a` — hotfix: correct message sort order (Bug 2) |
| **Full SHA** | `55bb74a094de5d9cc5ae5646512a2aed94e311d2` |
| **Protocol version** | v4 (confirmed in `GatewayClient.swift`) |
| **Build status** | ✅ `swift build` passes cleanly (4.85s) |
| **Platforms** | macOS 14+ / iOS 17+ |

The protocol v4 fix (`99e3b69`, May 15) is present on `develop` as expected.

### Build Verification

`swift build` from `develop` completes with **zero errors**. Only pre-existing warnings (unused `try` expressions, Sendable conformance, unused `write` results) — no new regressions.

---

## 2. Branch Comparison

### `develop` (baseline — 5+ commits behind unified)
- ✅ Protocol v4 fix (`99e3b69`)
- ✅ deviceFamily handshake fixes
- ✅ Gate 2B.5 data layer + TopicRepository
- ✅ AnyCodable iOS compatibility fix (`8edfafa`)
- ✅ Message sort order hotfix (`55bb74a`)
- **This is the working Mac baseline.**

### `main` (outdated — DO NOT USE as source of truth)
- Protocol v3 (broken — handshake fails)
- 3 commits behind develop
- Last: `52234f7` — Gate 2F Phase 0
- **Action needed:** `main` needs to be updated from `develop` once baseline is formalised.

### `feature/gate-2f-unified` (9 commits ahead of develop)
- Includes all of `develop` plus:
  - Topic-project binding (Steps 1–8)
  - Project directory scanner + scaffolder
  - EditTopicSheet UI
  - Context menu trigger + sheet wiring
  - SyncBridge context injection + session summary
  - Fixes: infinite spinner, double-write on save, re-inject on binding change, "Could not load topic" error
- Also contains protocol v4 fix (inherited from develop)
- **Status:** 9 unmerged commits ahead. Mac-only features in `Sources/App/` plus small shared additions (Topic model extension, TopicRepository).

---

## 3. BeeChat-Mobile Dependency

BeeChat-Mobile (`/Users/openclaw/Projects/BeeChat-Mobile/BeeChatMobile/Package.swift`) references BeeChat-v5 via:

```swift
.package(path: "../../BeeChat-v5"),
```

This is an **SPM path dependency** — it resolves to whatever the local filesystem copy of BeeChat-v5 has checked out. There is **no pinned branch, commit, or version**. The mobile build uses whatever branch is currently checked out in the BeeChat-v5 repo on disk.

**Imports:** BeeChatPersistence, BeeChatGateway, BeeChatSyncBridge (the 3 shared packages)
**Does NOT import:** Sources/App (Mac-only)
**Platforms:** iOS 17+ only

**⚠️ Risk:** If someone checks out a broken branch in BeeChat-v5 on the shared machine, the iOS build will silently use it.

---

## 4. Recommended Merge/Tag Strategy

### Phase 1: Formalise `develop` as Baseline (No code changes)
1. ✅ This document — validate that `develop` builds and is the source of truth.
2. Tag the current HEAD: `git tag v4.0.0-develop-baseline 55bb74a` (pending Adam approval).
3. Update `main` to match `develop` once tagged (or retire `main` as a release-only branch).

### Phase 2: Merge `feature/gate-2f-unified` → `develop`
1. **Dual-build validation** (per CROSS-STREAM-SAFEGUARDS.md Rule 2):
   - `swift build` in BeeChat-v5 from unified branch ✅
   - `swift build` in BeeChat-Mobile from unified branch (needs verification)
2. Kieran adversarial review focused on shared package changes
3. Merge to `develop`
4. Tag as `v4.1.0-topic-binding` (or appropriate semver)

### Phase 3: Align `main`
1. Fast-forward or merge `develop` → `main`
2. Tag `v4.0.0` on `main` (first formal release tag)

---

## 5. Risks and Dependencies

| Risk | Severity | Mitigation |
|---|---|---|
| **SPM path dependency has no pinning** | Medium | Consider switching to `.package(url:..., branch: "develop")` or a version tag once baseline is tagged |
| **`main` diverged from `develop`** | Medium | Update `main` once develop is tagged; prevent direct commits to `main` |
| **Shared package changes in unified not validated on iOS** | High | Must build BeeChat-Mobile against unified before merge |
| **Protocol version hardcoded assumptions** | Low | v4 is confirmed in GatewayClient.swift; verify Mobile doesn't assume v3 |
| **Pre-existing compiler warnings** | Low | 13+ warnings (Sendable, unused try, unused write results) — clean up separately, not blocking |

---

## 6. Actions for Adam

1. ✅ Confirm `develop` is accepted as the Mac baseline
2. Approve tagging `develop` HEAD as `v4.0.0-develop-baseline`
3. Decide: merge `feature/gate-2f-unified` into `develop` now, or hold for separate review cycle
4. Decide: update `main` to match `develop`, or keep `main` as release-only going forward
5. Consider pinning the BeeChat-Mobile SPM dependency to a branch or tag instead of path

---

*Next review: after Adam approves direction.*
