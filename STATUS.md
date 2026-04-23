# BeeChat v5 Status

## Stage
active

**Phase:** Working App — Direct WebSocket Path  
**Last Updated:** 2026-04-22  
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

## Known Issues
- M4 AsyncStream delivery tests remain as low-priority gap
- GatewayStatusBar shows "No gateway connection" briefly on startup (cosmetic)

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