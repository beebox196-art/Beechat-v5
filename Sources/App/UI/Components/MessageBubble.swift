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
                .padding(.vertical, 8)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
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

                MessageContent(message: message)

                Text(message.timestamp, style: .time)
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFromUser ? themeManager.color(.accentPrimary) : themeManager.color(.bgPanel))
            )
            .foregroundColor(isFromUser ? themeManager.color(.textOnAccent) : themeManager.color(.textPrimary))
            .shadow(
                color: themeManager.color(.shadowMedium).opacity(0.1),
                radius: 4, x: 0, y: 2
            )
            .modifier(BubbleWidthModifier(alignment: isFromUser ? .trailing : .leading))

            if !isFromUser { Spacer(minLength: 34) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
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