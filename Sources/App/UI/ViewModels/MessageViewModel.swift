import SwiftUI
import BeeChatPersistence
import BeeChatSyncBridge

/// View model for the message list.
/// Reads from MessageListObserver (GRDB-backed), NOT from SyncBridge directly.
@MainActor
@Observable
final class MessageViewModel {
    var topics: [TopicViewModel] = []
    var selectedTopicId: String?

    private let sessionListObserver = SessionListObserver()
    private let messageListObserver = MessageListObserver()
    private weak var syncBridge: SyncBridge?

    var selectedTopic: TopicViewModel? {
        topics.first { $0.id == selectedTopicId }
    }

    var messages: [Message] {
        messageListObserver.messages
    }

    func start(syncBridge: SyncBridge) {
        self.syncBridge = syncBridge
        sessionListObserver.startObserving(syncBridge: syncBridge)
    }

    func stop() {
        sessionListObserver.stopObserving()
        messageListObserver.stopObserving()
        syncBridge = nil
    }

    /// Called when session list changes — updates topic list.
    func updateTopics(from sessions: [Session]) {
        // Preserve selection and icons
        let previousIcons = Dictionary(uniqueKeysWithValues: topics.compactMap { t -> (String, String)? in
            guard let icon = t.icon else { return nil }
            return (t.id, icon)
        })
        let previousSelection = selectedTopicId

        topics = TopicViewModel.sorted(from: sessions)

        // Restore icons
        for i in topics.indices {
            if let icon = previousIcons[topics[i].id] {
                topics[i].icon = icon
            }
        }

        // Restore selection (or pick first if lost)
        if let prev = previousSelection, topics.contains(where: { $0.id == prev }) {
            selectedTopicId = prev
        } else {
            selectedTopicId = topics.first?.id
        }

        // If selection changed, start observing messages for new session
        if let key = selectedTopicId, key != messageListObserver.sessionKey {
            messageListObserver.startObserving(syncBridge: syncBridge!, sessionKey: key)
        }
    }

    /// Select a topic by id.
    func selectTopic(id: String) {
        guard topics.contains(where: { $0.id == id }) else { return }
        selectedTopicId = id
        if let syncBridge = syncBridge {
            messageListObserver.startObserving(syncBridge: syncBridge, sessionKey: id)
        }
    }

    /// Send a message via SyncBridge (write path — direct RPC call is correct).
    func sendMessage(text: String) async throws {
        guard let key = selectedTopicId, let bridge = syncBridge else { return }
        _ = try await bridge.sendMessage(sessionKey: key, text: text)
    }

    /// Fetch history for current topic.
    func fetchHistory() async throws {
        guard let key = selectedTopicId, let bridge = syncBridge else { return }
        _ = try await bridge.fetchHistory(sessionKey: key)
    }

    /// Add a locally-created topic (from manual create).
    func addLocalTopic(_ session: Session) {
        let topic = TopicViewModel(from: session)
        topics.append(topic)
        topics.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        selectedTopicId = topic.id
        if let syncBridge = syncBridge {
            messageListObserver.startObserving(syncBridge: syncBridge, sessionKey: topic.id)
        }
    }

    /// Remove a topic by id (from manual delete).
    func removeTopic(id: String) {
        topics.removeAll { $0.id == id }
        if selectedTopicId == id {
            selectedTopicId = topics.first?.id
            if let key = selectedTopicId, let syncBridge = syncBridge {
                messageListObserver.startObserving(syncBridge: syncBridge, sessionKey: key)
            }
        }
    }
}