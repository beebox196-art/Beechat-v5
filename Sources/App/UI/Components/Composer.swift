import SwiftUI

/// Attachment type enum for the composer.
enum AttachmentType {
    case image
    case file
    case voiceNote
}

/// Message composer — clean input row only.
/// Enter = newline, Cmd+Enter = send, or click Send button.
/// Gateway status lives in GatewayStatusBar (top of detail pane), not here.
struct Composer: View {
    @Environment(ThemeManager.self) var themeManager

    @Bindable var viewModel: ComposerViewModel
    let onSend: () -> Void

    @State private var showAttachmentPicker = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            // Attachment button
            Button(action: { showAttachmentPicker = true }) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 24))
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .confirmationDialog("Attach", isPresented: $showAttachmentPicker) {
                Button("Photo") { /* Phase 4B */ }
                Button("File") { /* Phase 4B */ }
                Button("Voice Note") { viewModel.startRecording() }
            }

            // Text input — MacTextView (NSTextView wrapper) for auto-expand
            MacTextView(
                text: $viewModel.inputText,
                onSend: {
                    if viewModel.canSend {
                        onSend()
                    }
                }
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 36, maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .background(themeManager.color(.bgPanel))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Voice recording button
            Button(action: toggleRecording) {
                Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20))
                    .foregroundColor(viewModel.isRecording ? .red : themeManager.color(.textSecondary))
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .background(
                Circle()
                    .fill(viewModel.isRecording ? Color.red.opacity(0.1) : Color.clear)
            )
            .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Start recording")

            // Send button
            Button(action: { onSend() }) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20))
                    .foregroundColor(
                        viewModel.canSend
                            ? themeManager.color(.textOnAccent)
                            : themeManager.color(.textSecondary)
                    )
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .background(
                Circle()
                    .fill(
                        viewModel.canSend
                            ? themeManager.color(.accentPrimary)
                            : themeManager.color(.bgPanel)
                    )
            )
            .disabled(!viewModel.canSend)
            .help("Send message")
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(themeManager.color(.bgSurface))
    }

    private func toggleRecording() {
        if viewModel.isRecording {
            viewModel.stopRecording()
        } else {
            viewModel.startRecording()
        }
    }
}