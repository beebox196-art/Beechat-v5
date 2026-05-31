# Gate 2F — REST-over-Tailscale Topic Sync

> **Status:** v2 — Updated per Q + Kieran review  
> **Date:** 2026-05-28  
> **Replaces:** Gateway-based topic sync (chat.inject / beechat-sync session approach)

---

## Context

Three attempts at gateway-based topic sync all hit impedance mismatches:

1. **`sessionsPluginPatch`** — gateway rejects "unknown plugin session extension: beechat/metadata" for sessions without the plugin registered
2. **Per-topic `publishTopicState`** — same plugin issue, plus serialisation complexity
3. **`chat.inject` bulk publish** — agent auto-responds to every inject, content format mismatches (`ChatHistoryMessage` can't decode assistant content blocks), session bootstrapping issues

Each "fix" uncovered another problem. The gateway is designed for agent conversations, not application data transport.

The iPhone is already connected to the Mac via Tailscale. A simple HTTP endpoint serving topic data from GRDB bypasses every impedance mismatch.

---

## Architecture

```
iPhone                                          Mac
  │                                              │
  │  GET https://<ts-domain>/topics/v1/topics    │
  │  (URLSession, ATS-compliant HTTPS)           │
  │ ───────────────────────────────────────────► │
  │                                              │  NWListener on localhost:8976
  │                                              │  Proxied via Tailscale Serve
  │                                              │  Reads from GRDB (source of truth)
  │  JSON response                               │
  │  ◄───────────────────────────────────────────│
  │                                              │
  │  WebSocket: sessions.changed                 │  (existing — unchanged)
  │  ◄───────────────────────────────────────────│
  │                                              │
```

**Key principle:** The gateway WebSocket is kept for `sessions.changed` events (real-time "something changed" notification). Topic data comes from a REST endpoint on the Mac, proxied through Tailscale Serve. No more `chat.inject`, no more sync sessions, no more agent auto-responses.

**Why Tailscale Serve instead of direct HTTP:** iOS App Transport Security (ATS) blocks plain `http://` URLs at the `URLSession` level, regardless of Tailscale's transport encryption. Tailscale Serve provides automatic HTTPS with Tailscale's own certificates, making the endpoint ATS-compliant without any Info.plist exceptions. It also means the iPhone uses the same domain as the gateway URL — just a different path.

---

## Specification

### 1. Mac: HTTP Server (NWListener)

**File:** `Sources/BeeChatSyncBridge/TopicServer.swift` (new)

- `NWListener` on `127.0.0.1:8976` (localhost only — Tailscale Serve proxies external access)
- Single endpoint: `GET /v1/topics`
- Returns JSON matching the `TopicListPayload` format (v, timestamp, topics)
- Reads directly from `TopicRepository.fetchAllActive(limit: 50)` on every request — no caching, no debounce, always fresh
- Only includes topics with a `sessionKey` (syncable topics)
- Response headers: `Content-Type: application/json`
- If GRDB read fails, returns `503 Service Unavailable`
- If port 8976 is occupied, log error and continue without the topic server (iPhone falls back to standalone mode — do NOT crash the app)
- GRDB reads happen on a background queue via `DatabaseQueue.read` — the NWListener handler must dispatch to a GRDB-safe queue

**Startup:**
- Start the server when `SyncBridge.start()` is called (after GRDB is ready)
- Log: `[TopicServer] Serving topics at http://127.0.0.1:8976/v1/topics (proxied via Tailscale Serve)`

**Shutdown:**
- Stop the server in `SyncBridge.stop()`

### 2. Mac: Tailscale Serve Configuration

The Tailscale Serve proxy is already configured for the gateway. Add a second route for the topic server:

```bash
tailscale serve --bg https://openclaws-mac-mini-1.tail3f2df8.ts.net/topics/ proxy http://127.0.0.1:8976
```

This means:
- iPhone gateway URL: `https://openclaws-mac-mini-1.tail3f2df8.ts.net/`
- iPhone topic URL: `https://openclaws-mac-mini-1.tail3f2df8.ts.net/topics/v1/topics`
- Same domain, HTTPS, ATS-compliant, no separate IP or port

### 3. Mac: Topic Data Endpoint

**Response format:**
```json
{
  "v": 1,
  "timestamp": "2026-05-28T18:00:00Z",
  "topics": [
    {
      "id": "abc123",
      "name": "Beelinks",
      "sessionKey": "agent:main:abc123",
      "isArchived": false,
      "lastActivityAt": "2026-05-28T17:30:00Z",
      "lastMessagePreview": "Let's build..."
    }
  ]
}
```

**Date encoding:** `JSONEncoder.dateEncodingStrategy = .iso8601` (critical — matches the iPhone's `TopicSyncPayload` decoder)

**Topic cap:** 50 topics max (sanity limit)

### 4. Mac: Trigger Publishing

The server reads from GRDB on every request — no debounce, no queue, no stale data. If a topic was just created and GRDB has it, the next GET returns it.

**Remove** all `publishTopicList()` call sites from:
- `AppRootView.swift` (startup)
- `MainWindow.swift` (topic CRUD: create, edit, delete)
- `SyncBridgeObserver.swift` (sessions.changed)

The server is always-on and always returns current data. No event-driven publishing needed.

### 5. iPhone: Fetch Topic Data

**File:** `BeeChatMobileKit/TopicClient.swift` (new)

- `URLSession` GET to `https://<ts-domain>/topics/v1/topics`
- URL derived from the existing gateway URL in AppSettings:
  - Take the gateway URL (e.g., `https://openclaws-mac-mini-1.tail3f2df8.ts.net`)
  - Append `/topics/v1/topics`
  - No separate IP:port configuration needed
- Timeout: 10 seconds
- Decodes JSON into `TopicSyncPayload` (existing type, reused)
- Returns `TopicSyncPayload?` — nil means no server available (standalone mode)
- Handles network errors gracefully: log and fall back to standalone mode, never crash

**URL derivation logic:**
```swift
// From gateway URL "https://openclaws-mac-mini-1.tail3f2df8.ts.net"
// Topic URL = gatewayURL + "/topics/v1/topics"
// Result: "https://openclaws-mac-mini-1.tail3f2df8.ts.net/topics/v1/topics"
```

### 6. iPhone: Integration Points

**`BeeChatMobileViewModel.swift`:**
- On `connect()` — after establishing gateway WebSocket, call `TopicClient.fetchTopics()` and `reconcileFromPayload()` if data is available
- On `sessions.changed` — re-fetch from the topic server on every event, with a 5-second cooldown to avoid hammering. The iPhone can't distinguish "topic list changed" from "new message in existing topic" from the event alone, so re-fetching is the simplest correct approach. The cost is one HTTP GET to localhost per event, which is negligible.
- Keep `reconcileFromPayload()` — it still works, just the data source changes from gateway session to REST endpoint
- Keep `isReconciling` guard — still needed for race protection
- Remove `readSyncPayload()` — replaced by `TopicClient.fetchTopics()`
- Remove `syncSessionKey` and `lastSyncTimestampKey` constants — no longer needed
- Remove `beechat-sync` filter from `didReceiveSessionChange` — re-fetch on any `sessions.changed`

**`SyncBridge.swift` (shared package):**
- Remove `fetchSyncPayload()` — no longer needed
- See backout spec for full removal list

### 7. What Stays Unchanged

- ✅ Gateway WebSocket for messaging (chat.send, chat.stream, sessions.subscribe)
- ✅ `sessions.changed` events for real-time "something changed" notifications
- ✅ `reconcileFromPayload()` logic on iPhone (still needed, different data source)
- ✅ `TopicRepository` / `BeeChatPersistence` (source of truth, unchanged)
- ✅ `origin` field on topics (used by reconcile logic)
- ✅ `resolveTopicId` / `saveBridge` methods (still needed for topic resolution)
- ✅ Message ordering fix (content-based dedup, `MessageMapper` 10s window + ≥20 char guard)
- ✅ All bounce fixes (scroll behaviour, Composer changes)
- ✅ `ChatHistoryMessage` / `ChatMessagePayload` — needed for chat history, not just sync
- ~~`RPCClient.chatInject`~~ — removed in backout (only caller was `performPublish()`, dead code)
- ✅ `RPCClient.sessionsList()` — still used for session management

### 8. What Gets Removed

See the separate backout spec: `GATE-2F-BACKOUT.md`

### 9. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Tailscale domain changes | Very low | Low — iPhone re-derives URL from gateway URL | Auto-derive from gateway URL |
| Mac app not running | Medium | Low — iPhone falls back to standalone mode | Existing graceful degradation |
| HTTP server port conflict | Low | Low — log error, continue without topic server | Bind to localhost only, fail gracefully |
| GRDB read during write | Low | Low — SQLite WAL mode handles concurrent reads | Dispatch to GRDB-safe queue |
| No push notifications | Low | Low — `sessions.changed` provides real-time signal | Re-fetch on every WS event |
| Tailscale Serve misconfigured | Low | Medium — iPhone can't reach topic server | Verify `tailscale serve status` in setup docs |

---

## Implementation Tasks

### Task A: Backout — Remove gateway-sync code (GATE-2F-BACKOUT)
- Execute backout steps 1–12 from `GATE-2F-BACKOUT.md`
- Both targets compile clean
- No dead code left behind

### Task B: Mac — Create TopicServer.swift
- New file: `Sources/BeeChatSyncBridge/TopicServer.swift`
- NWListener on `127.0.0.1:8976` (localhost only)
- Single `GET /v1/topics` endpoint returning JSON from GRDB
- ISO 8601 dates, 50-topic cap
- Start in `SyncBridge.start()`, stop in `SyncBridge.stop()`
- Graceful failure if port occupied (log + continue)

### Task C: Mac — Configure Tailscale Serve
- Add `/topics` route proxying to `http://127.0.0.1:8976`
- Verify with `curl https://<ts-domain>/topics/v1/topics`

### Task D: iPhone — Create TopicClient.swift
- New file: `BeeChatMobileKit/TopicClient.swift`
- `URLSession` GET to `https://<ts-domain>/topics/v1/topics`
- Derive URL from gateway settings (same domain, append path)
- 10s timeout
- Returns `TopicSyncPayload?`

### Task E: iPhone — Update ViewModel
- Replace `readSyncPayload()` with `TopicClient.fetchTopics()`
- Keep `reconcileFromPayload()` and `isReconciling`
- Replace `beechat-sync` filter with re-fetch on any `sessions.changed` (with 5s cooldown)
- Remove `syncSessionKey`, `lastSyncTimestampKey`, `beechat_lastSyncTimestamp` UserDefaults cleanup

### Task F: iPhone — Refactor TopicSyncPayload.swift
- Keep `TopicSyncPayload` and `TopicPayloadItem` type definitions (needed by `reconcileFromPayload()`)
- Remove `extract(from:)` method and `maxPayloadSize` guard (gateway-parsing logic, no longer needed)
- Rename file to `TopicTypes.swift` for clarity

### Task G: Build verification
- Both targets compile clean
- Mac: TopicServer starts and serves topics on `127.0.0.1:8976`
- iPhone: Can connect via Tailscale Serve and fetch topics
- End-to-end: Mac topics appear on iPhone

### Task H: Kieran review
- Review all changes before committing