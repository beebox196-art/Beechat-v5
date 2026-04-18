import SwiftUI
import BeeChatSyncBridge

/// View model for the message composer.
/// Manages input text, attachments, and send action.
@MainActor
@Observable
final class ComposerViewModel {
    var inputText: String = ""
    var isRecording: Bool = false

    private weak var syncBridge: SyncBridge?
    private weak var messageViewModel: MessageViewModel?

    func configure(syncBridge: SyncBridge, messageViewModel: MessageViewModel) {
        self.syncBridge = syncBridge
        self.messageViewModel = messageViewModel
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func send() async {
        guard canSend else { return }
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        do {
            try await messageViewModel?.sendMessage(text: text)
        } catch {
            // Restore text on failure so user doesn't lose their message
            inputText = text
            print("[ComposerViewModel] Send failed: \(error)")
        }
    }

    func startRecording() {
        isRecording = true
        // Voice recording implementation deferred to Phase 4B
    }

    func stopRecording() {
        isRecording = false
        // Voice recording processing deferred to Phase 4B
    }
}