import SwiftUI

/// A partial assistant message bubble shown during streaming.
/// Displays the accumulated streaming text with a blinking cursor to indicate
/// that the response is still being generated.
struct StreamingBubble: View {
    @Environment(ThemeManager.self) var themeManager
    let content: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                // Sender name
                Text("Bee")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))

                // Streaming content with cursor
                HStack(spacing: 0) {
                    Text(content)
                        .font(themeManager.font(.body))
                        .textSelection(.enabled)

                    // Blinking cursor
                    Text("▌")
                        .font(themeManager.font(.body))
                        .foregroundColor(themeManager.color(.accentPrimary))
                        .opacity(cursorVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: cursorVisible)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(themeManager.color(.bgSurface))
            )
            .foregroundColor(themeManager.color(.textPrimary))
            .shadow(
                color: themeManager.color(.shadowMedium).opacity(0.1),
                radius: 4, x: 0, y: 2
            )
            .frame(maxWidth: .infinity)
            .modifier(BubbleWidthModifier())

            Spacer(minLength: 34)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .onAppear { cursorVisible = true }
    }

    @State private var cursorVisible = false
}