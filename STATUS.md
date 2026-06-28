# BeeChat v5 Status

## Stage
active

**Phase:** Working App — Direct WebSocket Path  
**Last Updated:** 2026-04-23  
**Latest Commit:** `696b33a` — feat: BeeChat v5 working chat interface — topics, messages, gateway connection

---

## Current State: WORKING APP ✅

The app connects to the OpenClaw gateway, displays topics in a sidebar, shows messages, sends messages, and displays streaming AI responses.

**Architecture:** Swift app → WebSocket → OpenClaw Gateway (using `openclaw-control-ui` client ID, auto-approved from localhost). NOT the channel plugin path — we reverted from that pivot.

---

## Component Status

| # | Component | Status | Tests | Notes |
|---|-----------|--------|-------|-------|
| 1 | BeeChatPersistence | ✅ PASS | 7+ | GRDB/SQLite, upsert, cascade delete, Topic model, TopicRepository |
| 2 | BeeChatGateway | ✅ PASS | 26 | WebSocket, resilient handshake, `openclaw-control-ui` client ID |
| 3 | BeeChatSyncBridge | ✅ PASS | 48 | Event routing, message persistence, streaming |
| 4 | BeeChatUI | ✅ WORKING | — | NavigationSplitView sidebar, message bubbles, composer, streaming indicator, gateway status bar |
| 5 | BeeChatApp (Assembly) | ✅ WORKING | — | All wired together, running on macOS |

---

## Build Sprint (Apr 18-22)

### Apr 18-19: Crash Fixes & Refactoring
- HOTFIX-001: GRDB ValueObservation MainActor crash
- HOTFIX-002: syncBridge force-unwrap crash
- FIX-001: Delete topic context menu (gesture conflict)
- FIX-002: Sidebar bottom bar, onKeyPress delete, new topic sheet
- REFACTOR-001: Replace TopicBar with NavigationSplitView sidebar (5 steps)
- Kieran review corrections: auto-sizing composer, gateway lifecycle, unified read paths

### Apr 19-20: Composer & Layout
- Replace MacTextView NSViewRepresentable with native SwiftUI TextField
- Fix greedy GeometryReader, cache intrinsicContentSize
- Unify sidebar/message area backgrounds
- Remove WindowBackgroundFix that broke NavigationSplitView layout

### Apr 20-21: Wiring & Streaming
- Wire observers to UI — sidebar topics, message list, composer send
- Streaming indicator — typing indicator and partial responses during AI generation
- Gateway config parsing — handle `mode:local`, add host/port defaults
- Gateway connection waits for handshake before returning
- Resilient handshake — decode HelloOk from rawData, handle empty auth, server.id→connId

### Apr 22: Full Working Chat
- Fix session key normalisation — map gateway keys to topic IDs
- Fix cross-session contamination — filter events for BeeChat topics only
- Fix response persistence — fetch history before notifying streaming ended
- Fix assistant bubble visibility — bgPanel for contrast
- Fix bubble sizing — dynamic width 66%, user right-aligned
- Topic model + TopicRepository for proper topic→session mapping
- Sidebar reads from topics table only
- Clean up debug contamination
- **Commit `696b33a` pushed to GitHub**

---

## Key Learnings

- Q's output truncates — always verify build before sending to Kieran
- Security framework Ed25519 limited — use EC P-256 with `ecdsaSignatureMessageX962SHA256`
- Keychain hangs in unsigned dev builds — file-based fallback with 5s timeout
- Never trust agent claims without verifying artifacts exist
- `openclaw-control-ui` client ID auto-approved from localhost (no device identity needed)
- DB is source of UI truth — SwiftUI observes GRDB, SyncBridge writes to DB
- Gateway validates client ID against strict enum
- Session key normalisation needed: gateway keys → topic IDs

---

## Architecture Decision

**Chosen path:** Direct WebSocket connection (Swift app → Gateway)  
**Rejected path:** Node.js channel plugin (in-process) — too complex for a chat client, auth overhead unnecessary with localhost client ID

**What stays from plugin idea:**
- HTTP API patterns (future: local plugin for advanced features)
- Thin frontend principle (SwiftUI observes DB, bridge writes to DB)

---

## Next Steps

### Polish
- [ ] UI polish — colours, spacing, dark mode
- [ ] Window chrome (titlebar, traffic lights)
- [ ] Keyboard shortcuts (Cmd+N new topic, Cmd+Delete remove)

### Features
- [ ] Media/attachment support
- [ ] Reactions
- [ ] Thread support
- [ ] Push notifications

### Platform
- [ ] iOS adaptation (Core packages are platform-agnostic, 90%+ reuse expected)

---

## Dependency Analysis (2026-04-23)
- **No circular dependencies** — clean DAG architecture
- **Design smell:** SyncBridge bypasses `BeeChatPersistenceStore` by accessing `DatabaseManager.shared` directly
- **Duplicated logic:** `isBeeChatSession()` and `normalizeSessionKey()` exist in both SyncBridge.swift and Reconciler.swift
- See `DEPENDENCY_ANALYSIS.md` for full assessment

## Documentation Structure

All project documentation is organised under `Docs/`:

| Folder | Purpose |
|--------|----------|
| `Docs/Specs/Active/` | Current specs (in progress or recently completed) |
| `Docs/Specs/Archive/` | Superseded/completed specs (kept for reference) |
| `Docs/Reviews/Cycles/<topic>/` | Review cycles grouped by topic |
| `Docs/Reviews/Components/` | Component-level reviews |
| `Docs/Reviews/Final/` | Final implementation reviews (A/B/C/D) |
| `Docs/Reviews/Adversarial/` | Adversarial and audit reviews |
| `Docs/Reviews/Consensus/` | Consensus documents |
| `Docs/Diagnosis/` | Diagnosis and evaluation reports |
| `Docs/Implementation/` | Implementation notes and fix specs |
| `Docs/Analysis/` | One-off assessments |
| `Docs/Architecture/` | Architecture specs |
| `Docs/Design/` | Design system and sessions |
| `Docs/Research/` | Research documents |
| `Docs/History/` | Historical records |
| `Docs/Status/` | Status and debug files |

See `Docs/Specs/Archive/README.md` for archive index and `Docs/Reviews/INDEX.md` for review index.

## Known Issues
- **BUG: Session reset uses wrong key for Telegram topics (2026-06-22)** — See `Docs/Bugs/session-reset-general-topic.md`. Local SQLite `topics` table stores UUID-format keys (`agent:main:491ea8d6...`) while the gateway uses canonical Telegram keys (`agent:main:telegram:group:-...:topic:N`). Manual reset passes the UUID key, resetting the wrong session. All 14 locally-created topics are affected. **FIX IN PROGRESS on branch `fix/session-key-alignment`** — Q implementation + Kieran review + Bee C1/C2/H1/H2 fixes. Commit `aeeeb23`. Binary built and installed to /Applications/BeeChatApp.app (0.9.3-dev, 2026.06.22). Awaiting Adam's live test.
- M4 AsyncStream delivery tests remain as low-priority gap
- GatewayStatusBar shows "No gateway connection" briefly on startup (cosmetic)
- `AnyCodable` Sendable warning (Swift 6 compatibility issue)

## Key Facts
- **GitHub:** https://github.com/beebox196-art/Beechat-v5
- **Local repo:** `/Users/openclaw/Projects/BeeChat-v5/`
- **Token auth:** Classic token with `repo` scope required
- **Review process:** Q = builder, Kieran = independent reviewer, Bee = coordinator + verifier
- **All components merged to `main`**
- **Client ID:** `openclaw-control-ui` (auto-approved from localhost)
- **DB is source of UI truth** — SwiftUI observes DB, SyncBridge writes to DB

---
*Update this file after each meaningful work session.*