import SwiftUI
import BeeChatPersistence

/// Single message bubble — 66% fixed width, left or right aligned.
struct MessageBubble: View {
    @Environment(ThemeManager.self) var themeManager
    let message: Message

    private var isFromUser: Bool {
        message.role == "user"
    }

    private var isSystem: Bool {
        message.role == "system"
    }

    private var agentBadgeTitle: String? {
        guard !isFromUser,
              let agentId = message.agentId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !agentId.isEmpty else {
            return nil
        }

        switch agentId.lowercased() {
        case "main":
            return nil
        case "q":
            return "🛠 Q"
        case "mel":
            return "🎨 Mel"
        case "kieran":
            return "📋 Kieran"
        case "gav":
            return "🔍 Gav"
        default:
            return "🤖 \(agentId)"
        }
    }

    var body: some View {
        if isSystem {
            systemBubble
        } else {
            chatBubble
        }
    }


    private var systemBubble: some View {
        HStack {
            Spacer()
            Text(message.content ?? "")
                .font(themeManager.font(.caption))
                .italic()
                .foregroundColor(themeManager.color(.textSecondary))
                .padding(.vertical, themeManager.spacing(.sm))
            Spacer()
        }
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.vertical, themeManager.spacing(.xs))
    }


    private var chatBubble: some View {
        HStack {
            if isFromUser { Spacer(minLength: 34) }

            VStack(alignment: isFromUser ? .trailing : .leading, spacing: 4) {
                if !isFromUser, let senderName = message.senderName {
                    Text(senderName)
                        .font(themeManager.font(.caption2))
                        .foregroundColor(themeManager.color(.textSecondary))
                }

                if let agentBadgeTitle {
                    agentBadge(title: agentBadgeTitle)
                }

                MessageContent(message: message)

                Text(message.timestamp, style: .time)
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .padding(.horizontal, themeManager.spacing(.lg))
            .padding(.vertical, themeManager.spacing(.md))
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: themeManager.radius(.xl), style: .continuous)
                    .fill(isFromUser ? themeManager.color(.accentPrimary) : themeManager.color(.bgPanel))
            )
            .foregroundColor(isFromUser ? themeManager.color(.textOnAccent) : themeManager.color(.textPrimary))
            .shadow(
                color: themeManager.color(.shadowMedium).opacity(0.1),
                radius: 4, x: 0, y: 2
            )
            .modifier(BubbleWidthModifier(alignment: isFromUser ? .trailing : .leading))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isFromUser ? "Message from User" : "Message from Assistant")

            if !isFromUser { Spacer(minLength: 34) }
        }
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.vertical, themeManager.spacing(.xs))
    }

    private func agentBadge(title: String) -> some View {
        Text(title)
            .font(themeManager.font(.caption2))
            .foregroundColor(themeManager.color(.textSecondary))
            .padding(.horizontal, themeManager.spacing(.sm))
            .padding(.vertical, themeManager.spacing(.xs))
            .background(
                Capsule(style: .continuous)
                    .fill(themeManager.color(.bgElevated))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
            )
            .accessibilityLabel("Agent \(title)")
    }
}

/// Enforces the 66% max width constraint on message bubbles.
struct BubbleWidthModifier: ViewModifier {
    @Environment(\.canvasWidth) var canvasWidth
    var alignment: Alignment = .leading
    
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: canvasWidth * 0.66, alignment: alignment)
    }
}

extension BubbleWidthModifier {
    static func leading() -> BubbleWidthModifier {
        BubbleWidthModifier(alignment: .leading)
    }
    static func trailing() -> BubbleWidthModifier {
        BubbleWidthModifier(alignment: .trailing)
    }
}

/// Environment key for the canvas width, measured at the MessageCanvas level.
struct CanvasWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1200 // fallback — supports 100-char lines at 66%
}

extension EnvironmentValues {
    var canvasWidth: CGFloat {
        get { self[CanvasWidthKey.self] }
        set { self[CanvasWidthKey.self] = newValue }
    }
}