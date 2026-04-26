# FEAT-005: Talk Mode — Voice Conversation in BeeChat

**Date:** 2026-04-26
**Status:** Future Option — Spec for Review
**Author:** Bee
**Reviewer:** Kieran (pending)
**Component:** 5 (BeeChatTalk)
**Priority:** P3 — Post-MVP, depends on Components 1-3

---

## Overview

Talk Mode adds voice conversation to BeeChat, letting Adam speak to Bee and hear responses aloud. This spec covers two implementation paths: a **zero-cost local path** (Phase 1) and an **optional premium path** (Phase 2).

### Why Now

OpenClaw 2026.4.24 adds first-class Talk mode support via the Control UI, including:
- Browser WebRTC realtime voice sessions backed by OpenAI Realtime
- Gateway-minted ephemeral client secrets via `talk.realtime.session`
- `openclaw_agent_consult` tool for deep agent handoff during voice calls
- Local MLX TTS (Soprano) for free, on-device speech synthesis on Apple Silicon
- `talk.speak` RPC for text-to-speech through any configured provider
- `talk.config` / `talk.mode` RPCs for configuration and state broadcasting

All of these gateway RPCs work over the **same WebSocket** we've already built (Component 2: GatewayClient). Talk Mode sits entirely on top of our existing infrastructure.

---

## Architecture

```
┌──────────────────────────────────────┐
│     OpenClaw Gateway (Node.js)       │
│                                      │
│  WebSocket on ws://127.0.0.1:18789   │
│                                      │
│  RPC Methods:                         │
│  - talk.speak       → TTS audio       │
│  - talk.config      → provider config │
│  - talk.mode        → mode state      │
│  - talk.realtime.session → WebRTC    │
│  - chat.send        → message relay   │
│                                      │
│  TTS Providers:                       │
│  - system (macOS AVSpeechSynthesizer)│
│  - mlx (Soprano on Apple Silicon)    │
│  - elevenlabs (paid API)             │
│  - openai (paid Realtime API)        │
└────────────┬─────────────────────────┘
             │ WebSocket (existing)
             │
┌────────────▼─────────────────────────┐
│  BeeChat macOS app (Swift)            │
│                                      │
│  Component 2: GatewayClient           │
│  ┌─────────────────────────────┐     │
│  │ Existing WebSocket + RPC    │     │
│  └────────────┬────────────────┘     │
│               │                      │
│  Component 5: BeeChatTalk            │
│  ┌─────────────────────────────┐     │
│  │ TalkManager                 │     │
│  │  ├── SpeechRecognizer (STT) │     │
│  │  ├── TalkSpeaker (TTS RPC)  │     │
│  │  ├── VAD (silence detect)   │     │
│  │  └── WebRTC client (Phase 2)│     │
│  └─────────────────────────────┘     │
│               │                      │
│  Component 3: SyncBridge             │
│  ┌─────────────────────────────┐     │
│  │ chat.send → main session    │     │
│  │ chat events → response text │     │
│  └─────────────────────────────┘     │
│                                      │
│  SwiftUI Views                       │
│  ┌─────────────────────────────┐     │
│  │ TalkButton (mic toggle)      │     │
│  │ TalkOverlay (state display)  │     │
│  │ VoiceSettings (provider cfg) │     │
│  └─────────────────────────────┘     │
└──────────────────────────────────────┘
```

**No new gateway connection. No plugin. No HTTP routes.** Just new Swift modules using the same WebSocket.

---

## Phase 1: STT → LLM → TTS Loop (Zero Cost)

### Flow

1. User taps mic button → Talk mode activates
2. `SFSpeechRecognizer` captures speech → text transcript
3. Silence timeout (700ms default) → transcript sent via `chat.send` (existing Component 3)
4. Gateway processes through LLM as normal
5. Response text arrives via `chat` events (existing Component 3)
6. BeeChat calls `talk.speak` RPC with response text + voice config
7. Gateway streams PCM audio back → played through `AVAudioEngine`

### TTS Provider Options (Zero Cost)

| Provider | Quality | Latency | Cost | Location |
|----------|---------|---------|------|----------|
| `system` | Basic (robotic) | Very low | Free | On-device (macOS) |
| `mlx` | Good (Soprano 80M) | Low (~200ms) | Free | On-gateway (Mac mini) |

**Recommended default:** `mlx` with Soprano — runs on the Mac mini, sounds decent, zero cost, low latency. The gateway handles model loading; BeeChat just calls `talk.speak` and plays the audio.

### New Swift Files

```
Sources/BeeChatTalk/
├── TalkManager.swift          — Orchestrates listen → think → speak cycle
├── SpeechRecognizer.swift     — Apple SFSpeechRecognizer wrapper (on-device STT)
├── TalkSpeaker.swift          — Calls talk.speak RPC, streams PCM playback
├── VoiceActivityDetector.swift — Energy-based silence detection
├── TalkConfig.swift           — Provider/voice configuration model
└── Views/
    ├── TalkButton.swift        — Mic toggle button in chat composer
    ├── TalkOverlay.swift      — Listening/Thinking/Speaking state overlay
    └── VoiceSettingsView.swift — Provider & voice picker
```

### Key RPCs

| RPC | Direction | Purpose |
|-----|-----------|---------|
| `talk.config` | Client → Gateway | Get available TTS providers, voices, config |
| `talk.speak` | Client → Gateway | Send text, receive audio stream |
| `talk.mode` | Client → Gateway | Toggle talk mode state |
| `chat.send` | Client → Gateway | Send transcript (existing) |
| `chat` events | Gateway → Client | Receive response (existing) |

### Talk Config Structure

```json
{
  "talk": {
    "provider": "mlx",
    "providers": {
      "mlx": {
        "modelId": "mlx-community/Soprano-80M-bf16"
      },
      "system": {},
      "elevenlabs": {
        "apiKey": "...",
        "voiceId": "...",
        "modelId": "eleven_v3"
      }
    },
    "silenceTimeoutMs": 700,
    "interruptOnSpeech": true
  }
}
```

### TalkManager State Machine

```
┌─────────┐  mic tap  ┌───────────┐  silence  ┌──────────┐
│  Idle   │──────────→│ Listening │──────────→│ Thinking │
└─────────┘          └───────────┘           └──────────┘
     ↑                    │                       │
     │                    │ interrupt             │ response
     │                    │ (user speaks)         │ received
     │                    ▼                       ▼
     │              ┌───────────┐           ┌──────────┐
     │              │ Listening │           │ Speaking │
     │              └───────────┘           └──────────┘
     │                                           │
     └───────────────────────────────────────────┘
                  audio complete / user interrupt
```

### Interruption Handling

- **User speaks while assistant speaks:** Stop audio playback immediately, note interruption timestamp, transition to Listening
- **Interrupt on speech** (default: true): If VAD detects speech during playback, abort `talk.speak` stream and return to Listening
- **Voice directives:** Response may prefix with `{"voice":"voice_id","once":true}` — strip before TTS, apply to provider config

### Audio Pipeline

1. Call `talk.speak` with `{text, voice, format: "pcm_44100"}`
2. Gateway streams PCM audio chunks back over WebSocket (binary frames)
3. `AVAudioEngine` plays chunks as they arrive (low-latency streaming)
4. Alternative: `format: "mp3_44100_128"` for compressed delivery (higher latency)

### Permissions

- **Microphone:** `NSMicrophoneUsageDescription` in Info.plist
- **Speech Recognition:** `NSSpeechRecognitionUsageDescription` in Info.plist
- Both required at first Talk mode activation
- macOS will prompt the user automatically

### Estimated Effort

- **TalkManager + state machine:** 2-3 days
- **SpeechRecognizer wrapper:** 1-2 days
- **TalkSpeaker (talk.speak RPC + AVAudioEngine):** 2-3 days
- **VAD:** 1 day (simple energy-based)
- **SwiftUI views (button, overlay, settings):** 2-3 days
- **Testing + polish:** 2-3 days
- **Total:** ~2-3 weeks

---

## Phase 2: WebRTC Realtime Voice (Optional, Paid)

### Overview

For users with an OpenAI API key, BeeChat can establish a **direct WebRTC connection** to OpenAI Realtime for ultra-low-latency voice conversations. The gateway mints an ephemeral client secret — BeeChat never handles OpenAI credentials directly.

### Flow

1. User enables Realtime Talk in settings (requires OpenAI API key configured on gateway)
2. BeeChat calls `talk.realtime.session` RPC → receives ephemeral WebRTC secret
3. BeeChat establishes WebRTC peer connection to OpenAI
4. Direct mic → OpenAI Realtime → speaker pipeline (bypasses gateway for audio)
5. When Realtime model needs deeper tools, it calls `openclaw_agent_consult`
6. Browser/BeeChat relays `openclaw_agent_consult` calls through `chat.send` to the full OpenClaw agent
7. Agent response comes back → relayed to Realtime model → spoken to user

### Additional Swift Files

```
Sources/BeeChatTalk/
├── RealtimeClient.swift      — WebRTC peer connection to OpenAI Realtime
├── RealtimeSession.swift     — talk.realtime.session RPC + secret management
└── AgentConsultRelay.swift   — Relays openclaw_agent_consult via chat.send
```

### Cost

- OpenAI Realtime API: ~$0.06/min input, ~$0.024/min output
- No per-call overhead from gateway (WebRTC is direct)
- `openclaw_agent_consult` uses the normal LLM (cost depends on model)

### Dependencies

- `WebRTC` Swift package (Google's official WebRTC framework)
- OpenAI API key configured in gateway config
- Gateway version ≥ 2026.4.24

### Estimated Effort

- **WebRTC client:** 3-4 days (complex audio pipeline)
- **Realtime session management:** 1-2 days
- **Agent consult relay:** 1-2 days
- **UI for provider switching:** 1 day
- **Testing + polish:** 2-3 days
- **Total:** ~2 weeks additional

---

## Implementation Priorities

| Priority | Item | Depends On | Estimated |
|----------|------|-----------|-----------|
| P3-1 | TalkManager state machine | Component 2 (GatewayClient) | 2-3 days |
| P3-2 | SpeechRecognizer (STT) | None (Apple framework) | 1-2 days |
| P3-3 | TalkSpeaker (talk.speak RPC) | Component 2 + gateway ≥4.23 | 2-3 days |
| P3-4 | VAD + interrupt handling | TalkManager | 1 day |
| P3-5 | SwiftUI views | TalkManager | 2-3 days |
| P3-6 | Testing + polish | All above | 2-3 days |
| P3-7 | WebRTC Realtime (optional) | P3-1 through P3-6 | 2 weeks |

**Phase 1 total: ~2-3 weeks** (can start once Components 1-3 are stable)

---

## Open Questions for Review

1. **MLX provider routing:** Should BeeChat call `talk.speak` with `provider: "mlx"` explicitly, or should it let the gateway's `talk.provider` config decide? Recommendation: use gateway config, so the user can switch providers without an app update.

2. **Audio format:** PCM 44100Hz gives lowest latency but most data over the WebSocket. MP3 44100 128kbps is compressed but adds latency. Recommendation: default to PCM for local connections (Mac mini on same network), offer MP3 as fallback.

3. **Silence timeout:** 700ms is the macOS default. Should this be configurable in BeeChat settings? Recommendation: yes, with a range of 500-2000ms.

4. **Voice assistant personality:** Should Talk mode responses use a different system prompt (shorter, more conversational)? The gateway's Talk mode docs mention "the prompt when sending transcribed voice is slightly tuned to let the model know this is from a voice session." Recommendation: rely on gateway's existing voice prompt tuning; don't add a separate system prompt in BeeChat.

5. **Phase 2 cost acceptance:** Is the OpenAI Realtime cost acceptable? At ~$0.06/min, a 10-minute conversation costs ~$0.60. This is cheap for occasional use but adds up for heavy daily use. Recommendation: make it opt-in with a cost warning in settings.

---

## Gateway Version Requirements

| Feature | Min Gateway Version |
|---------|-------------------|
| `talk.speak` RPC | 2026.4.22+ |
| `talk.config` / `talk.mode` RPCs | 2026.4.22+ |
| MLX Soprano TTS provider | 2026.4.22+ |
| `talk.realtime.session` (WebRTC) | 2026.4.24+ |
| Block streaming dedup fix | 2026.4.23+ |

**Recommended gateway version:** 2026.4.24+ for Talk mode support.

---

## Relationship to Other Specs

- **Component 1 (Persistence):** Talk mode stores voice preferences in GRDB (provider, voice, silence timeout). No new tables needed — use existing `key_value_store` or add a `talk_preferences` table.
- **Component 2 (GatewayClient):** Talk mode uses the existing WebSocket connection and RPC call mechanism. New RPCs (`talk.speak`, `talk.config`, `talk.mode`) are simple additions to `RPCClient`.
- **Component 3 (SyncBridge):** Talk mode sends transcripts via `chat.send` (existing) and receives responses via `chat` events (existing). The `idempotencyKey` dedup system applies to voice transcripts the same as text messages.
- **BeeChat v5 Architecture (SIMPLIFIED-CLAWCHAT-PATH.md):** No architectural changes needed. Talk mode is a new feature module that plugs into the existing client infrastructure.

---

## Naming

**Internal module:** `BeeChatTalk`
**User-facing feature:** "Talk Mode"
**Swift package target:** `BeeChatTalk` (separate from core, imported by app)