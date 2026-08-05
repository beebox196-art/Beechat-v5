# BeeChat v5 Status

## Stage
active

**Phase:** Working App - Feature Growth — **Option B single-WebView transcript programme in progress**
**Last Updated:** 2026-08-05
**Latest Commit:** `c84a50f` — v0.9.5g (fix(scroll): self-healing clamp v3, Kieran v2 review fixes)
**Version:** v0.9.5g (VERSION file) — tag `v0.9.5g` == main HEAD `c84a50f`
**Installed builds:** `BeeChatApp.app` = v0.9.5f (old, rollback) · `BeeChatApp-g.app` = v0.9.5g (new, side-by-side, added 2026-08-05)
**Protocol:** v4 (confirmed in `GatewayClient.swift`)

---

## ⭐ WHERE TO FIND EVERYTHING (read this first — single source of truth)

The **canonical Option B programme tracker is the HTML file on the Desktop**, not the repo docs. It holds the gate register, work packages, decisions, and evidence rules in one place and is the authoritative view of what's planned, what's signed off, and what to do next:

- **Tracker:** `/Users/openclaw/Desktop/BEECHAT-BUILD-PROGRESS.html` — WP-0…WP-6, Gate Register (G1–G6 kill gates, B1–B4, T1–T5, P1–P16, R1–R3), Decisions D1–D4, Evidence rules E1–E7. **Always start here.**
- **Route plan (the detailed spec):** `Docs/Specs/Active/single-webview-transcript-plan.md` — Option B phases B-0…B-5, §0.1 = FR-MULTICOPY gated requirement, §12 = decisions taken. (Note: the tracker's footer historically said `...-scope.md`; the real file is `...-plan.md` — corrected 2026-08-05.)
- **Active Specs index:** `Docs/Specs/Active/INDEX.md` — includes `FR-MULTICOPY` (multi-line copy, gated 2026-08-05).
- **Option B review evidence:** `Docs/Reviews/optionb/<GATE-ID>-evidence.md` per E1–E7 rules.
- **Daily log:** `~/.openclaw/workspace/memory/2026-08-05.md` — FR-MULTICOPY + v0.9.5g side-by-side build logged.

**Rule (set by Adam 2026-08-05):** this project is critical and must be managed perfectly. If a fact about Option B direction, gate status, or decisions isn't in the tracker, it does not exist — sync the tracker before and after any significant work. The Desktop HTML is the tracking system of record for this programme.

---

## Current State: WORKING APP ✅ (Option B programme active)

The app connects to the OpenClaw gateway, displays topics in a sidebar, shows messages, sends messages, and displays streaming AI responses. Font scale is adjustable via Settings (⌘,) with keyboard shortcuts ⌘+/⌘-. Research panel (Cmd+Shift+R) routes to Gav. BeeBoard provides pin creation, prioritisation, and archive/restore. Folder favourites give quick Finder access. Tap-to-reconnect provides visual feedback on WebSocket drops.

**Architecture:** Swift app → WebSocket → OpenClaw Gateway (`openclaw-control-ui` client ID, auto-approved from localhost)

---

## Component Status

| # | Component | Status | Tests | Notes |
|---|-----------|--------|-------|-------|
| 1 | BeeChatPersistence | ✅ PASS | 27 | GRDB/SQLite, upsert, cascade delete, Topic model, TopicRepository, BookmarkRepository |
| 2 | BeeChatGateway | ✅ PASS | 48 | WebSocket, resilient handshake, Protocol v4 |
| 3 | BeeChatSyncBridge | ✅ PASS | 37 | Event routing, message persistence, streaming, path validation |
| 4 | BeeChatUI | ✅ WORKING | - | NavigationSplitView sidebar, message bubbles, composer, streaming, research panel |
| 5 | BeeChatApp (Assembly) | ✅ WORKING | 11+3 | FontScale (11), TopicViewModel (3), all passing |
| **Total** | | **✅ 155 PASS** | **155** | Zero failures |

---

## Merged Features (v0.9.0 → v0.9.3)

| Version | Feature | Spec | Tag |
|---------|---------|------|-----|
| v0.9.0 | Baseline stabilisation (topic binding, reset injection, sidebar, poll spin loop) | BASELINE-PLAN | `v0.9.0` |
| v0.9.1 | Tap-to-reconnect with visual feedback + auto-recovery | FR-002 | `v0.9.1-release` |
| v0.9.2 | Research Pipeline (Cmd+Shift+R, 3 depths, /research → Gav) | FR-003 | `v0.9.2-release` |
| v0.9.3 | Font Scale (Settings ⌘, slider, ⌘+/⌘−, sidebar auto-width, Phase 1A+1B sweep) | FR-004 | `v0.9.3-release`, rollback `v0.9.3-pre-font` at `e6fca60` |
| — | Topic Archiving (Active/Archived toggle, right-click Archive/Restore, read-only Archived view, COALESCE NULL guard) | topic-archiving.md | uncommitted |
| - | BeeBoard Archive (pin archive/restore with 3s undo toast) | - | `0582aac` |
| - | Mark as Unread (sidebar indicator) | - | `94164d3` |
| - | Session Key Alignment Fix (UUID vs gateway key) | - | `aeeeb23`, branch `fix/session-key-alignment` |
| - | Topic Delete Confirmation (3 paths behind alert) | FR-004-URGENT-DELETE-CONFIRM | merged to develop |
| - | Folder Favourites (Migration008, FolderPicker, NSOpenPanel) | FOLDER-FAVOURITES-SPEC | merged |
| - | Seed Claude Oversight Folder Bookmark (Migration009) | FEAT-011 | merged |
| - | Click-through File Links (regex detection, Finder launch) | FEAT-010 | merged |
| - | Protocol v4 fix | - | `99e3b69` |
| - | Device family handshake fixes | - | develop |
| - | Orange dot fix | - | `20ad14a` |
| - | Message sort order hotfix | - | `55bb74a` |
| - | AnyCodable iOS compatibility | - | `8edfafa` |

---

## Git Branches

| Branch | Purpose | Status |
|--------|---------|--------|
| `main` | Stable release branch | HEAD `6b20bd8` (v0.9.3 font scale) |
| `develop` | Integration branch | HEAD `9d411a1` (docs: VISION.md + STATUS.md sync) |
| `feature/font-scale` | FR-004 font scale | Merged to main |
| `fix/session-key-alignment` | Session key fix | Merged to main |
| `feature/gate-2f-phase1` | iPhone sync Phase 1 | 9 commits ahead of develop |
| `feature/gate-2f-unified` | Unified Gate 2F work | Superseded by phase1 branch |

---

## Active Specs

| Spec | Status | Priority | Notes |
|------|--------|----------|-------|
| BASELINE-PLAN | Draft pending approval | - | Baseline formalisation, no code changes |
| FOLDER-FAVOURITES-SPEC | ✅ IMPLEMENTED | - | Migration008 + FolderPicker |
| FR-002-TAP-TO-RECONNECT | ✅ MERGED v0.9.1 | - | Kieran PASS WITH CHANGES |
| FR-003-RESEARCH-PIPELINE | ✅ MERGED v0.9.2 | - | Kieran Approve with conditions |
| FR-004-URGENT-DELETE-CONFIRM | ✅ MERGED | P0 | Topic delete 3-path alert gate |
| SESSION-KEY-ALIGNMENT-REFACTOR | v5 FINAL | High | Ready for build |
| TOPIC-ARCHIVING | ✅ IMPLEMENTED | Medium | Active/Archived sidebar toggle, right-click Archive/Restore, read-only Archived view, COALESCE NULL guard |
| FIX-002-sidebar-interaction | Needs verification | P0 | |
| FIX-003-POLL-SLEEP-BEE-DIAGNOSTICS | Needs verification | - | |
| DIAG-001-delete-topic-not-working | P1 | - | |

---

## Known Issues

- **M4 AsyncStream delivery tests** - low-priority gap, not blocking
- **GatewayStatusBar** - shows "No gateway connection" briefly on startup (cosmetic)
- **AnyCodable Sendable warning** - Swift 6 compatibility, not blocking
- **VERSION vs CFBundleShortVersionString mismatch** - VERSION file says `0.9.2`, Info.plist says `0.6.0-reset-inject`. Should be aligned at next release.
- **Mark as Unread** - Kieran review still pending (minor, 3 files)
- **Pre-merge checklist** (develop → main) - all items unchecked: full test suite, Adam smoke test for BeeBoard Archive, Kieran review of full diff since `main@52234f7`, Adam explicit approval

---

## Key Facts

- **GitHub:** https://github.com/beebox196-art/Beechat-v5
- **Local repo:** `/Users/openclaw/Projects/BeeChat-v5/`
- **Token auth:** Classic token with `repo` scope
- **Review process:** Q = builder, Kieran = independent reviewer, Bee = coordinator + verifier
- **All changes merged to `main`**
- **Client ID:** `openclaw-control-ui` (auto-approved from localhost)
- **DB is source of UI truth** - SwiftUI observes GRDB, SyncBridge writes to DB
- **BeeChat Mobile** depends on shared packages via local SPM path dependency (no pinned branch/commit)
- **Installed app:** `/Applications/BeeChatApp.app` (ad-hoc signed arm64)

---

## Dependency Analysis (2026-04-23)

- **No circular dependencies** - clean DAG architecture
- **Design smell:** SyncBridge bypasses `BeeChatPersistenceStore` by accessing `DatabaseManager.shared` directly
- **Duplicated logic:** `isBeeChatSession()` and `normalizeSessionKey()` exist in both SyncBridge.swift and Reconciler.swift
- See `DEPENDENCY_ANALYSIS.md` for full assessment

---

## Documentation Structure

All project documentation is organised under `Docs/`:

| Folder | Purpose |
|--------|----------|
| `Docs/Specs/Active/` | Current specs (in progress or recently completed) |
| `Docs/Specs/Archive/` | 88 superseded/completed specs (kept for reference) |
| `Docs/Reviews/Cycles/<topic>/` | Review cycles grouped by topic |
| `Docs/Reviews/Components/` | Component-level reviews |
| `Docs/Reviews/Final/` | Final implementation reviews |
| `Docs/Diagnosis/` | Diagnosis and evaluation reports |
| `Docs/Implementation/` | Implementation notes and fix specs |
| `Docs/Analysis/` | One-off assessments (dependency, legacy, type, weak types) |
| `Docs/Architecture/` | Architecture specs (Persistence, Gateway, SyncBridge, Cross-Stream Safeguards) |
| `Docs/Design/` | Design system, cross-platform review, Stitch sessions, UI concepts |
| `Docs/Research/` | Research documents (gateway auth, Ed25519, architecture, integration tests, response persistence) |
| `Docs/Status/` | Status and debug files |

---

## Near-Term Priorities

1. **Resolve VERSION/CFBundleShortVersionString mismatch** - align for clean releases
2. **Complete pre-merge checklist** - full test suite, Kieran review, Adam approval for develop → main
3. **Kieran review: Mark as Unread** - 3 files, minor
4. **Kieran review: BeeBoard Archive** - already PASS, needs Adam smoke test confirmation
5. **Gate 2F Phase 1** (iOS sync) - 9 commits on `feature/gate-2f-phase1`, needs merge planning
6. **D2 Message List Diff-Guard** - owned by Q, still on develop

---

*Update this file after each meaningful work session.*