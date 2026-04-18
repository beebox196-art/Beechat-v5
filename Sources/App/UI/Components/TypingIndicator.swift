import SwiftUI

/// Typing indicator — three animated dots shown when Bee is generating a response.
/// HARD CONSTRAINT: streaming buffer content is NEVER displayed. Only this indicator.
struct TypingIndicator: View {
    @Environment(ThemeManager.self) var themeManager
    @State private var animations: [Bool] = [false, false, false]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(themeManager.color(.textSecondary))
                    .frame(width: 8, height: 8)
                    .scaleEffect(animations[index] ? 1.2 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animations[index]
                    )
                    .onAppear {
                        animations[index] = true
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(themeManager.color(.bgPanel))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: 100, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.opacity)
    }
}