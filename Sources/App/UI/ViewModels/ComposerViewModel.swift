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

    func configure(syncBridge: SyncBridge?, messageViewModel: MessageViewModel) {
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
            // Don't restore text — the message was already persisted locally.
            // If the RPC failed, the message appears in the list but wasn't delivered.
            // A future reconciliation pass will retry failed deliveries.
            print("[ComposerViewModel] Send RPC failed (message persisted locally): \(error)")
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