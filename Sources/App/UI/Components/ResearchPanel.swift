import SwiftUI

// MARK: - Research Depth

enum ResearchDepth: String, CaseIterable {
    case quick = "quick"
    case standard = "standard"
    case deep = "deep"

    var displayName: String {
        switch self {
        case .quick: return "⚡ Quick"
        case .standard: return "Standard"
        case .deep: return "🔬 Deep"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .quick: return "Quick Scan — 2 to 3 minutes, chat brief"
        case .standard: return "Standard — 8 to 12 minutes, HTML report"
        case .deep: return "Deep Dive — 15 to 25 minutes, comprehensive HTML report"
        }
    }
}

// MARK: - Research Panel

struct ResearchPanel: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss
    @Bindable var composerViewModel: ComposerViewModel

    @State private var topicText: String = ""
    @State private var selectedDepth: ResearchDepth = .standard
    @State private var tagsText: String = ""
    @FocusState private var isTopicFieldFocused: Bool

    private var canSubmit: Bool {
        !topicText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — matches AgentActivityPanel pattern exactly
            HStack {
                Text("🔍 Research")
                    .font(themeManager.font(.heading))
                    .foregroundColor(themeManager.color(.textPrimary))
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .font(themeManager.font(.subheading))
                .foregroundColor(themeManager.color(.accentPrimary))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, themeManager.spacing(.xl))
            .padding(.vertical, themeManager.spacing(.lg))

            Divider()
                .background(themeManager.color(.borderSubtle))

            VStack(spacing: themeManager.spacing(.lg)) {
                // Topic TextEditor with placeholder overlay
                ZStack(alignment: .topLeading) {
                    if topicText.isEmpty {
                        Text("Paste a link, topic, or idea...")
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.textSecondary))
                            .padding(.horizontal, themeManager.spacing(.md) + 4)
                            .padding(.vertical, themeManager.spacing(.sm) + 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $topicText)
                        .font(themeManager.font(.body))
                        .foregroundColor(themeManager.color(.textPrimary))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, themeManager.spacing(.md))
                        .padding(.vertical, themeManager.spacing(.sm))
                        .focused($isTopicFieldFocused)
                }
                .frame(minHeight: 80, maxHeight: 160)
                .background(
                    RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
                        .fill(themeManager.color(.bgPanel))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
                        .stroke(
                            topicText.isEmpty
                                ? themeManager.color(.borderSubtle)
                                : themeManager.color(.accentPrimary),
                            lineWidth: 1
                        )
                )
                .accessibilityLabel("Topic or link")
                .accessibilityHint("Enter a topic, link, or idea to research")

                // Depth selector
                VStack(alignment: .leading, spacing: themeManager.spacing(.sm)) {
                    Text("Depth")
                        .font(themeManager.font(.subheading))
                        .foregroundColor(themeManager.color(.textPrimary))

                    Picker("Depth", selection: $selectedDepth) {
                        ForEach(ResearchDepth.allCases, id: \.self) { depth in
                            Text(depth.displayName).tag(depth)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Research depth")
                    .accessibilityHint("Select research depth level")
                }

                // Tags field (optional)
                VStack(alignment: .leading, spacing: themeManager.spacing(.sm)) {
                    Text("Tags (optional)")
                        .font(themeManager.font(.subheading))
                        .foregroundColor(themeManager.color(.textPrimary))

                    TextField("topcon, competitor, market", text: $tagsText)
                        .font(themeManager.font(.body))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, themeManager.spacing(.md))
                        .padding(.vertical, themeManager.spacing(.sm))
                        .background(
                            RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
                                .fill(themeManager.color(.bgPanel))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
                                .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
                        )
                        .accessibilityLabel("Tags")
                        .accessibilityHint("Optional comma-separated tags, for example: topcon, competitor")
                }

                // Submit button
                Button(action: submitResearch) {
                    Text("Start Research")
                        .font(themeManager.font(.subheading))
                        .foregroundColor(themeManager.color(.textOnAccent))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, themeManager.spacing(.md))
                        .background(
                            RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous)
                                .fill(
                                    canSubmit
                                        ? themeManager.color(.accentPrimary)
                                        : themeManager.color(.textSecondary).opacity(0.3)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Start research")
                .accessibilityHint(canSubmit
                    ? "Submit research request with selected depth"
                    : "Enter a topic to enable research")
            }
            .padding(.horizontal, themeManager.spacing(.xl))
            .padding(.vertical, themeManager.spacing(.lg))
        }
        .frame(minWidth: 460, idealWidth: 480, minHeight: 340)
        .background(themeManager.color(.bgSurface))
        .onAppear {
            isTopicFieldFocused = true
        }
    }

    private func submitResearch() {
        guard canSubmit else { return }
        let trimmedTopic = topicText.trimmingCharacters(in: .whitespacesAndNewlines)
        let depthFlag = "--depth \(selectedDepth.rawValue)"
        let tagsFlag = tagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : " --tags \(tagsText.trimmingCharacters(in: .whitespacesAndNewlines))"
        let payload = "/research \(depthFlag) \"\(trimmedTopic)\"\(tagsFlag)"

        composerViewModel.sendPayload(payload)
        dismiss()
    }
}