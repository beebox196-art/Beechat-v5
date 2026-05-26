# FEAT-005: Talk Mode — Technical Review

**Date:** 2026-04-26
**Reviewer:** Bee (Kieran unavailable — models timed out across 6 attempts)
**Spec:** FEAT-005-TALK-MODE.md
**Status:** ✅ Approved with 7 Conditions

---

## Executive Summary

The spec is architecturally sound. Phase 1 correctly leverages existing Components 1-3, the zero-cost path via SFSpeechRecognizer + `talk.speak` + MLX Soprano is well-reasoned, and no new gateway connections or plugins are needed. I found no fundamental design flaws.

**However**, there are 7 conditions that must be addressed before implementation — the most critical being binary frame handling in GatewayClient and the missing error/reconnection states.

---

## 1. Architecture Correctness

### State Machine — Missing 3 States ⚠️

The proposed 4-state machine (Idle → Listening → Thinking → Speaking) is correct for the happy path but omits three essential states:

| Missing State | Why It's Needed |
|---------------|-----------------|
| **Connecting** | Talk mode activation may require confirming providers via `talk.config` before listening can begin. Also needed after WebSocket reconnection. |
| **Error** | Speech recognition failure, gateway timeout, TTS provider unavailable, permission denied — all need a terminal state with recovery. |
| **Paused** | User takes a phone call, switches apps, or explicitly pauses. Different from Idle (can resume without re-requesting permissions). |

**Condition 1:** Add Connecting, Error, and Paused states to the TalkManager state machine before implementation.

### Audio Pipeline — Binary Frame Gap ⚠️

The spec correctly identifies `talk.speak` + `AVAudioEngine` as the playback mechanism, but misses a critical integration point: **`talk.speak` returns audio as WebSocket binary frames, not JSON text frames.** GatewayClient currently only handles JSON text frames (see `handleMessage(_ text: String)` in `GatewayClient.swift`).

This is the single biggest technical gap. Before Phase 1 can work, Component 2 needs:

```swift
// New protocol on GatewayClient
public protocol BinaryFrameHandler: Sendable {
    func handleBinaryFrame(_ data: Data) async
}

// New method on GatewayClient
public func setBinaryFrameHandler(for method: String, handler: BinaryFrameHandler?)
```

This allows `TalkSpeaker` to register as the binary frame handler for `talk.speak` responses without changing the core frame parsing logic.

**Condition 2:** Extend GatewayClient to handle WebSocket binary frames before starting Talk mode implementation. This affects Component 2.

### TalkManager as Swift Actor ✅

Correct choice. TalkManager should be an `actor` to prevent state corruption across concurrent listen/speak/interrupt cycles.

---

## 2. Missing Pieces

### Error Handling — Critical Gap ❌

The spec mentions "Error" nowhere. Real failures to handle:

| Error | Impact | Recovery |
|-------|--------|----------|
| Microphone permission denied | Can't start Listening | Show permission prompt → Idle |
| Speech recognition fails (no audio, low confidence) | No transcript | Return to Listening with timeout |
| `chat.send` fails (network, gateway down) | No response | Retry with backoff; show error overlay |
| `talk.speak` times out or returns error | No audio playback | Fall back to text-only response in chat |
| Gateway WebSocket disconnects mid-Talk | All RPCs fail | Auto-reconnect and restore Talk state |
| TTS provider not configured (MLX not loaded) | `talk.speak` returns error | Show config error; fall back to `system` provider |

**Condition 3:** Add an explicit Error state and per-error recovery strategy before implementation.

### Reconnection During Talk Mode — Critical Gap ❌

If the WebSocket disconnects while Talk mode is active (Listening or Speaking state), the UI would show "Listening" but all RPCs are dead.

**Recovery strategy:**
1. GatewayClient detects disconnect, preserves `talkModeWasActive = true`
2. On reconnect, `TalkManager` re-requests `talk.config` to confirm providers
3. If providers available → return to Listening (auto-resume)
4. If providers unavailable → show error overlay → Idle
5. **Never** resend the last transcript (prevents duplicate processing)

**Condition 4:** Add WebSocket reconnection handling for Talk mode before implementation.

### VAD Accuracy — Placeholder ⚠️

Simple energy-based VAD (volume threshold) will produce false positives (keyboard clicks, background noise) and false negatives (quiet speech). The 700ms silence timeout is a reasonable starting point but needs tuning.

**Recommendation:** Use `AVAudioSession` audio level metering combined with `SFSpeechAudioBufferRecognitionRequest.shouldReportPartialResults`. If partial results show no new words for 700ms, assume user has finished speaking. This is more robust than pure energy detection.

**Condition 5:** Document the VAD approach in more detail. Energy-based VAD is a placeholder that will need tuning for Yorkshire accents specifically.

---

## 3. Swift/macOS Specifics

### SFSpeechRecognizer Gotchas

1. **Requires network on macOS:** `SFSpeechRecognizer` uses Apple's servers for recognition. It is **not** offline on macOS. The spec says "free" but it requires internet. This is fine for a gateway-connected app, but should be documented.

2. **Accent sensitivity:** Works well for standard English but struggles with strong regional accents. Adam's Yorkshire accent may produce lower accuracy. Consider a custom vocabulary file or confidence threshold tuning.

3. **Single-use task lifecycle:** Each `SFSpeechRecognitionTask` must be cancelled and recreated after a response cycle. Cannot reuse across turns.

4. **No simulator support:** Speech recognition requires real hardware. For BeeChat (macOS native) this is fine, but note for any future iOS port.

**Condition 6:** Document SFSpeechRecognizer limitations (network requirement, accent sensitivity, single-use tasks) in the implementation notes.

### AVAudioEngine Streaming

`talk.speak` returns PCM audio as WebSocket binary frames. Playing via `AVAudioEngine` requires:
1. Creating an `AVAudioPCMBuffer` for each chunk
2. Scheduling buffers on an `AVAudioPlayerNode`
3. Handling buffer underrun (gateway sends slower than playback)

`AVAudioEngine` runs on a separate audio thread. All buffer scheduling must be thread-safe.

### Permissions Flow

The spec lists `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`. **Recommendation:** Request microphone first, then speech recognition after mic is granted. Requesting both simultaneously creates a confusing combined dialog. If either is denied, show a helpful message explaining how to re-enable in System Settings.

### MLX Soprano on Mac mini

The spec correctly identifies MLX Soprano as the zero-cost TTS provider. Works if:
- Gateway has `talk.provider: "mlx"` configured
- MLX TTS helper binary is on PATH
- Soprano model is downloaded (first use pulls ~150MB)

No BeeChat-side changes needed — gateway handles everything.

---

## 4. Gateway RPC Correctness

### talk.speak RPC ✅

```json
{
  "method": "talk.speak",
  "params": {
    "text": "Hello, how can I help?",
    "voice": "default",
    "format": "pcm_44100"
  }
}
```

Correct. Response is a stream of binary frames (not JSON). This is the critical integration point — see Condition 2.

### talk.config RPC ✅

```json
{ "method": "talk.config", "params": {} }
```

Returns provider config. Use on Talk mode start to confirm providers are available.

### talk.mode RPC ✅

```json
{ "method": "talk.mode", "params": { "enabled": true } }
```

Broadcasts Talk state to Control UI. Optional for BeeChat but useful for consistency.

### talk.realtime.session (Phase 2) ✅

Gateway mints ephemeral WebRTC secret. BeeChat never handles OpenAI credentials directly. Correct.

### RPCs Correctly NOT Called ✅

The spec correctly avoids `tts.convert` (one-shot TTS), `tts.enable/disable` (preferences, not Talk mode), and only uses `chat.send` for transcript relay.

### Audio Format Negotiation ⚠️

The spec assumes `pcm_44100`. The gateway may return `pcm_24000` or `mp3_44100_128` depending on provider config. BeeChat should either:
- Negotiate the format in the `talk.speak` call, or
- Auto-detect format from the binary frame metadata

**Recommendation:** Default to `pcm_44100` (lowest latency for local connections), fall back to `mp3_44100_128` if the gateway reports PCM unsupported.

---

## 5. Security Concerns

### Microphone Access — Low Risk ✅

Gated by macOS permissions. App cannot capture audio without explicit user consent.

### Speech Recognition Data — Low Risk ✅

SFSpeechRecognizer sends audio to Apple's servers. Standard macOS behaviour, Apple's privacy policy applies.

### WebSocket Binary Frames — Low Risk ⚠️

Binary frames arrive on the same WebSocket as JSON RPC. GatewayClient should:
- Validate binary frames only arrive after a `talk.speak` call (reject unexpected binary data)
- Cap buffer size to prevent memory exhaustion
- Discard audio data after playback completes

**Condition 7:** Add binary frame validation and size limits to GatewayClient.

### WebRTC Secret (Phase 2) — Medium Risk ✅

Ephemeral, gateway-minted, short-lived. Spec correctly says BeeChat should never persist it to disk, discard on session end, re-mint on each session. No issues.

---

## 6. Feasibility Assessment

### Phase 1: 2-3 Weeks → Revised to 3-4 Weeks ⚠️

The original estimate is realistic **if** GatewayClient already handles binary frames. Since it doesn't, add 1 week for the refactor:

| Week | Work |
|------|------|
| Week 1 | TalkManager actor, state machine (with Error/Connecting/Paused), SFSpeechRecognizer wrapper, permission flow |
| Week 2 | GatewayClient binary frame support, TalkSpeaker, AVAudioEngine streaming playback |
| Week 3 | VAD, SwiftUI views (button, overlay, settings), integration testing |
| Week 4 (buffer) | Polish, accent tuning, edge cases |

### Phase 2: 2 Weeks → Revised to 3-4 Weeks ❌

WebRTC integration on macOS is complex:
- SDP negotiation handling
- ICE candidate management
- Audio track capture/playback
- Reconnection logic for dropped sessions

**Corrected total estimate:** 6-8 weeks for both phases.

---

## 7. Recommendations

### Must Fix Before Implementation

1. Add Connecting, Error, and Paused states to state machine
2. Add per-error recovery strategies (permission denied, gateway timeout, TTS failure, etc.)
3. Add WebSocket reconnection handling for Talk mode
4. Document VAD approach (energy-based is placeholder, needs tuning)
5. Document SFSpeechRecognizer limitations (network, accents, single-use tasks)
6. Add binary frame handling to GatewayClient (Condition 2)
7. Add binary frame validation and size limits (Condition 7)

### Should Fix During Implementation

1. **Audio format negotiation:** Don't assume `pcm_44100`. Auto-detect or negotiate based on `talk.config` response.
2. **Voice directive parsing:** `{"voice":"...","once":true}` prefix needs a robust parser that handles malformed JSON.
3. **Accessibility:** Talk overlay should support VoiceOver for Listening/Thinking/Speaking labels.
4. **Permission sequencing:** Request microphone first, then speech recognition — not both at once.

### Nice to Have (Post-Implementation)

1. **Wake word detection:** Hands-free activation. Significant addition (on-device model), don't let it delay Phase 1.
2. **Conversation mode:** Make the continuous Listening → Thinking → Speaking → Listening loop explicit in the spec. It's implied but not stated.
3. **Audio output device selection:** Mac mini may have no speakers. Let users choose AirPods/Bluetooth in settings.

---

## 8. Open Questions for Reviewer Response

1. **Multi-turn conversation:** Should Talk mode keep the same `chat.send` session across multiple utterances (maintaining conversation history), or start fresh each time? The spec implies the same session — confirm this is intentional.

2. **Voice directives:** Does `talk.speak` strip `{"voice":...}` directives before synthesis, or does BeeChat need to strip them? Recommendation: check gateway behaviour; if not stripped, BeeChat must do it.

3. **Audio output device:** Should Talk mode play through the default output device, or allow user selection? For Mac mini with no speakers, routing to AirPods/Bluetooth should be a settings option.

---

## Summary

| Area | Verdict |
|------|---------|
| Architecture | ✅ Correct, missing 3 states |
| Error handling | ❌ Needs explicit per-error recovery |
| Reconnection | ❌ Needs handling for WebSocket drops |
| VAD | ⚠️ Placeholder approach, needs detail |
| SFSpeechRecognizer | ✅ Correct, document limitations |
| Gateway RPCs | ✅ Correct, binary frames are the gap |
| Security | ✅ Low risk, add binary frame validation |
| Phase 1 estimate | ⚠️ 2-3 weeks → 3-4 weeks (GatewayClient refactor) |
| Phase 2 estimate | ❌ 2 weeks → 3-4 weeks (WebRTC complexity) |
| **Overall** | **✅ Approved with 7 conditions** |

**Verdict:** Good spec. Build it. But fix the error handling, add the missing states, and extend GatewayClient for binary frames first.