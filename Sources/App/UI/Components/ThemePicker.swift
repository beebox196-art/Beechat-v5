import SwiftUI

// MARK: - Theme Picker Settings Sheet

struct ThemePicker: View {
    @Environment(ThemeManager.self) var themeManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Appearance")
                    .font(themeManager.font(.heading))
                    .foregroundColor(themeManager.color(.textPrimary))
                Spacer()
                Button("Done") {
                    // Dismissed by parent sheet
                }
                .font(themeManager.font(.subheading))
                .foregroundColor(themeManager.color(.accentPrimary))
            }
            .padding(.horizontal, themeManager.spacing(.xl))
            .padding(.vertical, themeManager.spacing(.lg))

            Divider()
                .background(themeManager.color(.borderSubtle))

            // Theme grid
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 180), spacing: 16)
                    ],
                    spacing: 16
                ) {
                    ForEach(themeManager.availableThemes) { metadata in
                        ThemeCard(
                            metadata: metadata,
                            isSelected: themeManager.currentTheme.id == metadata.id
                        )
                        .onTapGesture {
                            themeManager.switchTheme(to: metadata.id)
                        }
                    }
                }
                .padding(themeManager.spacing(.xl))
            }
            .background(themeManager.color(.bgSurface))
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(themeManager.color(.bgSurface))
    }
}

// MARK: - Theme Card

struct ThemeCard: View {
    let metadata: ThemeMetadata
    let isSelected: Bool
    @Environment(ThemeManager.self) var themeManager

    var body: some View {
        VStack(spacing: themeManager.spacing(.sm)) {
            // Color swatch preview
            HStack(spacing: 2) {
                ForEach(Array(metadata.previewColors.enumerated()), id: \.offset) { _, color in
                    RoundedRectangle(cornerRadius: themeManager.radius(.sm))
                        .fill(color)
                        .frame(height: 32)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: themeManager.radius(.md))
                    .stroke(
                        isSelected
                            ? themeManager.color(.accentPrimary)
                            : themeManager.color(.borderSubtle),
                        lineWidth: isSelected ? 3 : 1
                    )
            )
            .shadow(
                color: isSelected
                    ? themeManager.color(.accentPrimary).opacity(0.3)
                    : themeManager.color(.shadowLight),
                radius: isSelected ? 8 : 2,
                x: 0,
                y: isSelected ? 2 : 1
            )

            // Theme name
            Text(metadata.name)
                .font(themeManager.font(.caption))
                .foregroundColor(
                    isSelected
                        ? themeManager.color(.accentPrimary)
                        : themeManager.color(.textPrimary)
                )
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(themeManager.spacing(.md))
        .background(
            RoundedRectangle(cornerRadius: themeManager.radius(.lg))
                .fill(themeManager.color(.bgPanel))
        )
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(themeManager.animation(.micro), value: isSelected)
        .accessibilityLabel(metadata.name)
        .accessibilityHint("Select \(metadata.name) theme")
        .accessibilityValue(isSelected ? "Selected" : "")
    }
}

// MARK: - Preview

#Preview {
    ThemePicker()
        .environment(ThemeManager())
}
