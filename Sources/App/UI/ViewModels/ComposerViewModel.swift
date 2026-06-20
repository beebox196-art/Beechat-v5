import SwiftUI
import BeeChatSyncBridge

@MainActor
@Observable
final class ComposerViewModel {
    var inputText: String = ""
    var isRecording: Bool = false
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
        inputText = ""
        BeeChatLogger.log("[ThinkingBee] ComposerViewModel.send() — about to call onMessageSent")
        onMessageSent?()
        BeeChatLogger.log("[ThinkingBee] ComposerViewModel.send() — onMessageSent callback returned")
        do {
            try await messageViewModel?.sendMessage(text: text)
            BeeChatLogger.log("[ThinkingBee] sendMessage RPC completed successfully")
        } catch {
            BeeChatLogger.log("[ThinkingBee] Send failed: \(error)")
        }
    }

    /// Sends a pre-constructed text payload (e.g. `/research` command) through the
    /// existing send chain — same path as `send()` but without touching `inputText`.
    /// Preserves thinking indicator (.thinking → .streaming) and onMessageSent callback.
    func sendPayload(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        BeeChatLogger.log("[ThinkingBee] ComposerViewModel.sendPayload — sending research payload")
        onMessageSent?()
        Task {
            do {
                try await messageViewModel?.sendMessage(text: trimmed)
                BeeChatLogger.log("[ThinkingBee] sendPayload sendMessage completed")
            } catch {
                BeeChatLogger.log("[ThinkingBee] sendPayload failed: \(error)")
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