# BeeChat v5 — OpenClaw 4.29 Enhancement Spec

**Created:** 2026-04-30  
**Author:** Bee (Coordinator) + Gav (Research)  
**Status:** ✅ REVIEWED — Kieran review complete (2026-04-30) → Ready for Q build  
**Depends on:** OpenClaw upgrade from 2026.4.24 → 2026.4.29  
**Review process:** Kieran = independent reviewer (✅ DONE) → Q = builder → Bee = verifier

---

## Purpose

OpenClaw 2026.4.25–4.29 introduces gateway-level features and new hooks that BeeChat can leverage. This spec breaks them into **independent, pickable options** — each self-contained with its own scope, dependency, and effort estimate. Do the quick ones first, fold the bigger ones into the longer-term plan.

**Design principle:** Never stop improving. Incremental delivery, not big bang.

---

## Option Index

| # | Option | Impact | Effort | Phase | Depends on |
|---|--------|--------|--------|-------|------------|
| A1 | `spawnedBy` agent badge (display only) | MEDIUM | Small | Quick win (revised) | 4.29 upgrade |
| A2 | Visible reply gating | MEDIUM | Small | Quick win ⚠️ | 4.29 upgrade, verify WebSocket filtering |
| A3a | Agent metadata from existing payloads | HIGH | Small | Quick win | 4.29 upgrade, no plugin needed |
| A3b | Response formatting via `before-agent-finalize` | MEDIUM | Medium | Short-term | 4.25+ upgrade, Node plugin |
| A3c | Content moderation via `before-agent-finalize` | LOW | Medium | Future | 4.25+ upgrade |
| A4 | Partial recall on timeout | MEDIUM | Trivial | Quick win (automatic) | 4.29 upgrade |
| B1 | Per-agent TTS config (gateway-only) | MEDIUM | Small | Quick win (revised) | 4.25+ upgrade |
| B1b | Per-agent TTS playback in BeeChat | HIGH | Medium | Voice Phase 2 | 4.25+ upgrade, TTS API verified |
| B2 | TTS persona configuration | MEDIUM | Small | Short-term | 4.25+ upgrade |
| C2 | Agent activity feed (existing events) | MEDIUM | Medium | Short-term (revised) | No OTel needed |
| C1a | Lightweight token counter (no OTel) | MEDIUM | Medium | Medium-term | 4.25+ upgrade |
| C1b | Full OTel dashboard | LOW | X-Large | Future (revised) | 4.25+ upgrade, OTel infra |
| D1 | Commitments & heartbeat reminders | MEDIUM | Medium | Medium-term ⚠️ | 4.29 upgrade, verify WS events |
| D2 | Per-conversation memory filters | LOW | Small | Future (revised) | 4.29 upgrade, config (when needed) |
| E1 | Web Push notifications | LOW | Large | Future | 4.25+ upgrade, PWA infra |

---

## Phase Definitions

- **Quick win:** Zero or minimal code, mostly config/gateway-level, < 1 day
- **Short-term:** New BeeChat code needed, 1–5 days
- **Medium-term:** New UI components or architecture changes, 1–3 weeks
- **Future:** Significant new infrastructure, plan separately

---

## Option Details

### A1: `spawnedBy` Subagent Routing Metadata
**Phase:** Quick win | **Impact:** HIGH | **Effort:** Small

**What it is (4.29):** Subagent chat and agent broadcast payloads now include a `spawnedBy` field, so clients know which parent session spawned a child — without an extra session lookup API call.

**Why it matters for BeeChat:** Our multi-agent setup (Bee → Q/Mel/Kieran/Gav) generates subagent events constantly. Right now BeeChat can't easily tell *which conversation* a subagent message belongs to without making a separate API call. With `spawnedBy`, the sidebar can show subagent threads under the right parent topic, and the message list can tag messages with their originating agent.

**Changes:**
- **GatewayEvent** model: Add optional `spawnedBy: String?` to relevant event types
- **SyncBridge:** Route `spawnedBy` events to correct topic (match parent session key → topic ID)
- **UI:** Show agent badge/label on messages that came from subagents (e.g. "🛠 Q" tag on message bubbles)

**Config needed:** None — gateway sends it automatically after upgrade.

**Test:** Spawn a subagent from BeeChat, verify event payload includes `spawnedBy` and UI renders agent badge.

---

### A2: Visible Reply Gating
**Phase:** Quick win | **Impact:** MEDIUM | **Effort:** Small

**What it is (4.29):** `messages.visibleReplies` forces all visible agent output through the `message(action=send)` path. There's also `messages.groupChat.visibleReplies` for group/channel override.

**Why it matters for BeeChat:** When multiple agents are active, their internal tool calls and planning steps can leak into the chat stream. Visible reply gating ensures only intentional, user-facing messages appear in BeeChat. This is especially useful when Bee delegates to Q or Gav — the user sees Bee's summary, not the raw tool chatter.

**Changes:**
- **Gateway config:** Add `messages.visibleReplies: true` to `openclaw.json`
- **BeeChat UI:** No code change needed — the gateway already filters what goes through the WebSocket. BeeChat just receives fewer noise events.
- **Optional:** If we want BeeChat to *override* this per-topic, add a `visibleReplies` toggle in topic settings.

**Config needed:**
```json
{
  "messages": {
    "visibleReplies": true
  }
}
```

**Test:** Send a multi-step request, verify internal tool messages don't appear in BeeChat message list.

---

### A3: `before-agent-finalize` Plugin Hook
**Phase:** Short-term | **Impact:** HIGH | **Effort:** Medium

**What it is (4.25):** A new plugin hook that fires just before an agent's final response is sent to the user. Plugins can inspect, modify, or augment the response.

**Why it matters for BeeChat:** This is the single most powerful new hook. Potential uses:
- **Response formatting:** Inject structured metadata (agent name, confidence, source citations) into messages before they reach BeeChat
- **Content moderation:** Filter or flag responses before they're shown
- **BeeChat-specific metadata:** Add a custom header/block with response metadata that BeeChat UI can render differently (e.g. research cards, code blocks with syntax hints, action confirmations)

**Changes:**
- **OpenClaw plugin:** Write a simple BeeChat plugin that hooks `before-agent-finalize` and injects structured metadata into a `beeChatMeta` field on the response
- **GatewayEvent model:** Parse `beeChatMeta` from message payloads
- **UI:** Render metadata differently — agent badge, confidence indicator, source links, action buttons

**Config needed:** Plugin registration in `openclaw.json`.

**Test:** Enable plugin, send a request, verify BeeChat renders enriched message cards.

---

### A4: Partial Recall on Timeout
**Phase:** Quick win | **Impact:** MEDIUM | **Effort:** Trivial (automatic)

**What it is (4.29):** When the memory sub-agent times out during context assembly, instead of returning nothing, it returns a bounded partial summary of what it recovered.

**Why it matters for BeeChat:** Long conversations with deep memory can stall on recall. Partial recall means the user gets *something* useful even if memory lookup is slow, rather than a blank or error state.

**Changes:** None — this is a gateway-level behaviour change. BeeChat already handles whatever context the gateway sends.

**BeeChat consideration:** If we want to show a "partial context" indicator in the UI (like a yellow warning that not all memory was loaded), we could parse a partial-recall flag from the gateway response. Low priority.

**Config needed:** None — automatic after upgrade.

---

### B1: Per-Agent TTS Voices
**Phase:** Short-term | **Impact:** HIGH | **Effort:** Medium

**What it is (4.25):** `agents.list[].tts` config lets you set a TTS voice per agent. Combined with `agents.defaults.tts` and per-channel overrides, each agent can have a distinct voice.

**Why it matters for BeeChat:** This directly maps to our **BeeChat Voice Phase 2** roadmap (TTS output, user taps speaker to hear response). With per-agent TTS, Bee speaks in one voice, Q in another, Mel in another. This is personality differentiation that makes the multi-agent experience feel alive.

**Changes:**
- **Gateway config:** Add `tts` blocks per agent in `openclaw.json`:
  ```json
  {
    "agents": {
      "list": [
        { "id": "bee", "tts": { "voice": "nova", "provider": "elevenlabs" } },
        { "id": "q", "tts": { "voice": "echo", "provider": "elevenlabs" } }
      ]
    }
  }
  ```
- **BeeChat UI:** Add speaker button on message bubbles. Tapping it requests TTS audio from the gateway and plays via AVAudioPlayer.
- **BeeChatGateway:** Add TTS request endpoint handling (if gateway exposes one) or use `/tts latest` command.

**Depends on:** ElevenLabs API key or on-device TTS provider configured.

**Test:** Configure Bee with "Nova" voice, tap speaker on a Bee message, hear it spoken. Configure Q differently, verify distinct voice.

---

### B2: TTS Persona Configuration
**Phase:** Short-term | **Impact:** MEDIUM | **Effort:** Small

**What it is (4.25):** TTS personas let you define named voice profiles that can be referenced by agents. Includes provider, voice, speed, pitch settings.

**Why it matters for BeeChat:** Decouples voice config from agent config. Define a "Yorkshire" persona, a "Technical" persona, etc. Swap voices without touching agent definitions.

**Changes:**
- **Gateway config:** Define personas in `openclaw.json`
- **BeeChat UI:** Persona selector in settings — user can override which persona BeeChat uses for playback

**Config needed:**
```json
{
  "tts": {
    "personas": {
      "default": { "provider": "elevenlabs", "voice": "nova" },
      "technical": { "provider": "elevenlabs", "voice": "echo", "speed": 1.1 }
    }
  }
}
```

---

### C1: OpenTelemetry Token/Cost Dashboard
**Phase:** Medium-term | **Impact:** HIGH | **Effort:** Large

**What it is (4.25):** Full OpenTelemetry coverage — model calls, token usage (prompt/completion/cache), tool loops, harness runs, exec processes, outbound delivery, context assembly, memory pressure. All emitted as OTel spans/metrics.

**Why it matters for BeeChat:** This is a genuine differentiator. Show real-time:
- Token usage per conversation, per agent, per model
- Cost tracking (if model pricing is configured)
- Agent activity timeline (which agents are working, how long they take)
- Memory pressure and context window usage
- Tool call frequency and latency

This turns BeeChat from a chat client into an **operations dashboard** for your AI team.

**Changes:**
- **BeeChatGateway:** Add OTel consumer — either scrape Prometheus endpoint or subscribe to gateway OTel HTTP export
- **New BeeChat module:** `BeeChatTelemetry` — parses OTel data, stores aggregates in GRDB
- **New UI component:** Dashboard view — token usage charts, cost breakdown, agent activity timeline, memory pressure gauge
- **Settings:** Configure OTel endpoint, model pricing for cost calculation

**Architecture note:** This could be a separate tab/view in BeeChat's sidebar, not inline with chat. Keep the chat view clean, add a "Dashboard" navigation option.

**Test:** Enable OTel on gateway, open BeeChat dashboard, verify real-time token counts update during conversations.

---

### C2: OpenTelemetry Agent Activity Feed
**Phase:** Medium-term | **Impact:** MEDIUM | **Effort:** Medium

**What it is:** Subset of C1 — just the agent activity timeline, not the full dashboard.

**Why it matters for BeeChat:** Show which agents are currently working, recent completions, and queue depth. Like a lightweight Mission Control inside BeeChat.

**Changes:**
- **BeeChatGateway:** Subscribe to agent lifecycle events (spawn, complete, error)
- **UI:** Small status panel — agent name, status (idle/working/error), last action time
- **No GRDB needed** — ephemeral state, just live UI

**Test:** Spawn a subagent, verify it appears as "working" in BeeChat activity panel.

---

### D1: Commitments & Heartbeat Reminders
**Phase:** Medium-term | **Impact:** MEDIUM | **Effort:** Medium

**What it is (4.29):** Opt-in inferred follow-up commitments. The agent extracts pending tasks from conversations, stores them as commitments, and delivers reminders via heartbeat at the right time. Configurable per-agent and per-channel with `commitments.enabled` and `commitments.maxPerDay`.

**Why it matters for BeeChat:** If Adam says "remind me to check that tomorrow", BeeChat can surface that reminder as a notification or a pinned message. The gateway handles the scheduling — BeeChat just needs to render the commitment events.

**Changes:**
- **Gateway config:** Enable commitments
  ```json
  {
    "commitments": {
      "enabled": true,
      "maxPerDay": 5
    }
  }
  ```
- **GatewayEvent model:** Parse commitment delivery events
- **UI:** Render commitment cards — due time, original context, dismiss/complete action
- **Notifications:** macOS notification on commitment due (via UNUserNotificationCenter)

**Config needed:** Enable in `openclaw.json`. Heartbeat must be configured with reasonable interval.

**Test:** Say "remind me in 5 minutes to review the spec", verify reminder appears in BeeChat at the right time.

---

### D2: Per-Conversation Memory Filters
**Phase:** Medium-term | **Impact:** LOW | **Effort:** Small

**What it is (4.29):** `allowedChatIds` and `deniedChatIds` on Active Memory config, so recall can be scoped to specific conversations.

**Why it matters for BeeChat:** Mostly a config optimisation. If we have high-volume group chats where memory recall is noisy, we can exclude them. Low impact for now since our recall works well.

**Config needed:**
```json
{
  "memory": {
    "activeMemory": {
      "allowedChatIds": ["bee-direct", "bee-command-topic"]
    }
  }
}
```

---

### E1: Web Push Notifications
**Phase:** Future | **Impact:** LOW | **Effort:** Large

**What it is (4.25):** PWA install + Web Push support in the Control UI. Browser-level push notifications for agent events.

**Why it matters for BeeChat:** Low priority for a native macOS app — macOS has UNUserNotificationCenter which is better than Web Push. This is more relevant if BeeChat ever gets a web client. Park for now.

---

## Recommended Implementation Order

### 🔥 Do Immediately (after upgrade, < 1 day each)

1. **A4** ✅ VIABLE — Partial recall (automatic, zero effort)
2. **A2** ✅ VIABLE — Visible reply gating (add one config line) ⚠️ *Must test WebSocket filtering first*
3. **A3a** ✅ VIABLE — Agent metadata from existing payloads (no plugin needed — check what gateway already sends)
4. **A1** ⚠️ REVISED — `spawnedBy` agent badge (display only, not routing — small code change)
5. **B1** ⚠️ REVISED — Per-agent TTS config only (gateway config, no BeeChat playback code yet)
6. **B2** ✅ VIABLE — TTS persona configuration (config-only, unlocks voice work)

### ⚡ Short-Term (next 2 weeks, with BeeChat UI component work)

7. **C2** ⚠️ REVISED — Agent activity feed from existing session events (NOT OTel — simpler, no new dependency)
8. **A3b** ⚠️ REVISED — Response formatting via `before-agent-finalize` plugin (split from original A3)

### 📊 Medium-Term (plan into Component 4 UI roadmap)

9. **C1a** ⚠️ REVISED — Lightweight token counter (prompt/completion counts, no OTel — keep it simple)
10. **D1** ⚠️ REVISED — Commitments & reminders ⚠️ *Must verify commitment events reach WebSocket clients*

### 📋 Future

11. **B1b** — Per-agent TTS playback in BeeChat (Voice Phase 2 — verify gateway TTS API surface first)
12. **C1b** — Full OTel dashboard (significant infra — only if lightweight version proves value)
13. **D2** — Memory filters (config optimisation, do when needed)
14. **A3c** — Content moderation plugin (low priority, use A3a first)
15. **E1** — Web Push (only if web client happens)

---

## Upgrade Prerequisites

Before any of these options work, we need to upgrade OpenClaw:

```bash
npm install -g openclaw@2026.4.29
openclaw gateway restart
```

**Pre-upgrade checklist:**
- [ ] Verify current gateway config is backed up
- [ ] Note any custom model configurations
- [ ] Check cron jobs are recorded (they should persist across upgrade)
- [ ] Verify BeeChat still connects after upgrade (test WebSocket handshake)
- [ ] Run `openclaw status` and `openclaw doctor` post-upgrade

**Rollback:** `npm install -g openclaw@2026.4.24` if anything breaks.

---

---

## Kieran's Independent Review — Summary

**Date:** 2026-04-30 | **Verdict:** 3 options rated VIABLE as-is, 6 NEED REVISION, 2 correctly parked in Future

### Key Changes Made

| Change | Reason |
|--------|--------|
| **A1: Routing → Display only** | Kieran found spec conflated topic routing with agent badges. Routing subagent messages by `spawnedBy` = architectural change. Display metadata = simple. We go display-only for Quick Win. |
| **A3: Split into 3 sub-options** | Original spec bundled formatting, moderation, and metadata into one plugin. Kieran flagged plugin language mismatch (Node.js plugin for SwiftUI app). Split: A3a (existing payloads, no plugin), A3b (plugin for formatting), A3c (moderation, future). |
| **B1: Config vs Playback split** | Kieran flagged underspecified TTS API surface. Gateway may only configure voices, not expose audio endpoint. Split: B1 (config-only, Quick Win) + B1b (playback, Voice Phase 2). |
| **C1: Full OTel dashboard → Future** | Kieran identified scope creep: OTel data volume, missing retention policy, no pricing mechanism, underspecified architecture. Replaced with C1a (lightweight counter, no OTel) + C1b (full dashboard, Future). |
| **C2: Decoupled from OTel** | Kieran found C2 should use existing `sessions.changed` events, NOT OTel. Moved to Short-term as lightweight UI component. |
| **A2: Added verification caveat** | Kieran noted `visibleReplies` may only affect channel plugins, not WebSocket clients. Flagged for post-upgrade testing. |
| **D1: Added verification caveat** | Kieran questioned whether commitment events reach WebSocket clients at all. Flagged for post-upgrade testing. |
| **D2: Demoted to Future** | Low impact, config-only, do when needed. |

### Kieran's Review Verdicts

| Option | Verdict |
|--------|---------|
| A1 (revised: display only) | VIABLE |
| A2 | VIABLE ⚠️ (verify WebSocket filtering) |
| A3a (new: existing payloads) | VIABLE |
| A3b (new: plugin formatting) | VIABLE (Medium) |
| A3c (new: moderation) | VIABLE (Future) |
| A4 | VIABLE ✅ |
| B1 (revised: config only) | VIABLE |
| B1b (new: playback) | VIABLE (Voice Phase 2) |
| B2 | VIABLE ✅ |
| C1a (new: lightweight counter) | VIABLE |
| C1b (new: full OTel) | VIABLE (Future, Effort: X-Large) |
| C2 (revised: existing events) | VIABLE |
| D1 | VIABLE ⚠️ (verify WS delivery) |
| D2 | VIABLE ✅ |
| E1 | VIABLE ✅ (correctly parked) |

---

## File Changes Summary (Revised)

| Option | New Files | Modified Files |
|--------|-----------|----------------|
| A1 | — | `MessageBubbleView.swift` (agent badge) |
| A2 | — | `openclaw.json` (config only) |
| A3a | — | `GatewayEvent.swift` (parse existing metadata) |
| A3b | `BeeChatPlugin.js` (if needed) | `MessageBubbleView.swift` |
| A4 | — | — (automatic) |
| B1 | — | `openclaw.json` (config only) |
| B1b | `TTSPlayer.swift` (Voice Phase 2) | `MessageBubbleView.swift` |
| B2 | — | `openclaw.json` |
| C1a | `TokenCounterView.swift` | `SidebarView.swift` |
| C2 | `AgentActivityPanel.swift` | `SidebarView.swift`, `SyncBridge.swift` |
| D1 | `CommitmentCardView.swift` | `GatewayEvent.swift`, `SyncBridge.swift` |

---

*"Never stop improving." — Adam Box, 2026*