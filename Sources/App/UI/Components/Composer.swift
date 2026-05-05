import SwiftUI
import AppKit
import ChatField

/// Message composer — ChatField with accessory buttons.
struct Composer: View {
    @Environment(ThemeManager.self) var themeManager

    @Bindable var viewModel: ComposerViewModel
    let onSend: () -> Void

    @State private var showAttachmentPicker = false
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        ChatField("Type a message...", text: $viewModel.inputText) {
            // ChatField's internal macOS_action only checks for Shift+Enter.
            // Option+Return also inserts a newline (macOS convention).
            if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                viewModel.inputText += "\n"
                return
            }
            if viewModel.canSend {
                onSend()
                isTextFieldFocused = true
            }
        } leadingAccessory: {
            Button(action: { showAttachmentPicker = true }) {
                Image(systemName: "plus.circle")
                    .font(themeManager.font(.display))
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .confirmationDialog("Attach", isPresented: $showAttachmentPicker) {
                Button("Photo") { /* Phase 4B */ }
                Button("File") { /* Phase 4B */ }
                Button("Voice Note") { viewModel.startRecording() }
            }
            .accessibilityLabel("Attach file")
            .accessibilityHint("Add an attachment")
        } trailingAccessory: {
            HStack(spacing: 8) {
                Button(action: toggleRecording) {
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "mic.fill")
                        .font(themeManager.font(.heading))
                        .foregroundColor(viewModel.isRecording ? themeManager.color(.error) : themeManager.color(.textSecondary))
                }
                .buttonStyle(.borderless)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(viewModel.isRecording ? themeManager.color(.error).opacity(0.1) : Color.clear)
                )
                .accessibilityLabel(viewModel.isRecording ? "Stop recording" : "Start recording")

                Button(action: { onSend() }) {
                    Image(systemName: "paperplane.fill")
                        .font(themeManager.font(.heading))
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
                .accessibilityHint("Send your message to the AI")
            }
        }
        .focused($isTextFieldFocused)
        .textFieldStyle(BeeChatChatFieldStyle())
        .frame(maxWidth: .infinity)
        .frame(minHeight: 36, maxHeight: 160)
        .fixedSize(horizontal: false, vertical: true)
        .background(themeManager.color(.bgPanel))
        .clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.md), style: .continuous))
        .accessibilityLabel("Message input")
        .accessibilityHint("Type your message here")
        .padding(.horizontal, themeManager.spacing(.lg))
        .padding(.vertical, themeManager.spacing(.md))
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