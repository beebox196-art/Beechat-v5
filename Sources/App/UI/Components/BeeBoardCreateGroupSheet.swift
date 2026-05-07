import SwiftUI

struct BeeBoardCreateGroupSheet: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss

    let palette: [String]
    let onCreate: (String, String) -> Void

    @State private var name = "Group"
    @State private var selectedColor = "#8fa895"

    var body: some View {
        VStack(alignment: .leading, spacing: themeManager.spacing(.lg)) {
            HStack {
                Text("Create Group")
                    .font(themeManager.font(.heading))
                    .foregroundColor(themeManager.color(.textPrimary))

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .foregroundColor(themeManager.color(.textSecondary))
            }

            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: themeManager.spacing(.sm)) {
                Text("Colour")
                    .font(themeManager.font(.caption))
                    .foregroundColor(themeManager.color(.textSecondary))

                HStack(spacing: themeManager.spacing(.sm)) {
                    ForEach(palette, id: \.self) { hex in
                        Button {
                            selectedColor = hex
                        } label: {
                            Circle()
                                .fill(Color(hex: hex) ?? themeManager.color(.accentPrimary))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .stroke(
                                            selectedColor == hex
                                                ? themeManager.color(.textPrimary)
                                                : themeManager.color(.borderSubtle),
                                            lineWidth: selectedColor == hex ? 2 : 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Spacer()

                Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onCreate(trimmed.isEmpty ? "Group" : trimmed, selectedColor)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .foregroundColor(themeManager.color(.accentPrimary))
            }
        }
        .padding(themeManager.spacing(.xl))
        .frame(width: 360)
        .background(themeManager.color(.bgSurface))
    }
}

#Preview {
    BeeBoardCreateGroupSheet(
        palette: BeeBoardViewModel.warmAuroraPalette,
        onCreate: { _, _ in }
    )
    .environment(ThemeManager())
}
