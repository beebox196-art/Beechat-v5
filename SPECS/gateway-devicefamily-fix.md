# SPEC: Gateway Device Auth v3 — deviceFamily Fix

**Date:** 2026-05-18  
**Status:** ✅ Implemented & Deployed (pending formal review)  
**Author:** Bee  
**Reviewer:** Q (implementation), Kieran (adversarial review) — PENDING

## Problem

BeeChat desktop went offline after the gateway upgraded to protocol v4. The handshake was rejected with `DEVICE_AUTH_SIGNATURE_INVALID`.

## Root Cause

The gateway's `buildDeviceAuthPayloadV3` constructs a canonical signing string:

```
v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily
```

Both `platform` and `deviceFamily` are normalized via `toLowerAscii(trim(...))`. When `deviceFamily` is undefined, it normalizes to `""` (empty string).

BeeChat's `ClientInfo` struct was missing the `deviceFamily` field entirely. The signing code in `DeviceCrypto.swift` used hardcoded platform-specific values:
- macOS: `deviceFamily: "desktop"` 
- iOS: `deviceFamily: "mobile"`

Result: gateway signed `"...|macos|"` (empty deviceFamily), BeeChat signed `"...|macos|desktop"` → signature mismatch.

## Fix Applied

### 1. ConnectParams.swift — Added fields to ClientInfo

```swift
public struct ClientInfo: Codable, Sendable {
    public let id: String
    public let displayName: String?        // NEW
    public let version: String
    public let platform: String
    public let deviceFamily: String?       // NEW
    public let modelIdentifier: String?     // NEW
    public let mode: String
    public let instanceId: String?          // NEW
}
```

All new fields are optional — no breaking change for existing code.

### 2. GatewayClient.swift — Default ClientInfo includes deviceFamily

```swift
// macOS default:
.init(id: "openclaw-control-ui", version: "1.0", platform: "macos", mode: clientMode, deviceFamily: "desktop")

// iOS default:
.init(id: "openclaw-ios", version: "1.0", platform: "ios", mode: clientMode, deviceFamily: "mobile")
```

Also fixed macOS default `id` from `"openclaw-macos"` to `"openclaw-control-ui"` to match the gateway's expected Control UI client ID.

### 3. GatewayClient.swift — Signing uses config values, not #if blocks

Before:
```swift
platform: {
    #if os(iOS)
    return "ios"
    #elseif os(macOS)
    return "macos"
    #else
    return "macos"
    #endif
}(),
deviceFamily: {
    #if os(iOS)
    return "mobile"
    #elseif os(macOS)
    return "desktop"
    #else
    return "desktop"
    #endif
}(),
```

After:
```swift
platform: config.clientInfo.platform,
deviceFamily: config.clientInfo.deviceFamily ?? {
    #if os(iOS)
    return "mobile"
    #elseif os(macOS)
    return "desktop"
    #else
    return "desktop"
    #endif
}(),
```

`platform` and `deviceFamily` now come from config, with `#if` blocks only as fallback defaults.

### 4. AppRootView.swift — Explicit deviceFamily

```swift
clientInfo: .init(id: "openclaw-control-ui", version: "1.0", platform: "macos", mode: "webchat", deviceFamily: "desktop")
```

## Verification

- BeeChat connects to gateway: ✅ ESTABLISHED
- Handshake: challenge → device identity → ok:true, protocol:4
- Full operator scopes received
- Debug log confirms: `succeedHandshake — resuming continuation`

## Risk Assessment

| Aspect | Risk |
|--------|------|
| Existing macOS connections | Zero — same scopes, more secure path |
| Cold start | Zero — device identity sent on first connect |
| Gateway restart | Zero — device tokens persisted |
| iOS (not yet deployed) | One-line change needed: `clientMode: "ui"` |

## Commits

1. `99e3b69` — Protocol v4 upgrade (minProtocol/maxProtocol)
2. `5b60f6c` — Always send device identity
3. `bc26a9e` — Scroll compat fix
4. `6aa7aee` — deviceFamily in ClientInfo (this fix)

## Rollback

See `Docs/GATE-2B-ROLLBACK.md`. Safe rollback point: `bc26a9e` (scroll fix) or `6aa7aee` (this fix). Do NOT roll back past `99e3b69` — gateway requires v4 protocol.