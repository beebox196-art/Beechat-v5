import SwiftUI

struct StreamingBubble: View {
    @Environment(ThemeManager.self) var themeManager
    let content: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bee")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))

                HStack(spacing: 0) {
                    Text(content)
                        .font(themeManager.font(.body))
                        .textSelection(.enabled)

                    Text("▌")
                        .font(themeManager.font(.body))
                        .foregroundColor(themeManager.color(.accentPrimary))
                        .opacity(cursorVisible ? 1 : 0)
                        .animation(themeManager.animation(.slow).repeatForever(autoreverses: true), value: cursorVisible)
                }
            }
            .padding(.horizontal, themeManager.spacing(.lg))
            .padding(.vertical, themeManager.spacing(.md))
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: themeManager.radius(.xl), style: .continuous)
                    .fill(themeManager.color(.bgPanel))
            )
            .foregroundColor(themeManager.color(.textPrimary))
            .shadow(
                color: themeManager.color(.shadowMedium).opacity(0.1),
                radius: 4, x: 0, y: 2
            )
            .modifier(BubbleWidthModifier())

            Spacer(minLength: 34)
        }
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.vertical, themeManager.spacing(.xs))
        .onAppear { cursorVisible = true }
    }

    @State private var cursorVisible = false
}