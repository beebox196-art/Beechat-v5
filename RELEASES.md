# BeeChat v5 — Release Log

All notable releases are documented here. Newest first.

**Source of truth:** `VERSION` file in repo root.
**App version:** `BeeChatApp.app/Contents/Info.plist` (`CFBundleShortVersionString` + `CFBundleVersion`).
**Release process:** `scripts/release.sh` (run from `develop` branch).

---

## v0.9.2 — 2026-06-20 — FR-003 Research Pipeline

**Features:**
- 🔍 Research Panel in BeeChat (Cmd+Shift+R, sidebar button)
- 3 depth levels: Quick Scan (chat brief) / Standard (HTML) / Deep Dive (HTML)
- `/research` routes to Gav with `research-pipeline` skill context
- Tags, depth selector, multi-line topic field with placeholder

**Pipeline (server-side):**
- Sag scout files checked before web search (saves cost, avoids duplication)
- Dedup against research index + AI digests + KB
- Source provenance: every claim links to its source
- KB conflict detection: flags contradictions with existing KB entries
- Pre-delivery verification gate: HTML + KB + index required before "complete"

**Files:**
- New: `Sources/App/UI/Components/ResearchPanel.swift` (188 lines)
- Modified: `Sources/App/UI/MainWindow.swift` (+17)
- Modified: `Sources/App/UI/ViewModels/ComposerViewModel.swift` (+18, `sendPayload` method)
- New skill: `~/.openclaw/workspace/skills/research-pipeline/` (SKILL.md, template, ingest.py, index)

**Review:** Kieran code review — Approve with conditions. All conditions addressed.

**Tag:** v0.9.2-release, v0.9.2

---

## v0.9.1 — 2026-06-12 — FR-002 Tap-to-Reconnect

**Features:**
- Tap status bar to reconnect when gateway is offline
- Visual feedback during reconnect attempt
- Auto-recovery on successful reconnect

**Tag:** v0.9.1-release, v0.9.1

---

## v0.9.0 — 2026-06-08 — Baseline Stabilisation

**Fixes:**
- Topic binding stability
- Reset injection cleanup
- Sidebar interaction standardisation
- Poll spin loop and ThinkingBee state fixes

**Tags:** v0.9.0, v0.8.0-sp001, v0.8.0-pre-extraction-fix
