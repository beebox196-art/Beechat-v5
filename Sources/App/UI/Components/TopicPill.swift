import SwiftUI

/// Individual topic pill — segment in the TopicBar horizontal control.
struct TopicPill: View {
    @Environment(ThemeManager.self) var themeManager

    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? themeManager.color(.textOnAccent) : themeManager.color(.textSecondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minWidth: 80, maxWidth: 200)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isSelected ? themeManager.color(.accentPrimary) : themeManager.color(.bgPanel))
                )
                .shadow(
                    color: isSelected ? themeManager.color(.shadowMedium) : themeManager.color(.shadowLight),
                    radius: isSelected ? 4 : 0,
                    x: 0,
                    y: isSelected ? 2 : 0
                )
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Topic: \(title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}