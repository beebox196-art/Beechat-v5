import SwiftUI

struct SessionRow: View {
    @Environment(ThemeManager.self) var themeManager
    let topic: TopicViewModel
    var thinkingState: ThinkingState = .idle
    var sessionUsage: Double? = nil
    var unreadCount: Int = 0  // NEW: in-memory unread count from SyncBridgeObserver
    var onReset: (() -> Void)? = nil
    var onSelect: (() -> Void)?

    var healthColor: Color {
        if topic.messageCount < 50 {
            Color(red: 0.42, green: 0.75, blue: 0.54) // Sage green #6BBF8A
        } else if topic.messageCount <= 150 {
            Color(red: 0.91, green: 0.72, blue: 0.29) // Warm honey #E8B84B
        } else {
            Color(red: 0.85, green: 0.42, blue: 0.42) // Soft rose #D96B6B
        }
    }

    var healthDescription: String {
        if topic.messageCount < 50 {
            "Healthy"
        } else if topic.messageCount <= 150 {
            "Getting large"
        } else {
            "Bloated"
        }
    }

    /// Whether the session usage threshold (50%) is reached, triggering the red dot.
    var shouldShowRedDot: Bool {
        guard let usage = sessionUsage else { return false }
        return usage >= 0.50
    }

    var body: some View {
        HStack {
            Circle()
                .fill(healthColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Topic health: \(healthDescription)")
                .accessibilityValue("\(topic.messageCount) messages")

            Text(topic.title)
                .font(themeManager.font(.body))
                .lineLimit(1)

            Spacer()

            // Unread indicator: blue dot only (ONLY when unread > 0)
            // No count text, no bold — just a dot like iMessage/Slack
            if unreadCount > 0 {
                Circle()
                    .fill(themeManager.color(.accentPrimary))  // Blue/accent, NEVER red
                    .frame(width: 8, height: 8)
            }

            // Session reset red dot — appears at 50% usage, tap to reset
            if shouldShowRedDot {
                Button(action: { onReset?() }) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .shadow(color: Color.red.opacity(0.4), radius: 3, x: 0, y: 0)
                }
                .buttonStyle(.plain)
                .help("Session at \(Int((sessionUsage ?? 0) * 100))% — tap to reset")
                .accessibilityLabel("Reset session: \(topic.title) is at \(Int((sessionUsage ?? 0) * 100))% context usage")
            }



            // Dormant bee — shows for idle topics with recent activity
            if thinkingState == .idle, let lastActivity = topic.lastActivityAt, lastActivity > Date.now - 300 {
                ThinkingBeeIndicator(mode: .dormant)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Select conversation")
    }

    private var accessibilityLabel: String {
        var parts = ["\(topic.title), \(healthDescription), \(topic.messageCount) messages"]
        if unreadCount > 0 {
            parts.append("unread")
        }
        return parts.joined(separator: ", ")
    }
}