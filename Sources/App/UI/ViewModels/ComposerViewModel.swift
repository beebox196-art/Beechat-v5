import SwiftUI
import BeeChatSyncBridge

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
            print("[ComposerViewModel] Send failed: \(error)")
        }
    }

    func startRecording() {
        isRecording = true
    }

    func stopRecording() {
        isRecording = false
    }
}