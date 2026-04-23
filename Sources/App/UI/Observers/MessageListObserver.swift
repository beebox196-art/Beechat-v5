import SwiftUI
import BeeChatPersistence
import BeeChatSyncBridge

@MainActor
@Observable
final class MessageListObserver {
    var messages: [Message] = []
    var sessionKey: String?

    private var streamTask: Task<Void, Never>?

    func startObserving(syncBridge: SyncBridge, sessionKey: String) {
        streamTask?.cancel()
        self.sessionKey = sessionKey
        self.messages = []
        print("[MessageListObserver] 🐝 startObserving — sessionKey=\(sessionKey)")

        streamTask = Task { [weak self] in
            let stream = await syncBridge.messageStream(sessionKey: sessionKey)
            for await messages in stream {
                guard !Task.isCancelled else { return }
                print("[MessageListObserver] 🐝 Received \(messages.count) messages from stream — roles: \(messages.map { $0.role }.joined(separator: ","))")
                self?.messages = messages
            }
            print("[MessageListObserver] 🐝 Stream ended for sessionKey=\(sessionKey)")
        }
    }

    func updateMessages(_ messages: [Message]) {
        self.messages = messages
    }

    func stopObserving() {
        streamTask?.cancel()
        streamTask = nil
        sessionKey = nil
        messages = []
    }

    nonisolated deinit {
    }
}