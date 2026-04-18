import SwiftUI
import BeeChatPersistence
import BeeChatSyncBridge

/// UI-layer observer for message list changes per session.
/// Wraps the SyncBridge MessageObserver AsyncStream into @Observable state.
@MainActor
@Observable
final class MessageListObserver {
    var messages: [Message] = []
    var sessionKey: String?

    private var streamTask: Task<Void, Never>?

    func startObserving(syncBridge: SyncBridge, sessionKey: String) {
        // Cancel any existing observation
        streamTask?.cancel()
        self.sessionKey = sessionKey
        self.messages = []

        streamTask = Task { [weak self] in
            let stream = await syncBridge.messageStream(sessionKey: sessionKey)
            for await messages in stream {
                guard !Task.isCancelled else { return }
                self?.messages = messages
            }
        }
    }

    func stopObserving() {
        streamTask?.cancel()
        streamTask = nil
        sessionKey = nil
        messages = []
    }

    nonisolated deinit {
        // Can't access MainActor properties in deinit, but Task.cancel() is thread-safe.
        // Call stopObserving() before deallocation to properly cancel streams.
    }
}