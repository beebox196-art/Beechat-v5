# FR-002: Tap-to-Reconnect on macOS Status Bar

**Priority:** High  
**Status:** Spec — PASS WITH CHANGES (Kieran review complete, 2026-06-19)
**Author:** Bee (Coordinator)  
**Date:** 2026-06-18  
**Predecessor:** FIX-001 (reconnect dedup guard, validated by Adam)  
**Related:** KI-3 / FR-2 in `Docs/Status/STATUS.md`  
**Reference implementation:** `BeeChat-Mobile/BeeChatMobile/Sources/BeeChatUI/ConnectionViews.swift` — `ConnectionStatusView`

## Problem

When the gateway connection drops and exhausts its 10-retry backoff, `GatewayStatusBar` shows "Connection error" but there is no way to reconnect without restarting the app. The user is stuck.

The iOS app solved this cleanly: `ConnectionStatusView` is a `Button` — tap when offline calls `viewModel.reconnect()`. Adam used this feature on macOS and wants the same UX: click the status bar text when it shows an error, app reconnects. No buttons, no sliders, just click the heading.

## Scope

**In scope:**
- Add `reconnect()` method to `AppState`
- Add tap gesture to `GatewayStatusBar` when connection is `.disconnected` or `.error`
- Show a subtle circular arrow icon when in tappable state
- Clear `offlineStatus` / `errorMessage` on successful reconnect

**Out of scope:**
- No changes to `GatewayClient` backoff logic (already works — 10 retries, exponential backoff)
- No changes to `SyncBridge` or `EventRouter`
- No background retry timer (separate feature if needed later)
- No new UI components — modify existing `GatewayStatusBar` only

## Design

### Principle

Minimal change. The status bar already shows the right states. We just make it tappable when offline and wire it to a reconnect method. Same pattern as iOS `ConnectionStatusView.onRetry`.

### 1. `AppState.reconnect()`

Add a reconnect method to `AppState` in `Sources/App/AppRootView.swift`:

```swift
// Re-entrancy guard property — stores the active connection state subscription
private var connectionStateTask: Task<Void, Never>?

func reconnect() {
    // Guard 1: no bridge to reconnect with
    guard syncBridge != nil else { return }
    // Guard 2: already reconnecting (Kieran MAJOR #1 — prevents race on rapid taps)
    guard connectionState != .connecting && connectionState != .handshaking else { return }
    // Set state SYNCHRONOUSLY before any await — closes the re-entrancy window
    connectionState = .connecting
    
    Task {
        // Clear stale error state
        offlineStatus = nil
        errorMessage = nil
        
        // Stop existing bridge
        if let bridge = syncBridge {
            await bridge.stop()
        }
        
        // Cancel old connection state subscription (Kieran MAJOR #2 — prevents state clobbering)
        connectionStateTask?.cancel()
        connectionStateTask = nil
        
        // Rebuild and reconnect (same path as startup, minus DB init)
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/openclaw.json")
        
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            connectionState = .error
            offlineStatus = "Offline — no gateway config found"
            return
        }
        
        do {
            let gatewayConfig = try loadGatewayConfig(from: configPath)
            let tokenStore = KeychainTokenStore()
            let gatewayClient = GatewayClient(config: gatewayConfig, tokenStore: tokenStore)
            let persistenceStore = BeeChatPersistenceStore(dbManager: DatabaseManager.shared)
            let config = SyncBridgeConfiguration(
                gatewayClient: gatewayClient,
                persistenceStore: persistenceStore
            )
            let bridge = SyncBridge(config: config)
            self.syncBridge = bridge
            
            try await bridge.start()
            connectionState = .connected
            isStartupComplete = true
            
            // Subscribe to live connection state — store the Task for cancellation on next reconnect
            connectionStateTask = Task {
                let stream = await bridge.connectionStateStream()
                for await state in stream {
                    self.connectionState = state
                }
            }
        } catch {
            connectionState = .error
            offlineStatus = "Offline — \(error.localizedDescription)"
        }
    }
}
```

**Notes:**
- Reuses `loadGatewayConfig` (already private method on `AppState`)
- Reuses `DatabaseManager.shared` (already open from startup)
- Creates fresh `GatewayClient` + `SyncBridge` (same as iOS `disconnect() → connect()`)
- **Re-entrancy guard (Kieran MAJOR #1):** `connectionState` is set to `.connecting` synchronously before the first `await`, and a guard prevents re-entry while `.connecting` or `.handshaking`. This prevents multiple concurrent reconnect attempts from rapid taps.
- **Connection state subscription cancellation (Kieran MAJOR #2):** The old `connectionStateStream` subscription is stored in `connectionStateTask` and explicitly cancelled before creating the new bridge. This prevents the old bridge's final `.disconnected` event from clobbering the new bridge's state updates. The same pattern should be retrofitted to `startup()` for consistency.
- `hasStarted` guard in `startup()` prevents double-init; `reconnect()` is separate and can be called multiple times.
- `reconnect()` assumes `startup()` successfully opened the database. If startup failed at the DB level, reconnect will fail with a persistence error (acceptable — app is already degraded).
- `bridge.stop()` is non-throwing by design — no error handling needed for the stop call.

**Consideration — extract shared method:**
The gateway config loading + bridge creation + connection state subscription is duplicated between `startup()` and `reconnect()`. If Q prefers, extract a private `func connectToGateway(persistenceStore:)` method that both call. Q's call — the duplication is small enough (8 lines) that either way is fine.

### 2. `GatewayStatusBar` tap action

Modify `Sources/App/UI/Components/GatewayStatusBar.swift` to add tap-to-reconnect:

```swift
struct GatewayStatusBar: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(AppState.self) var appState
    let connectionState: ConnectionState
    var detailText: String? = nil

    private var isTappable: Bool {
        // Kieran MINOR #1 — don't show tappable state during initialisation
        appState.isStartupComplete && (connectionState == .disconnected || connectionState == .error)
    }

    // ... existing statusText and dotColor unchanged ...

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(themeManager.color(.textSecondary))
            if isTappable {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeManager.color(.textSecondary))
            }
        }
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.vertical, themeManager.spacing(.xxs))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.color(.bgSurface))
        .contentShape(Rectangle())  // Make full width tappable
        .onTapGesture {
            if isTappable {
                appState.reconnect()
            }
        }
        .accessibilityLabel("Gateway status")
        .accessibilityHint(isTappable ? "Tap to reconnect" : "Current gateway connection status")
        .accessibilityValue(Text(statusText))
    }
}
```

**Key changes:**
- `isTappable` computed property — true when `.disconnected` or `.error`
- `arrow.clockwise` SF Symbol appears when tappable (same as iOS `ConnectionStatusView`)
- `.contentShape(Rectangle())` ensures the full width of the bar is tappable, not just the text
- `.onTapGesture` calls `appState.reconnect()` only when tappable
- Accessibility hint updates to "Tap to reconnect" when tappable
- **No visual change when connected** — same subtle dot + text, no arrow, not tappable

### 3. No changes to `MainWindow`

The call site at `MainWindow.swift:157` stays exactly the same:
```swift
GatewayStatusBar(connectionState: appState.connectionState, detailText: appState.offlineStatus ?? appState.errorMessage)
```

No new parameters, no new bindings. The tap gesture is internal to `GatewayStatusBar` and uses `@Environment(AppState.self)` to call reconnect.

## Files Changed

| File | Change | Lines |
|---|---|---|
| `Sources/App/AppRootView.swift` | Add `reconnect()` method to `AppState` | ~30 new |
| `Sources/App/UI/Components/GatewayStatusBar.swift` | Add tap gesture, arrow icon, `isTappable` | ~10 new/modified |

**Total: ~40 lines changed across 2 files.**

## Success Criteria

1. App running, gateway goes down → status bar shows "Connection error" with arrow icon
2. Click the status bar text → status changes to "Connecting…", arrow disappears
3. Gateway comes back → status shows "Connected", normal operation resumes
4. Click when already connected → nothing happens (not tappable)
5. Click during "Connecting…" or "Handshaking…" → nothing happens (not tappable yet)
6. Multiple clicks when error → only one reconnect attempt fires (synchronous `.connecting` guard + `isTappable` check)
7. No duplicate messages after reconnect (FIX-001 dedup guard already handles this)
8. Build clean, no warnings, all existing tests pass

## Review Checklist

- [ ] `reconnect()` doesn't leak the old `SyncBridge` (check `bridge.stop()` cleans up properly)
- [ ] `connectionStateStream` from old bridge terminates cleanly (no hanging task)
- [ ] `loadGatewayConfig` is accessible from `reconnect()` (it's a private method — same class, fine)
- [ ] `DatabaseManager.shared` is already open (guaranteed by `startup()` running first)
- [ ] No race condition if user taps rapidly (synchronous state guard + re-entrancy check)
- [ ] Arrow icon is subtle and matches the 11pt text size (not jarring)
- [ ] VoiceOver: "Tap to reconnect" hint is announced when tappable

## Build & Validation

| Step | Owner |
|---|---|
| Spec review | Kieran |
| Implement | Q |
| Code review | Kieran (structured review via `scripts/review/code-review.sh`) |
| Build + test | Q |
| Smoke test | Adam (disconnect gateway, tap to reconnect, verify messages flow) |

## Notes

- The iOS reference implementation (`ConnectionStatusView`) uses a `Button` wrapper. On macOS, `.onTapGesture` with `.contentShape(Rectangle())` is more idiomatic — macOS users click anywhere on the bar, not just on a button target. Either approach works; `.onTapGesture` is fewer lines and matches "just click the heading" UX.
- The `arrow.clockwise` icon is the same SF Symbol used in the iOS version. Consistent across platforms.
- If a background retry timer is wanted later (auto-reconnect every 30s after exhausting backoff), that's a separate spec. This one is manual reconnect only.
- **Known risk (Kieran MINOR #2):** `TopicServer` port release is asynchronous. If the old listener hasn't fully released port 8976 before the new one starts, iPhone sync will silently break after reconnect. Pre-existing issue, not introduced by this spec. If it surfaces during testing, Q should add a small delay/retry in `TopicServer.start()` — out of scope for FR-002.
- **Kieran review:** `Docs/Reviews/Cycles/tap-to-reconnect/FR-002-KIERAN-REVIEW.md` — PASS WITH CHANGES (2 MAJOR, 2 MINOR, 3 NIT). All MAJOR findings incorporated into this spec revision.