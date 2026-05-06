import SwiftUI
import BeeBoard

struct BeeBoardSheet: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("BeeBoard")
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

            VStack(spacing: themeManager.spacing(.md)) {
                Spacer()

                Image(systemName: "pin.square")
                    .font(.system(size: 36))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.6))

                Text("BeeBoard")
                    .font(themeManager.font(.heading))
                    .foregroundColor(themeManager.color(.textPrimary))

                Text("Pins and canvas arrive in the next phase.")
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.textSecondary))

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(themeManager.color(.bgSurface))
        }
        .frame(minWidth: 800, minHeight: 560)
        .background(themeManager.color(.bgSurface))
    }
}

#Preview {
    BeeBoardSheet()
        .environment(ThemeManager())
}
