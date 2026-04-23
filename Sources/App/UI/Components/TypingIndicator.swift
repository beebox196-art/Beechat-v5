import SwiftUI

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
                        themeManager.animation(.slower)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animations[index]
                    )
                    .onAppear {
                        animations[index] = true
                    }
            }
        }
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.vertical, themeManager.spacing(.md))
        .background(themeManager.color(.bgPanel))
        .clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.xl), style: .continuous))
        .frame(maxWidth: 100, alignment: .leading)
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.bottom, themeManager.spacing(.sm))
        .transition(.opacity)
    }
}