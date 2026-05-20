import SwiftUI
import BeeChatSyncBridge

@MainActor
@Observable
final class ComposerViewModel {
    var inputText: String = ""
    var isRecording: Bool = false
    /// Brief feedback string shown to the user (e.g. "Still sending..."). Clears automatically.
    var sendFeedback: String?
    var onMessageSent: (() -> Void)?

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
        // Don't clear inputText yet — only clear on successful send
        BeeChatLogger.log("[ThinkingBee] ComposerViewModel.send() — about to call onMessageSent")
        onMessageSent?()
        BeeChatLogger.log("[ThinkingBee] ComposerViewModel.send() — onMessageSent callback returned")
        do {
            try await messageViewModel?.sendMessage(text: text)
            BeeChatLogger.log("[ThinkingBee] sendMessage RPC completed successfully")
            // Send succeeded — clear the composer
            inputText = ""
        } catch SyncBridgeError.concurrentSendInProgress {
            // Don't clear input — preserve the text so the user can retry
            BeeChatLogger.log("[ThinkingBee] sendMessage — concurrent send in progress, preserving composer text")
            showFeedback("Still sending...")
        } catch {
            BeeChatLogger.log("[ThinkingBee] Send failed: \(error)")
            // On other errors, also preserve the text
            showFeedback("Send failed — please retry")
        }
    }

    /// Show brief feedback that auto-clears after 3 seconds
    private func showFeedback(_ message: String) {
        sendFeedback = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if sendFeedback == message {
                sendFeedback = nil
            }
        }
    }

    func startRecording() {
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }
}