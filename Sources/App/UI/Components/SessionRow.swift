import SwiftUI

struct SessionRow: View {
    @Environment(ThemeManager.self) var themeManager
    let topic: TopicViewModel
    var thinkingState: ThinkingState = .idle
    var sessionUsage: Double? = nil
    var unreadCount: Int = 0  // In-memory unread count from SyncBridgeObserver
    var onReset: (() -> Void)? = nil
    var onSelect: (() -> Void)?
    var projectContextState: ProjectContextState = .none

    /// UI state for project context injection in the sidebar (Mel Warning-3).
    enum ProjectContextState: Equatable {
        case none
        case linked(projectName: String)
        case injected(projectName: String)
        case unavailable(projectName: String, reason: String)
    }

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

    /// Whether the session usage threshold (50%) is reached, triggering the amber dot.
    var shouldShowResetDot: Bool {
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

            // Unread indicator: blue/accent dot only (ONLY when unread > 0)
            if unreadCount > 0 {
                Circle()
                    .fill(themeManager.color(.accentPrimary))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Unread messages")
            }

            // Session reset amber dot — appears at 50% usage, tap to reset
            if shouldShowResetDot {
                Button(action: { onReset?() }) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 10, height: 10)
                        .shadow(color: Color.orange.opacity(0.3), radius: 3, x: 0, y: 0)
                        .contentShape(Rectangle())
                        .frame(width: 24, height: 24)  // Larger hit target for accessibility
                }
                .buttonStyle(.plain)
                .help("Session at \(Int((sessionUsage ?? 0) * 100))% — tap to reset")
                .accessibilityLabel("Session at \(Int((sessionUsage ?? 0) * 100))% — tap to reset")
            }

            // Project context indicator (Mel Warning-3)
            if case .linked(let name) = projectContextState {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.6))
                    .help("Project context linked: \(name)")
                    .accessibilityLabel("Project bound to \(name)")
            } else if case .injected(let name) = projectContextState {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.6))
                    .help("Project context linked: \(name)")
                    .accessibilityLabel("Project bound to \(name)")
            } else if case .unavailable(let name, let reason) = projectContextState {
                Image(systemName: "folder.badge.exclamationmark")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .help("Project context unavailable for \(name): \(reason)")
                    .accessibilityLabel("Project context unavailable for \(name)")
                    .accessibilityValue(reason)
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
        if shouldShowResetDot {
            parts.append("session at \(Int((sessionUsage ?? 0) * 100))% — reset available")
        }
        return parts.joined(separator: ", ")
    }
}