import SwiftUI
import BeeChatGateway

struct GatewayStatusBar: View {
    @Environment(ThemeManager.self) var themeManager
    let connectionState: ConnectionState
    var detailText: String? = nil

    private var isConnected: Bool {
        connectionState == .connected
    }

    private var statusText: String {
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
        switch connectionState {
        case .connected:
            return .green
        case .connecting, .handshaking:
            return .yellow
        case .disconnected:
            return themeManager.color(.textSecondary).opacity(0.6)
        case .error:
            return .red
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.color(.bgSurface))
    }
}