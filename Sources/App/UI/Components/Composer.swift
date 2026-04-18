import SwiftUI

/// Attachment type enum for the composer.
enum AttachmentType {
    case image
    case file
    case voiceNote
}

/// Message composer — text input + send + attach + voice.
/// Uses MacTextView (AutoSizingTextView wrapper) for reliable macOS multiline input.
struct Composer: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(AppState.self) var appState

    @Bindable var viewModel: ComposerViewModel
    let onSend: () -> Void

    @State private var showAttachmentPicker = false

    private var isOffline: Bool {
        appState.connectionState != .connected
    }

    var body: some View {
        VStack(spacing: 4) {
            // Offline warning bar
            if isOffline {
                Text("No gateway connection")
                    .font(themeManager.font(.caption))
                    .foregroundColor(themeManager.color(.textSecondary))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }

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

                // Text input — AutoSizingTextView wrapper for reliable macOS auto-expand
                MacTextView(text: $viewModel.inputText, onSend: sendMessageIfReady)
                    .frame(minHeight: 40, maxHeight: 160)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
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
                .disabled(!viewModel.canSend || isOffline)
                .help(isOffline ? "No gateway connection" : "Send message")
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(themeManager.color(.bgSurface))
    }

    /// Called by MacTextView's Enter key and by the send button
    private func sendMessageIfReady() {
        guard viewModel.canSend, !isOffline else { return }
        onSend()
    }

    private func toggleRecording() {
        if viewModel.isRecording {
            viewModel.stopRecording()
        } else {
            viewModel.startRecording()
        }
    }
}