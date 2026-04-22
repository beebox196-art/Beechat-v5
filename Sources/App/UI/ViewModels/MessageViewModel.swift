import SwiftUI
import BeeChatPersistence
import BeeChatSyncBridge
import GRDB

/// View model for the message list.
/// Reads from MessageListObserver (GRDB-backed), NOT from SyncBridge directly.
@MainActor
@Observable
final class MessageViewModel {
    var topics: [TopicViewModel] = []
    var selectedTopicId: String?

    private let messageListObserver = MessageListObserver()
    private weak var syncBridge: SyncBridge?
    private var localMessageCancellable: DatabaseCancellable?
    private let topicRepo = TopicRepository()

    var selectedTopic: TopicViewModel? {
        topics.first { $0.id == selectedTopicId }
    }

    var messages: [Message] {
        messageListObserver.messages
    }

    /// Start gateway-dependent observation (session list via SyncBridge stream).
    /// Note: Session list is now driven by the local GRDB ValueObservation on
    /// the topics table in MainWindow, so this only stores the syncBridge reference.
    func start(syncBridge: SyncBridge) {
        self.syncBridge = syncBridge
    }

    func stop() {
        messageListObserver.stopObserving()
        localMessageCancellable?.cancel()
        localMessageCancellable = nil
        syncBridge = nil
    }

    /// Start local GRDB message observation for the currently selected topic.
    /// This works without a gateway connection — reads directly from the database.
    func startLocalMessageObservation() {
        guard let topicId = selectedTopicId else { return }
        startLocalMessageObservation(for: topicId)
    }

    /// Start gateway message observation for a specific session.
    /// Switches from local GRDB observation to the SyncBridge AsyncStream.
    func startGatewayMessageObservation(sessionKey: String) {
        guard let bridge = syncBridge else { return }
        // Cancel local observation — gateway stream takes over
        localMessageCancellable?.cancel()
        localMessageCancellable = nil
        messageListObserver.startObserving(syncBridge: bridge, sessionKey: sessionKey)
    }

    /// Called when topic list changes — updates topic list from Topic models.
    func updateTopics(from topics: [Topic]) {
        // Preserve selection and icons
        let previousIcons = Dictionary(uniqueKeysWithValues: self.topics.compactMap { t -> (String, String)? in
            guard let icon = t.icon else { return nil }
            return (t.id, icon)
        })
        let previousSelection = selectedTopicId

        self.topics = TopicViewModel.sorted(from: topics)

        // Restore icons
        for i in self.topics.indices {
            if let icon = previousIcons[self.topics[i].id] {
                self.topics[i].icon = icon
            }
        }

        // Restore selection (or pick first if lost)
        if let prev = previousSelection, self.topics.contains(where: { $0.id == prev }) {
            selectedTopicId = prev
        } else {
            selectedTopicId = self.topics.first?.id
        }

        // Start message observation for selected topic
        startObservationForSelectedTopic()
    }

    /// Select a topic by id.
    func selectTopic(id: String) {
        guard topics.contains(where: { $0.id == id }) else { return }
        selectedTopicId = id
        startObservationForSelectedTopic()
    }

    /// Send a message via SyncBridge (write path — direct RPC call is correct).
    /// Resolves the topic's session key before sending.
    /// If the topic has no session key yet, the send creates a gateway session
    /// and we record the mapping afterwards.
    func sendMessage(text: String) async throws {
        guard let topicId = selectedTopicId else { return }

        // Resolve session key for this topic
        let sessionKey: String
        if let vmKey = topics.first(where: { $0.id == topicId })?.sessionKey, !vmKey.isEmpty {
            sessionKey = vmKey
        } else if let resolvedKey = try? topicRepo.resolveSessionKey(topicId: topicId), !resolvedKey.isEmpty {
            sessionKey = resolvedKey
        } else {
            // No session key yet — use the topic ID as the session key.
            // The gateway will create a new session when we send the first message.
            // We'll update the topic with the actual session key afterwards.
            sessionKey = topicId
        }

        // Persist user message locally for immediate display
        let userMessage = Message(
            id: UUID().uuidString,
            sessionId: sessionKey,
            role: "user",
            content: text,
            timestamp: Date()
        )
        do {
            try DatabaseManager.shared.write { db in
                var msg = userMessage
                try msg.insert(db)
            }
        } catch {
            print("[MessageViewModel] Failed to persist user message: \(error)")
        }

        // Send via RPC if gateway is connected
        guard let bridge = syncBridge else { return }
        _ = try await bridge.sendMessage(sessionKey: sessionKey, text: text)

        // If this was a new session, update the topic with the session key
        if sessionKey == topicId {
            do {
                try topicRepo.updateSessionKey(topicId: topicId, sessionKey: sessionKey)
                try topicRepo.saveBridge(topicId: topicId, sessionKey: sessionKey)
                // Update the in-memory TopicViewModel
                if let idx = topics.firstIndex(where: { $0.id == topicId }) {
                    topics[idx].sessionKey = sessionKey
                }
            } catch {
                print("[MessageViewModel] Failed to update topic session key: \(error)")
            }
        }
    }

    /// Fetch history for current topic.
    func fetchHistory() async throws {
        guard let topicId = selectedTopicId else { return }
        let sessionKey = (try? topicRepo.resolveSessionKey(topicId: topicId)) ?? topicId
        guard let bridge = syncBridge else { return }
        _ = try await bridge.fetchHistory(sessionKey: sessionKey)
    }

    /// Add a locally-created topic (from manual create).
    func addLocalTopic(_ topic: Topic) {
        let vm = TopicViewModel(from: topic)
        topics.append(vm)
        topics.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        selectedTopicId = topic.id
        startObservationForSelectedTopic()
    }

    /// Remove a topic by id (from manual delete).
    func removeTopic(id: String) {
        topics.removeAll { $0.id == id }
        if selectedTopicId == id {
            selectedTopicId = topics.first?.id
            startObservationForSelectedTopic()
        }
    }

    // MARK: - Private helpers

    /// Start message observation for the currently selected topic.
    /// Resolves the session key from the topic and observes messages keyed by that session key.
    private func startObservationForSelectedTopic() {
        guard let topicId = selectedTopicId else { return }

        // Resolve session key for message observation
        let sessionKey: String
        if let vmKey = topics.first(where: { $0.id == topicId })?.sessionKey, !vmKey.isEmpty {
            sessionKey = vmKey
        } else if let resolvedKey = try? topicRepo.resolveSessionKey(topicId: topicId), !resolvedKey.isEmpty {
            sessionKey = resolvedKey
        } else {
            // No session key — try observing by topic id (may have no messages yet)
            sessionKey = topicId
        }

        if sessionKey != messageListObserver.sessionKey {
            if let syncBridge = syncBridge {
                messageListObserver.startObserving(syncBridge: syncBridge, sessionKey: sessionKey)
            } else {
                startLocalMessageObservation(for: sessionKey)
            }
        }
    }

    // MARK: - Local GRDB Message Observation

    /// Start a local GRDB ValueObservation for messages in a given session.
    /// Used when there's no gateway connection — reads directly from the database.
    private func startLocalMessageObservation(for sessionKey: String) {
        // Cancel any existing local observation
        localMessageCancellable?.cancel()

        let observation = ValueObservation.tracking { db in
            try Message
                .filter(Column("sessionId") == sessionKey)
                .order(Column("timestamp").asc)
                .limit(500)
                .fetchAll(db)
        }

        do {
            let writer = try DatabaseManager.shared.writer
            localMessageCancellable = observation.start(
                in: writer,
                scheduling: .mainActor,
                onError: { error in
                    print("[MessageViewModel] Local message observation error: \(error)")
                },
                onChange: { [weak self] messages in
                    self?.messageListObserver.updateMessages(messages)
                }
            )
        } catch {
            print("[MessageViewModel] Failed to start local message observation: \(error)")
        }
    }
}