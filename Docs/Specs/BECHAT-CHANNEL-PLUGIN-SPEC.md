# BeeChat v5 — OpenClaw Channel Plugin Specification

**Date:** 2026-04-17
**Status:** Draft for Adam's review
**Pivotal Decision:** BeeChat becomes an in-process OpenClaw channel plugin, following the exact proven approach used by Telegram, Discord, IRC, Slack, and every other working chat integration.

---

## 1. Why This Path

Every working chat channel in OpenClaw runs as an **in-process plugin**. They don't use WebSocket, Ed25519, or any external auth. They load as Node.js modules inside the gateway process and call methods directly.

Our earlier approach — building a standalone Swift app connecting via WebSocket with Ed25519 device identity — was the **external client** path. It's what the web Control UI and mobile companion apps use. It works, but it's complex and fragile for a chat channel.

The plugin path gives us:
- **Zero auth complexity** — we're already inside the process
- **Full gateway access** — session store, agent runtime, event subscriptions, subagent spawning
- **Proven patterns** — every existing channel does this
- **Shared message tool** — OpenClaw core owns the `message` tool, we just provide the adapters

---

## 2. Architecture

```
┌─────────────────────────────────────────────┐
│          OpenClaw Gateway (Node.js)          │
│                                             │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  │
│  │ Telegram  │  │ Discord  │  │  BeeChat  │  │
│  │ plugin   │  │ plugin   │  │  plugin   │  │
│  └──────────┘  └──────────┘  └─────┬─────┘  │
│                                     │        │
│  ┌──────────────────────────────────▼─────┐  │
│  │  Plugin Runtime (PluginRuntime)         │  │
│  │  - agent.session (session store)         │  │
│  │  - subagent (spawn agents)              │  │
│  │  - events (transcript updates)           │  │
│  │  - media (load/detect/resize)            │  │
│  │  - config (load/write)                  │  │
│  └────────────────────────────────────────┘  │
│                                             │
│  ┌────────────────────────────────────────┐  │
│  │  HTTP Routes (registerHttpRoute)        │  │
│  │  GET  /beechat/api/sessions             │  │
│  │  GET  /beechat/api/messages/:sessionKey  │  │
│  │  POST /beechat/api/send                 │  │
│  │  WS   /beechat/ws (real-time events)    │  │
│  └────────────────────────────────────────┘  │
│                                             │
│  ┌────────────────────────────────────────┐  │
│  │  Gateway Methods (registerGatewayMethod)│  │
│  │  beechat.sessions                       │  │
│  │  beechat.messages                       │  │
│  │  beechat.send                           │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────┬──────────────────┘
                           │
                    ┌──────▼──────┐
                    │  macOS app  │
                    │  (Swift UI) │
                    │             │
                    │  Connects   │
                    │  to plugin  │
                    │  HTTP/WS    │
                    └─────────────┘
```

**Key principle:** The Node.js plugin IS BeeChat's backend. The Swift macOS app becomes a **thin frontend** that talks to the plugin's local HTTP API, not to the gateway WebSocket.

---

## 3. Plugin Structure

Following the exact pattern from existing channel plugins:

### 3.1 Package Layout

```
@openclaw/beechat/
├── package.json
├── openclaw.plugin.json
├── src/
│   ├── index.ts                    # Plugin entry (defineChannelPluginEntry)
│   ├── channel-plugin.ts           # ChannelPlugin definition
│   ├── runtime.ts                  # Runtime setup (setBeeChatRuntime)
│   ├── adapters/
│   │   ├── security.ts             # ChannelSecurityAdapter
│   │   ├── outbound.ts             # ChannelOutboundAdapter
│   │   ├── messaging.ts            # ChannelMessagingAdapter
│   │   └── threading.ts            # ChannelThreadingAdapter
│   ├── setup/
│   │   ├── wizard.ts              # Setup wizard
│   │   └── adapter.ts             # Setup adapter
│   ├── http/
│   │   ├── routes.ts              # HTTP API routes (registerHttpRoute)
│   │   └── websocket.ts           # WebSocket endpoint for native app
│   ├── gateway-methods/
│   │   ├── sessions.ts             # beechat.sessions gateway method
│   │   ├── messages.ts             # beechat.messages gateway method
│   │   └── send.ts                 # beechat.send gateway method
│   └── native-app/
│       ├── session-store.ts        # Bridge to plugin runtime session store
│       └── event-bus.ts            # Real-time event stream for native app
```

### 3.2 Manifest (`openclaw.plugin.json`)

```json
{
  "id": "beechat",
  "channels": ["beechat"],
  "configSchema": {
    "type": "object",
    "additionalProperties": false,
    "properties": {}
  }
}
```

### 3.3 Entry Point (`index.ts`)

Following the exact `defineChannelPluginEntry` pattern from the SDK:

```typescript
import { defineChannelPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { beechatPlugin } from "./channel-plugin.js";
import { setBeeChatRuntime } from "./runtime.js";

export default defineChannelPluginEntry({
  id: "beechat",
  name: "BeeChat",
  description: "Native macOS chat client for OpenClaw",
  plugin: beechatPlugin,
  setRuntime: setBeeChatRuntime,
  registerFull(api) {
    // Register HTTP routes for native app communication
    registerBeeChatHttpRoutes(api);
    // Register gateway methods for RPC access
    registerBeeChatGatewayMethods(api);
  },
});
```

### 3.4 Channel Plugin (`channel-plugin.ts`)

Using `createChatChannelPlugin` — the exact helper every chat channel uses:

```typescript
import { createChatChannelPlugin } from "openclaw/plugin-sdk/channel-core";

export const beechatPlugin = createChatChannelPlugin({
  base: {
    id: "beechat",
    meta: {
      id: "beechat",
      label: "BeeChat",
      selectionLabel: "BeeChat",
      docsPath: "/channels/beechat",
      blurb: "Native macOS chat client",
      chatTypes: ["direct", "group", "thread"],
      markdownCapable: true,
    },
    setup: {
      resolveAccount(cfg, accountId) {
        return { accountId: accountId ?? "default", enabled: true };
      },
      listAccountIds(cfg) {
        return ["default"];
      },
    },
    capabilities: {
      chatTypes: ["direct", "group", "thread"],
      polls: false,
      reactions: true,
      edit: true,
      unsend: false,
      reply: true,
      threads: true,
      media: true,
    },
  },
  security: {
    dm: {
      channelKey: "beechat",
      resolvePolicy: () => "open",
    },
  },
  threading: {
    topLevelReplyToMode: "off",
  },
  outbound: {
    attachedResults: {
      channel: "beechat",
      sendText: async (ctx) => {
        // Deliver text to the native app via internal event bus
        return { messageId: await deliverToNativeApp(ctx) };
      },
      sendMedia: async (ctx) => {
        return { messageId: await deliverMediaToNativeApp(ctx) };
      },
    },
  },
});
```

---

## 4. HTTP API for Native App

The plugin exposes local HTTP routes via `registerHttpRoute` — exactly like Slack does for its webhook handler. This is how the Swift macOS app communicates with the plugin.

### 4.1 Routes

```typescript
function registerBeeChatHttpRoutes(api: OpenClawPluginApi) {
  const basePath = "/beechat/api";

  api.registerHttpRoute({
    path: `${basePath}/sessions`,
    auth: "plugin",
    handler: async (req, res) => {
      // List sessions from runtime.agent.session
      const sessions = await listSessions(runtime);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(sessions));
    },
  });

  api.registerHttpRoute({
    path: `${basePath}/messages`,
    auth: "plugin",
    handler: async (req, res) => {
      // Load message history from session store
      const { sessionKey, limit } = parseQuery(req);
      const messages = await loadMessages(runtime, sessionKey, limit);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(messages));
    },
  });

  api.registerHttpRoute({
    path: `${basePath}/send`,
    auth: "plugin",
    method: "POST",
    handler: async (req, res) => {
      // Inject inbound message into OpenClaw's processing pipeline
      const { sessionKey, text } = await parseBody(req);
      await injectInboundMessage(runtime, sessionKey, text);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
    },
  });
}
```

### 4.2 WebSocket for Real-Time Events

The native app needs real-time updates (new messages, agent status). We expose a WebSocket endpoint on the gateway's HTTP server:

```typescript
api.registerHttpRoute({
  path: "/beechat/ws",
  auth: "plugin",
  upgrade: true, // WebSocket upgrade
  handler: async (req, socket) => {
    // Subscribe to runtime events and stream to native app
    const unsubscribe = runtime.events.onSessionTranscriptUpdate((event) => {
      socket.send(JSON.stringify({ type: "transcript_update", ...event }));
    });
    socket.on("close", unsubscribe);
  },
});
```

**Note:** This WebSocket is between the **plugin and the native app**, running on localhost. No Ed25519 auth needed — it's the same machine, auth handled by `auth: "plugin"` (the gateway's internal plugin auth).

---

## 5. Gateway Methods

Using `registerGatewayMethod` — exactly like `memory-wiki` does for `wiki.status`, `wiki.init`, etc.

```typescript
function registerBeeChatGatewayMethods(api: OpenClawPluginApi) {
  api.registerGatewayMethod("beechat.sessions", async ({ params, respond }) => {
    const sessions = await listSessions(runtime);
    respond(true, sessions);
  });

  api.registerGatewayMethod("beechat.messages", async ({ params, respond }) => {
    const messages = await loadMessages(runtime, params.sessionKey, params.limit);
    respond(true, messages);
  });

  api.registerGatewayMethod("beechat.send", async ({ params, respond }) => {
    await injectInboundMessage(runtime, params.sessionKey, params.text);
    respond(true, { ok: true });
  });

  api.registerGatewayMethod("beechat.subscribe", async ({ params, respond }) => {
    // Subscribe to real-time events — returns a subscription id
    const subId = await createEventSubscription(runtime, params);
    respond(true, { subscriptionId: subId });
  });
}
```

---

## 6. Session Store Access

The plugin accesses the session store directly through the runtime:

```typescript
// Reading sessions
const store = runtime.agent.session.loadSessionStore(cfg);
const sessionPath = runtime.agent.session.resolveSessionFilePath(sessionKey);

// Real-time transcript updates
runtime.events.onSessionTranscriptUpdate((event) => {
  // Push to native app via WebSocket or internal queue
});

// Spawning subagents for message processing
const result = await runtime.subagent.run({
  sessionKey: "agent:main:beechat",
  message: inboundText,
  deliver: true,
});
```

---

## 7. Impact on Earlier BeeChat Components

This is the critical section — what changes and what stays.

### 7.1 What Gets Replaced

| Earlier Component | Why It's Replaced | Replacement |
|---|---|---|
| `GatewayClient.swift` (WebSocket connection) | No external WebSocket to gateway | HTTP client calling plugin's `/beechat/api/*` routes |
| `WebSocketTransport.swift` | No gateway WebSocket needed | Native URLSession + HTTP |
| `ConnectParams.swift` | No gateway handshake/connect params | Simple REST API calls |
| `DeviceIdentityManager.swift` (Ed25519) | No device identity signing | Not needed — plugin auth is in-process |
| `TokenStore.swift` (device tokens) | No device token flow | Not needed |
| `RPCClient.swift` (gateway RPC) | No gateway RPC from Swift | HTTP calls to plugin API |
| The entire Ed25519 auth layer | External client auth pattern | Not applicable |

### 7.2 What Stays (Adapted)

| Earlier Component | Adaptation Needed |
|---|---|
| **SwiftUI views** (chat list, message list, composer) | Backend changes from WebSocket to HTTP — UI stays the same |
| **MessageStore** (SQLite/SQLCipher) | Remains the local cache. Syncs from plugin API instead of WebSocket |
| **Models** (Message, Session, etc.) | Same domain types. Map from plugin JSON responses |
| **Design system** (Mel's tokens) | Unchanged |
| **NavigationSplitView layout** | Unchanged |
| **Notification service** | Adapted: push notifications come from plugin events, not WebSocket |
| **Keychain** (for app secrets) | Still used for any native app credentials, just no gateway tokens |

### 7.3 What's New

| New Component | Purpose |
|---|---|
| **BeeChatPlugin** (Node.js) | The in-process OpenClaw channel plugin |
| **HTTPClient** (Swift) | Replaces WebSocket client — calls plugin HTTP routes |
| **EventStream** (Swift) | Replaces WebSocket events — connects to plugin WS endpoint |
| **PluginAPI** (Swift) | Thin typed wrapper for `/beechat/api/*` endpoints |

---

## 8. Implementation Phases

### Phase 1: Plugin Skeleton (2-3 days)
- [ ] Create `@openclaw/beechat` package with `openclaw.plugin.json`
- [ ] Implement `defineChannelPluginEntry` with channel registration
- [ ] Wire up `setRuntime` to capture the `PluginRuntime`
- [ ] Register minimal HTTP routes (`/beechat/api/sessions`, `/beechat/api/messages`)
- [ ] Register gateway methods (`beechat.sessions`, `beechat.messages`)
- [ ] Test: `openclaw plugins install ./beechat && openclaw gateway restart`
- [ ] Verify: `openclaw gateway call beechat.sessions` returns data

### Phase 2: Message Flow (3-4 days)
- [ ] Implement message injection: native app → plugin → OpenClaw processing
- [ ] Implement message delivery: OpenClaw → plugin outbound → native app
- [ ] Wire `runtime.events.onSessionTranscriptUpdate` for real-time updates
- [ ] Implement WebSocket event stream endpoint (`/beechat/ws`)
- [ ] Test full round-trip: send message from native app → agent processes → reply appears

### Phase 3: Swift Frontend Adaptation (3-4 days)
- [ ] Replace `GatewayClient.swift` with `HTTPClient.swift`
- [ ] Replace `WebSocketTransport.swift` with `EventStream.swift`
- [ ] Update `MessageStore` sync logic to pull from plugin API
- [ ] Remove Ed25519/DeviceIdentity code
- [ ] Remove TokenStore (gateway tokens)
- [ ] Update integration tests to hit plugin HTTP endpoints
- [ ] Test: native app connects, sends, receives, all working

### Phase 4: Polish & Features (ongoing)
- [ ] Media support (images, files via plugin media helpers)
- [ ] Reactions (via plugin outbound adapter)
- [ ] Thread support (via channel threading adapter)
- [ ] Push notifications (via plugin event subscriptions)
- [ ] Multi-session support
- [ ] Search (via plugin gateway methods)

---

## 9. Known Working Reference Code

We do NOT invent our own versions. We reference and reuse proven patterns:

| Need | Reference | File |
|---|---|---|
| Channel plugin entry | IRC plugin | `extensions/irc/index.js` — `defineBundledChannelEntry` |
| Channel plugin definition | SDK types | `plugin-sdk/src/plugin-sdk/core.d.ts` — `createChatChannelPlugin` |
| HTTP route registration | Slack plugin | `extensions/slack/runtime-api.js` — `registerSlackPluginHttpRoutes` |
| Gateway method registration | memory-wiki plugin | `extensions/memory-wiki/index.js` — `api.registerGatewayMethod` |
| Plugin runtime access | SDK types | `plugin-sdk/src/plugins/runtime/types-core.d.ts` — `PluginRuntimeCore` |
| Session store access | SDK types | `PluginRuntimeCore.agent.session` |
| Event subscriptions | SDK types | `PluginRuntimeCore.events.onSessionTranscriptUpdate` |
| Subagent spawning | SDK types | `PluginRuntime.subagent.run` |
| Security adapter | SDK types | `channels/plugins/types.adapters.d.ts` — `ChannelSecurityAdapter` |
| Outbound adapter | SDK types | `channels/plugins/types.adapters.d.ts` — `ChannelOutboundAdapter` |
| Threading adapter | SDK types | `channels/plugins/types.core.d.ts` — `ChannelThreadingAdapter` |
| Channel docs | Official docs | https://docs.openclaw.ai/plugins/sdk-channel-plugins |

---

## 10. Key Design Decisions (Immutable)

1. **BeeChat is an in-process plugin** — not an external WebSocket client
2. **The Node.js plugin IS the backend** — Swift app is a thin frontend
3. **Use `createChatChannelPlugin`** — not a custom plugin type
4. **Use `registerHttpRoute`** for native app API — like Slack's webhook handler
5. **Use `registerGatewayMethod`** for RPC — like memory-wiki's methods
6. **Use `PluginRuntime` directly** for session/event access — no reimplementation
7. **No Ed25519, no device identity, no gateway tokens** — all eliminated
8. **Earlier Swift components that conflict with this approach get replaced** — not the other way around

---

## 11. Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `registerHttpRoute` doesn't support WebSocket upgrades | Fallback: long-polling or SSE for events. Or use `registerGatewayMethod` with a subscribe pattern |
| Plugin auth (`auth: "plugin"`) may not be enough for native app | Plugin runs on localhost — can add API key in config if needed |
| Session store format may change across OpenClaw versions | Use `runtime.agent.session` API, not raw file reads |
| Native app HTTP latency vs WebSocket speed | Localhost HTTP is sub-millisecond. WebSocket only needed for events |
| Plugin must be installed separately | Document install steps; eventually publish to ClawHub |

---

## 12. Questions for Adam

1. **Package name:** `@openclaw/beechat` or `beechat-plugin`?
2. **Install location:** `/Users/openclaw/.openclaw/plugins/beechat/` or in the BeeChat-v5 repo?
3. **Do you want to start with Phase 1 (plugin skeleton) immediately?**
4. **Any concerns about the Swift app becoming a "thin frontend"?** It still runs natively, stores data locally, has full SwiftUI — it just talks to localhost HTTP instead of gateway WebSocket.

---

_This spec is the bridge between research and implementation. Every decision here is grounded in proven, working code — not theory._