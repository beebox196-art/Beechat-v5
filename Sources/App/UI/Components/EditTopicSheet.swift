import SwiftUI
import BeeChatPersistence
import BeeChatSyncBridge

/// Sheet for editing a topic's name and project binding.
struct EditTopicSheet: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss

    let topic: Topic
    let onSave: (Topic) -> Void

    @State private var topicName: String = ""
    @State private var selectedProjectPath: String?
    @State private var availableProjects: [String] = []
    @State private var showCreateNewField = false
    @State private var newProjectName: String = ""
    @State private var errorMessage: String?

    private var projectPathBinding: Binding<String> {
        Binding(
            get: { selectedProjectPath ?? "" },
            set: { newValue in
                selectedProjectPath = newValue.isEmpty ? nil : newValue
            }
        )
    }

    init(topic: Topic, onSave: @escaping (Topic) -> Void) {
        self.topic = topic
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Edit Topic")
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

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: themeManager.spacing(.lg)) {
                    // Topic Name
                    VStack(alignment: .leading, spacing: themeManager.spacing(.sm)) {
                        Text("Topic Name")
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.textSecondary))
                        TextField("Enter topic name", text: $topicName)
                            .textFieldStyle(.roundedBorder)
                            .font(themeManager.font(.body))
                    }

                    Divider()
                        .background(themeManager.color(.borderSubtle))

                    // Project Binding
                    VStack(alignment: .leading, spacing: themeManager.spacing(.md)) {
                        Text("Project Binding")
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.textSecondary))

                        if let currentPath = selectedProjectPath {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(themeManager.color(.accentPrimary))
                                Text(URL(fileURLWithPath: currentPath).lastPathComponent)
                                    .font(themeManager.font(.body))
                                    .foregroundColor(themeManager.color(.textPrimary))
                                Spacer()
                                Button("Unbind") {
                                    selectedProjectPath = nil
                                    showCreateNewField = false
                                }
                                .font(themeManager.font(.caption))
                                .foregroundColor(themeManager.color(.error))
                            }
                            .padding(themeManager.spacing(.sm))
                            .background(themeManager.color(.bgElevated))
                            .cornerRadius(themeManager.radius(.sm))

                            // Context files status (Mel Warning-4)
                            contextFilesSection(projectPath: currentPath)
                        } else {
                            Text("No project bound")
                                .font(themeManager.font(.caption))
                                .foregroundColor(themeManager.color(.textSecondary).opacity(0.7))
                                .padding(.vertical, themeManager.spacing(.xs))
                        }

                        // Project dropdown
                        if !availableProjects.isEmpty {
                            Picker("Select Project", selection: projectPathBinding) {
                                Text("None").tag("")
                                ForEach(availableProjects, id: \.self) { name in
                                    let fullPath = "/Users/openclaw/Projects/\(name)/"
                                    Text(name).tag(fullPath)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        // Create new project button / inline form
                        if showCreateNewField {
                            VStack(alignment: .leading, spacing: themeManager.spacing(.sm)) {
                                TextField("New project name", text: $newProjectName)
                                    .textFieldStyle(.roundedBorder)

                                HStack(spacing: themeManager.spacing(.md)) {
                                    Button("Cancel") {
                                        showCreateNewField = false
                                        newProjectName = ""
                                    }
                                    .font(themeManager.font(.caption))

                                    Button("Create & Bind") {
                                        createAndBindProject()
                                    }
                                    .font(themeManager.font(.caption))
                                    .disabled(newProjectName.trimmingCharacters(in: .whitespaces).isEmpty)
                                }
                            }
                            .padding(themeManager.spacing(.sm))
                            .background(themeManager.color(.bgElevated))
                            .cornerRadius(themeManager.radius(.sm))
                        } else {
                            Button {
                                showCreateNewField = true
                            } label: {
                                Label("Create New Project", systemImage: "folder.badge.plus")
                            }
                            .font(themeManager.font(.body))
                            .foregroundColor(themeManager.color(.accentPrimary))
                            .buttonStyle(.plain)
                        }

                        // Error display
                        if let error = errorMessage {
                            Text(error)
                                .font(themeManager.font(.caption))
                                .foregroundColor(themeManager.color(.error))
                                .padding(.vertical, themeManager.spacing(.xs))
                        }
                    }

                    Spacer()

                    // Save button
                    Button("Save Changes") {
                        saveTopic()
                    }
                    .font(themeManager.font(.subheading))
                    .frame(maxWidth: .infinity)
                    .padding(themeManager.spacing(.md))
                    .background(themeManager.color(.accentPrimary))
                    .foregroundColor(.white)
                    .cornerRadius(themeManager.radius(.md))
                    .disabled(topicName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(themeManager.spacing(.xl))
            }
            .background(themeManager.color(.bgSurface))
        }
        .frame(minWidth: 400, idealWidth: 420, maxWidth: 480, minHeight: 400, idealHeight: 500, maxHeight: 600)
        .background(themeManager.color(.bgSurface))
        .onAppear {
            topicName = topic.name
            selectedProjectPath = topic.projectPath
            availableProjects = ProjectDirectoryUtils.listProjectDirectories()
        }
    }

    private func createAndBindProject() {
        let rawName = newProjectName.trimmingCharacters(in: .whitespaces)
        guard !rawName.isEmpty else { return }

        do {
            let newPath = try ProjectScaffolder.scaffoldProject(named: rawName)
            selectedProjectPath = newPath
            showCreateNewField = false
            newProjectName = ""
            errorMessage = nil
            // Refresh available projects
            availableProjects = ProjectDirectoryUtils.listProjectDirectories()
        } catch let err as ProjectScaffoldError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = "Failed to create project: \(error.localizedDescription)"
        }
    }

    // MARK: - Context files section (Mel Warning-4)

    @ViewBuilder
    private func contextFilesSection(projectPath: String) -> some View {
        let statuses = ProjectContextReader.getFileStatuses(projectPath: projectPath)
        let hasStatusMd = statuses.contains { $0.filename == "STATUS.md" && $0.status != .missing }

        VStack(alignment: .leading, spacing: themeManager.spacing(.xs)) {
            Text("Context files")
                .font(themeManager.font(.caption))
                .foregroundColor(themeManager.color(.textSecondary))

            if !hasStatusMd {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text("STATUS.md not found — agent will have limited project context")
                        .font(themeManager.font(.caption))
                        .foregroundColor(.orange)
                }
                .accessibilityLabel("Warning: STATUS.md not found")
            }

            ForEach(statuses, id: \.filename) { file in
                HStack(spacing: themeManager.spacing(.sm)) {
                    Image(systemName: statusIcon(for: file.status))
                        .font(.system(size: 9))
                        .foregroundColor(statusColor(for: file.status))
                    Text(file.filename)
                        .font(themeManager.font(.caption))
                        .foregroundColor(themeManager.color(.textPrimary))
                    Spacer()
                    Text(formatFileSize(file.bytes))
                        .font(themeManager.font(.caption))
                        .foregroundColor(themeManager.color(.textSecondary))
                    if file.status == .truncated {
                        Text("(truncated)")
                            .font(themeManager.font(.caption))
                            .foregroundColor(themeManager.color(.textSecondary))
                    }
                }
                .accessibilityLabel("\(file.filename), \(file.status.rawValue), \(formatFileSize(file.bytes))")
                .accessibilityValue(file.status == .truncated ? "truncated" : "")
            }
        }
        .padding(themeManager.spacing(.sm))
        .background(themeManager.color(.bgElevated))
        .cornerRadius(themeManager.radius(.sm))
    }

    private func statusIcon(for status: ProjectContextReadResult.ProjectContextFileStatus.FileStatus) -> String {
        switch status {
        case .found: return "checkmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        case .truncated: return "exclamationmark.circle.fill"
        }
    }

    private func statusColor(for status: ProjectContextReadResult.ProjectContextFileStatus.FileStatus) -> Color {
        switch status {
        case .found: return .green
        case .missing: return .red.opacity(0.7)
        case .truncated: return .orange
        }
    }

    private func formatFileSize(_ bytes: Int) -> String {
        if bytes >= 1024 {
            return String(format: "%.1fKB", Double(bytes) / 1024.0)
        }
        return "\(bytes)B"
    }

    private func saveTopic() {
        let trimmedName = topicName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        var updatedTopic = topic
        updatedTopic.name = trimmedName

        do {
            try updatedTopic.setProjectPath(selectedProjectPath)
            onSave(updatedTopic)
            dismiss()
        } catch let err as TopicError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
