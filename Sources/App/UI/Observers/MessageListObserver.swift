import SwiftUI
import BeeChatPersistence
import BeeChatSyncBridge

@MainActor
@Observable
final class MessageListObserver {
    var messages: [Message] = []        // The windowed slice shown in UI
    var sessionKey: String?
    var canLoadEarlier: Bool = false

    private var streamTask: Task<Void, Never>?
    private var allMessages: [Message] = []  // Full set from stream (up to 500)
    private var messageLimit: Int = 25

    func startObserving(syncBridge: SyncBridge, sessionKey: String) {
        streamTask?.cancel()
        self.sessionKey = sessionKey
        self.messageLimit = 25       // Reset on topic switch
        self.allMessages = []
        self.messages = []
        self.canLoadEarlier = false
        print("[MessageListObserver] 🐝 startObserving — sessionKey=\(sessionKey)")

        streamTask = Task { [weak self] in
            let stream = await syncBridge.messageStream(sessionKey: sessionKey)
            for await updatedMessages in stream {
                guard !Task.isCancelled else { return }
                print("[MessageListObserver] 🐝 Received \(updatedMessages.count) messages from stream — roles: \(updatedMessages.map { $0.role }.joined(separator: ","))")
                self?.setAllMessages(updatedMessages)
            }
            print("[MessageListObserver] 🐝 Stream ended for sessionKey=\(sessionKey)")
        }
    }

    /// Single entry point for both stream and local paths
    func setAllMessages(_ allMessages: [Message]) {
        // D2: Diff guard — skip update when data hasn't changed to prevent
        // SwiftUI LazyVStack churn from GRDB ValueObservation reference-only yields.
        // This is Path C of the 13 May 99% CPU hang root cause in
        // Docs/Status/DEBUG.md. A new array reference is yielded on every
        // streaming delta write even when the visible data is identical.
        guard messagesDiffer(self.allMessages, allMessages) else { return }
        self.allMessages = allMessages
        applyWindow()
    }

    /// Lightweight equality check for the diff guard. Compares by
    /// id + content + timestamp + role (the four fields the UI cares about
    /// for layout and rendering). Order-sensitive.
    private func messagesDiffer(_ lhs: [Message], _ rhs: [Message]) -> Bool {
        guard lhs.count == rhs.count else { return true }
        for (l, r) in zip(lhs, rhs) {
            if l.id != r.id || l.content != r.content || l.timestamp != r.timestamp || l.role != r.role {
                return true
            }
        }
        return false
    }

    /// Apply the display window to the full message set
    private func applyWindow() {
        let windowed = Array(allMessages.suffix(messageLimit))
        messages = windowed
        canLoadEarlier = allMessages.count > messageLimit
    }

    /// Load 25 more messages — no stream restart needed
    func loadEarlierMessages() {
        messageLimit += 25
        applyWindow()
    }

    func stopObserving() {
        streamTask?.cancel()
        streamTask = nil
        sessionKey = nil
        allMessages = []
        messages = []
        canLoadEarlier = false
    }

    nonisolated deinit {
    }
}