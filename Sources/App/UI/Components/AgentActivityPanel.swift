import SwiftUI

struct AgentActivityPanel: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss
    var tracker: SyncBridgeObserver.AgentActivityTracker

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Team Activity")
                    .font(themeManager.font(.heading))
                    .foregroundColor(themeManager.color(.textPrimary))
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .font(themeManager.font(.subheading))
                .foregroundColor(themeManager.color(.accentPrimary))
            }
            .padding(.horizontal, themeManager.spacing(.xl))
            .padding(.vertical, themeManager.spacing(.lg))

            Divider()
                .background(themeManager.color(.borderSubtle))

            ScrollView {
                VStack(spacing: 0) {
                    // Agent list
                    let sortedAgents = tracker.agents.values.sorted { a, b in
                        let orderA = agentSortOrder(for: a.status)
                        let orderB = agentSortOrder(for: b.status)
                        if orderA != orderB { return orderA < orderB }
                        return a.agentId < b.agentId
                    }

                    ForEach(sortedAgents, id: \.agentId) { agent in
                        AgentRow(agent: agent, themeManager: themeManager)
                            .padding(.horizontal, themeManager.spacing(.xl))
                            .padding(.vertical, themeManager.spacing(.sm))
                    }

                    if !tracker.recentEvents.isEmpty {
                        Divider()
                            .padding(.vertical, themeManager.spacing(.sm))
                            .padding(.horizontal, themeManager.spacing(.xl))

                        Text("Recent")
                            .font(themeManager.font(.caption))
                            .foregroundColor(themeManager.color(.textSecondary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, themeManager.spacing(.xl))
                            .padding(.top, themeManager.spacing(.sm))

                        ForEach(tracker.recentEvents) { event in
                            RecentEventRow(event: event, themeManager: themeManager)
                                .padding(.horizontal, themeManager.spacing(.xl))
                                .padding(.vertical, themeManager.spacing(.xs))
                        }
                    }

                    if tracker.agents.isEmpty {
                        Text("No agent activity yet")
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.textSecondary))
                            .padding(themeManager.spacing(.xl))
                    }
                }
            }
            .background(themeManager.color(.bgSurface))
        }
        .frame(minWidth: 360, minHeight: 280)
        .background(themeManager.color(.bgSurface))
    }

    private func agentSortOrder(for status: SyncBridgeObserver.AgentActivityTracker.AgentStatus) -> Int {
        switch status {
        case .working: return 0
        case .error: return 1
        case .idle: return 2
        }
    }
}

// MARK: - Agent Row

struct AgentRow: View {
    let agent: SyncBridgeObserver.AgentActivityTracker.AgentActivity
    let themeManager: ThemeManager

    private var statusColor: Color {
        switch agent.status {
        case .working:
            return themeManager.color(.accentPrimary)
        case .idle:
            return themeManager.color(.textSecondary).opacity(0.5)
        case .error:
            return themeManager.color(.error)
        }
    }

    private var statusText: String {
        switch agent.status {
        case .working: return "Working"
        case .idle: return "Idle"
        case .error: return "Error"
        }
    }

    private var timeText: String {
        let elapsed = Date().timeIntervalSince(agent.lastActivityAt)
        if agent.status == .working {
            if elapsed < 60 {
                return "Now"
            } else {
                return timeAgo(elapsed)
            }
        }
        return timeAgo(elapsed)
    }

    var body: some View {
        HStack(spacing: themeManager.spacing(.md)) {
            let info = SyncBridgeObserver.AgentActivityTracker.agentEmojiAndName(for: agent.agentId)
            Text(info.emoji)
                .font(themeManager.font(.subheading))
                .frame(width: 24)

            Text(info.name)
                .font(themeManager.font(.body))
                .foregroundColor(themeManager.color(.textPrimary))

            Spacer()

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(themeManager.font(.caption))
                .foregroundColor(statusColor)
                .frame(minWidth: 48, alignment: .leading)

            Text(timeText)
                .font(themeManager.font(.caption))
                .foregroundColor(themeManager.color(.textSecondary))
                .frame(minWidth: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(SyncBridgeObserver.AgentActivityTracker.agentEmojiAndName(for: agent.agentId).name), \(statusText), \(timeText)")
    }

    private func timeAgo(_ elapsed: TimeInterval) -> String {
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m"
        } else if elapsed < 86400 {
            return "\(Int(elapsed / 3600))h"
        } else {
            return "\(Int(elapsed / 86400))d"
        }
    }
}

// MARK: - Recent Event Row

struct RecentEventRow: View {
    let event: SyncBridgeObserver.AgentActivityTracker.RecentEvent
    let themeManager: ThemeManager

    private var verb: String {
        switch event.kind {
        case .completed: return "completed"
        case .errored: return "errored"
        }
    }

    private var elapsed: TimeInterval {
        Date().timeIntervalSince(event.timestamp)
    }

    var body: some View {
        HStack(spacing: themeManager.spacing(.md)) {
            let info = SyncBridgeObserver.AgentActivityTracker.agentEmojiAndName(for: event.agentId)
            Text(info.emoji)
                .font(themeManager.font(.subheading))
                .frame(width: 24)

            Text("\(info.name) \(verb)")
                .font(themeManager.font(.body))
                .foregroundColor(themeManager.color(.textPrimary))

            Spacer()

            Text(timeAgo(elapsed))
                .font(themeManager.font(.caption))
                .foregroundColor(themeManager.color(.textSecondary))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(SyncBridgeObserver.AgentActivityTracker.agentEmojiAndName(for: event.agentId).name) \(verb) \(timeAgo(elapsed)) ago")
    }

    private func timeAgo(_ elapsed: TimeInterval) -> String {
        if elapsed < 60 {
            return "\(Int(elapsed))s ago"
        } else if elapsed < 3600 {
            return "\(Int(elapsed / 60))m ago"
        } else if elapsed < 86400 {
            return "\(Int(elapsed / 3600))h ago"
        } else {
            return "\(Int(elapsed / 86400))d ago"
        }
    }
}

#Preview {
    AgentActivityPanel(tracker: SyncBridgeObserver.AgentActivityTracker())
        .environment(ThemeManager())
}
