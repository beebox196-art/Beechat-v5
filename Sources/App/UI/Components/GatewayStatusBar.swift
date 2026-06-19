import SwiftUI
import BeeChatGateway

struct GatewayStatusBar: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(AppState.self) var appState
    let connectionState: ConnectionState
    var detailText: String? = nil

    private var isConnected: Bool {
        connectionState == .connected
    }

    private var isTappable: Bool {
        // Kieran MINOR #1 — don't show tappable state during initialisation
        appState.isStartupComplete && (connectionState == .disconnected || connectionState == .error)
    }

    private var statusText: String {
        if !appState.isStartupComplete {
            return "Initialising…"
        }
        if let detail = detailText, !detail.isEmpty {
            return detail
        }
        switch connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting…"
        case .handshaking:
            return "Handshaking…"
        case .disconnected:
            return "No gateway connection"
        case .error:
            return "Connection error"
        }
    }

    private var dotColor: Color {
        if !appState.isStartupComplete {
            return themeManager.color(.warning)
        }
        switch connectionState {
        case .connected:
            return themeManager.color(.success)
        case .connecting, .handshaking:
            return themeManager.color(.warning)
        case .disconnected:
            return themeManager.color(.textSecondary).opacity(0.6)
        case .error:
            return themeManager.color(.error)
        }
    }

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
        .contentShape(Rectangle())
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