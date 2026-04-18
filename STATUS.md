# BeeChat v5 Status

**Phase:** Architecture Pivot — Channel Plugin Path  
**Last Updated:** 2026-04-18  
**Pivotal Decision:** BeeChat becomes an in-process OpenClaw channel plugin (Node.js), not an external WebSocket client. Decision made 2026-04-17. Spec committed.

---

## Research-First Gate
- [x] Phase 0 Prior Art Survey complete
- [x] Research report drafted (`Docs/History/PHASE0-RESEARCH-REPORT.md`)
- [x] Research report approved by Adam
- [x] Validated repos added to SHOULDERS-INDEX.md
- [x] Attribution tracker ready

**Research Timebox:** 4 hours (completed in <1 hour)  
**Build Estimate:** 8.5–12 days total  
**Research Report:** `Docs/History/PHASE0-RESEARCH-REPORT.md`

---

## Architecture Decision (2026-04-17)

**Old path:** Swift app → WebSocket → Gateway (external client, Ed25519 auth)  
**New path:** Node.js plugin (in-process) → HTTP API → Swift thin frontend (localhost)

**Why:** Every working chat channel in OpenClaw runs as an in-process plugin. External WebSocket clients need Ed25519 device identity — complex and fragile for a chat channel. In-process plugins get full gateway access with zero auth complexity.

**Spec:** `Docs/Specs/BECHAT-CHANNEL-PLUGIN-SPEC.md`

### What Gets Replaced
| Component | Status | Notes |
|-----------|--------|-------|
| BeeChatGateway (WebSocket, handshake, Ed25519) | 🔄 Obsolete | Replaced by HTTP client to plugin API |
| DeviceCrypto / TokenStore / Keychain | 🔄 Obsolete | No device identity needed in plugin path |
| RPCClient (gateway RPC) | 🔄 Obsolete | Replaced by HTTP calls to `/beechat/api/*` |

### What Stays (Adapted)
| Component | Status | Notes |
|-----------|--------|-------|
| BeeChatPersistence (GRDB/SQLite) | ✅ Keep | Local cache unchanged |
| BeeChatSyncBridge | 🔀 Adapt | Replaces WebSocket event stream with HTTP/WS to plugin |
| Models (Session, Message, Attachment) | ✅ Keep | Map from plugin JSON responses |
| SwiftUI views | ✅ Keep | Backend changes, UI stays same |
| Design system (Mel's tokens) | ✅ Keep | Unchanged |

---

## Build Progress (Original Components)

| # | Component | Status | Tests | Reviews |
|---|-----------|--------|-------|---------|
| 1 | BeeChatPersistence | ✅ PASS | 7+ | 2 (fail→pass) |
| 2 | BeeChatGateway | ✅ PASS (now obsolete) | 26 | 2 (fail→pass) |
| 3 | BeeChatSyncBridge | ✅ PASS | 48 total | 3 (fail→fail→pass) |
| 4 | BeeChatUI | ⬜ Pending architecture adaptation | — | — |
| 5 | BeeChatApp (Assembly) | ⬜ Pending | — | — |
| 🆕 | BeeChat Plugin (Node.js) | ⬜ Not started | — | — |

---

## Component 3 — SyncBridge Review Status

Kieran's final re-review (2026-04-17) verdict: **FAIL** on H4 only.

| Item | Original | Re-Review | Current |
|------|----------|-----------|---------|
| C1: chat.send thinking/attachments | FAIL | ✅ PASS | ✅ Fixed in code |
| C2: session.message event | FAIL | ✅ PASS | ✅ Fixed in code |
| H1: Gap triggers reconcile | WARN | ✅ PASS | ✅ Fixed in code |
| H2: Reconciler shares RPCClient | WARN | ✅ PASS | ✅ Fixed in code |
| H3: stop() cleanup | WARN | ⚠️ PARTIAL | ✅ Fixed (Tasks cancelled + nilled, buffer cleared) |
| H4: DatabaseManager fatalError | WARN | ❌ FAIL | ✅ Fixed (now throws DatabaseManagerError.notOpen) |
| M1: Force unwraps | WARN | ✅ PASS | ✅ Fixed |
| M2: connectionStateStream yield | WARN | ✅ PASS | ✅ Acceptable |
| M3: lastMessageAt mapping | WARN | ✅ PASS | ✅ Fixed |
| M4: AsyncStream tests | WARN | ❌ NOT FIXED | ⬜ Remaining gap |

**All critical/high items now resolved in code.** Only M4 (AsyncStream delivery tests) remains as a low-priority gap.

---

## Active Blockers
None — all review items resolved in code.

## Next Steps (Channel Plugin Path)

### Phase 1: Plugin Skeleton (2-3 days)
- [ ] Create `@openclaw/beechat` package with `openclaw.plugin.json`
- [ ] Implement `defineChannelPluginEntry` with channel registration
- [ ] Wire up `setRuntime` to capture `PluginRuntime`
- [ ] Register minimal HTTP routes (`/beechat/api/sessions`, `/beechat/api/messages`)
- [ ] Register gateway methods (`beechat.sessions`, `beechat.messages`)
- [ ] Test: plugin installs and responds to gateway method calls

### Phase 2: Message Flow (3-4 days)
- [ ] Implement message injection: native app → plugin → OpenClaw processing
- [ ] Implement message delivery: OpenClaw → plugin outbound → native app
- [ ] Wire `runtime.events.onSessionTranscriptUpdate` for real-time updates
- [ ] Implement WebSocket event stream endpoint (`/beechat/ws`)
- [ ] Test full round-trip

### Phase 3: Swift Frontend Adaptation (3-4 days)
- [ ] Replace `GatewayClient` with `HTTPClient` (calls plugin HTTP routes)
- [ ] Replace `WebSocketTransport` with `EventStream` (plugin WS endpoint)
- [ ] Update `SyncBridge` to pull from plugin API
- [ ] Remove Ed25519/DeviceIdentity code
- [ ] Update integration tests

### Phase 4: Polish & Features (ongoing)
- [ ] Media support
- [ ] Reactions
- [ ] Thread support
- [ ] Push notifications

---

## Key Facts
- **GitHub:** https://github.com/beebox196-art/Beechat-v5
- **Local repo:** `/Users/openclaw/Projects/BeeChat-v5/`
- **Token auth:** Classic token with `repo` scope required
- **Review process:** Q = builder, Kieran = independent reviewer, Bee = coordinator + verifier
- **All 3 original components merged to `main`** (no `develop` branch exists)
- **48 tests passing** on `main`
- **Client mode must be `"webchat"`** — gateway validates against strict enum
- **Primary event type:** `agent` (validated against live gateway)
- **DB is source of UI truth** — SwiftUI observes DB, bridge writes to DB

---
*Update this file after each meaningful work session.*