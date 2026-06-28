import SwiftUI

/// Native macOS Settings panel content for font scale control.
/// Opened with ⌘, via the `Settings` scene in BeeChatApp.
///
/// All state flows through the environment-injected `ThemeManager`.
/// Quick-select buttons jump to fixed values; the slider is continuous
/// with 0.1 step. `setFontScale` does the clamping and persistence.
struct FontSizeSettingsView: View {
    @Environment(ThemeManager.self) var themeManager

    private let presets: [(label: String, value: CGFloat)] = [
        ("XS", 0.7),
        ("S",  0.85),
        ("M",  1.0),
        ("L",  1.2),
        ("XL", 1.5),
        ("XXL", 2.0),
    ]

    var body: some View {
        Form {
            Section {
                Text("Adjust the size of all text in BeeChat. Changes apply immediately.")
                    .font(themeManager.font(.caption))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Text Size")
            }

            Section {
                Slider(
                    value: Binding(
                        get: { Double(themeManager.fontScale) },
                        set: { themeManager.setFontScale(CGFloat($0)) }
                    ),
                    in: 0.7...2.0,
                    step: 0.1
                ) {
                    Text("Text Size")
                } minimumValueLabel: {
                    Text("A").font(.caption2)
                } maximumValueLabel: {
                    Text("A").font(.title)
                }
                .accessibilityLabel("Text size slider")
                .accessibilityValue("\(Int(themeManager.fontScale * 100))%")

                Text("Current: \(Int(themeManager.fontScale * 100))%")
                    .font(themeManager.font(.caption))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } header: {
                Text("Slider")
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.label) { preset in
                        Button(preset.label) {
                            themeManager.setFontScale(preset.value)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(abs(themeManager.fontScale - preset.value) < 0.01)
                        .accessibilityLabel("\(preset.label) — \(Int(preset.value * 100))%")
                    }
                }
            } header: {
                Text("Quick Select")
            }

            Section {
                previewBubble
            } header: {
                Text("Preview")
            }

            Section {
                Button("Reset to Default (100%)") {
                    themeManager.setFontScale(1.0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 380)
    }

    /// Sample message bubble rendered at the current scale so the user
    /// can see the impact immediately.
    private var previewBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text("Bee")
                    .font(themeManager.font(.heading))
                Spacer()
                Text("just now")
                    .font(themeManager.font(.caption))
                    .foregroundStyle(.secondary)
            }
            Text("This is a sample message rendered at the current text size. It helps you preview how your messages will look.")
                .font(themeManager.font(.body))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
