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

    func startRecording() {
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }
}