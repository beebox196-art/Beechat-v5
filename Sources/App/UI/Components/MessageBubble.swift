import SwiftUI
import BeeChatPersistence

/// Single message bubble — 66% fixed width, left or right aligned.
/// Adam's messages (role == "user") are right-aligned with accent colour.
/// Bee's messages (role == "assistant") are left-aligned with surface colour.
/// System messages are centred with secondary text.
struct MessageBubble: View {
    @Environment(ThemeManager.self) var themeManager
    let message: Message

    /// Whether this message is from the user (Adam).
    private var isFromUser: Bool {
        message.role == "user"
    }

    /// Whether this is a system message.
    private var isSystem: Bool {
        message.role == "system"
    }

    var body: some View {
        if isSystem {
            systemBubble
        } else {
            chatBubble
        }
    }

    // MARK: - System bubble (centred, subtle)

    private var systemBubble: some View {
        HStack {
            Spacer()
            Text(message.content ?? "")
                .font(themeManager.font(.caption))
                .italic()
                .foregroundColor(themeManager.color(.textSecondary))
                .padding(.vertical, 8)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Chat bubble (left/right aligned, 66% width)

    private var chatBubble: some View {
        HStack {
            if isFromUser { Spacer(minLength: 34) }

            VStack(alignment: isFromUser ? .trailing : .leading, spacing: 4) {
                // Sender name (for assistant messages)
                if !isFromUser, let senderName = message.senderName {
                    Text(senderName)
                        .font(themeManager.font(.caption2))
                        .foregroundColor(themeManager.color(.textSecondary))
                }

                // Message content
                MessageContent(message: message)

                // Timestamp
                Text(message.timestamp, style: .time)
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: isFromUser ? .trailing : .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFromUser ? themeManager.color(.accentPrimary) : themeManager.color(.bgSurface))
            )
            .foregroundColor(isFromUser ? themeManager.color(.textOnAccent) : themeManager.color(.textPrimary))
            .shadow(
                color: themeManager.color(.shadowMedium).opacity(0.1),
                radius: 4, x: 0, y: 2
            )
            // 66% fixed bubble width constraint
            .frame(maxWidth: .infinity)
            .modifier(BubbleWidthModifier())

            if !isFromUser { Spacer(minLength: 34) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

/// Enforces the 66% max width constraint on message bubbles.
/// Uses the canvas width from the environment to ensure consistent sizing
/// regardless of HStack spacer widths.
struct BubbleWidthModifier: ViewModifier {
    @Environment(\.canvasWidth) var canvasWidth
    
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: canvasWidth * 0.66, alignment: .leading)
    }
}

/// Environment key for the canvas width, measured at the MessageCanvas level.
struct CanvasWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 800 // fallback
}

extension EnvironmentValues {
    var canvasWidth: CGFloat {
        get { self[CanvasWidthKey.self] }
        set { self[CanvasWidthKey.self] = newValue }
    }
}