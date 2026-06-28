import SwiftUI
import BeeChatSyncBridge

struct SessionRow: View {
    @Environment(ThemeManager.self) var themeManager
    @Bindable var topic: TopicViewModel
    var thinkingState: ThinkingState = .idle
    var sessionUsage: Double? = nil
    var unreadCount: Int = 0  // In-memory unread count from SyncBridgeObserver
    var onReset: (() -> Void)? = nil
    var onSelect: (() -> Void)?
    var onMarkUnread: ((Bool) -> Void)? = nil
    var isSelected: Bool = false
    var projectContextState: ProjectContextState = .none
    var bridge: SyncBridge? = nil  // Phase 2: needed for saveTopicSummary

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

            // Phase 2: transient save status indicator
            saveStatusIndicator

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
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.6))
                    .help("Project context linked: \(name)")
                    .accessibilityLabel("Project bound to \(name)")
            } else if case .injected(let name) = projectContextState {
                Image(systemName: "folder.fill")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.6))
                    .help("Project context linked: \(name)")
                    .accessibilityLabel("Project bound to \(name)")
            } else if case .unavailable(let name, let reason) = projectContextState {
                Image(systemName: "folder.badge.exclamationmark")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(.orange)
                    .help("Project context unavailable for \(name): \(reason)")
                    .accessibilityLabel("Project context unavailable for \(name)")
                    .accessibilityValue(reason)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Select conversation")
        .contextMenu {
            contextMenuItems
        }
    }

    // MARK: - Phase 2: Topic Summary Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        // Edit Topic (existing)
        Button {
            onSelect?()
        } label: {
            Label("Edit Topic", systemImage: "pencil")
        }

        // Save Topic Summary (NEW — Phase 2)
        Button {
            Task {
                guard let bridge = bridge else { return }
                await topic.saveTopicSummary(bridge: bridge)
            }
        } label: {
            if topic.isSaving {
                Label("Saving topic...", systemImage: "arrow.triangle.2.circlepath")
            } else {
                Label("Save Topic Summary", systemImage: "doc.badge.plus")
            }
        }
        .disabled(topic.isSaving)
        .accessibilityHint(topic.isSaving ? "Save already in progress" : "Extract durable items from recent conversation and save to project summary file")

        // Reset Session (existing)
        Button {
            onReset?()
        } label: {
            Label("Reset Session", systemImage: "arrow.clockwise")
        }

        // Mark as Unread / Mark as Read (mutually exclusive)
        if unreadCount == 0 && !isSelected {
            Button {
                onMarkUnread?(true)
            } label: {
                Label("Mark as Unread", systemImage: "circle.badge")
            }
        } else if unreadCount > 0 {
            Button {
                onMarkUnread?(false)
            } label: {
                Label("Mark as Read", systemImage: "circle.slash")
            }
        }

        Divider()

        // Delete Topic (existing — would be added by parent if needed)
    }

    // MARK: - Phase 2: Transient Save Status Indicator

    @ViewBuilder
    private var saveStatusIndicator: some View {
        switch topic.saveStatus {
        case .idle:
            EmptyView()

        case .saving:
            ProgressView()
                .scaleEffect(0.7)
                .accessibilityLabel("Saving topic summary")
                .accessibilityValue("In progress")

        case .success:
            Text("Topic saved")
                .font(themeManager.font(.caption2))
                .foregroundColor(.green)
                .accessibilityLabel("Topic summary saved")
                .accessibilityValue("Success")

        case .empty:
            Text("No changes to save")
                .font(themeManager.font(.caption2))
                .foregroundColor(themeManager.color(.textSecondary))
                .accessibilityLabel("No durable topic changes found")
                .accessibilityValue("No changes to save")

        case .failed(let reason):
            Label {
                Text("Could not save")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(.orange)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(.orange)
            }
            .help(reason)
            .accessibilityLabel("Topic summary could not be saved")
            .accessibilityValue(reason)
        }
    }

    private var accessibilityLabel: String {
        var parts = ["\(topic.title), \(healthDescription), \(topic.messageCount) messages"]
        if unreadCount > 0 {
            parts.append("unread")
        }
        if shouldShowResetDot {
            parts.append("session at \(Int((sessionUsage ?? 0) * 100))% — reset available")
        }
        // Phase 2: announce save status
        switch topic.saveStatus {
        case .saving:
            parts.append("saving topic summary")
        case .success:
            parts.append("topic summary saved")
        case .empty:
            parts.append("no durable changes found")
        case .failed(let reason):
            parts.append("topic summary save failed: \(reason)")
        case .idle:
            break
        }
        return parts.joined(separator: ", ")
    }
}
