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

    var selectedTopic: TopicViewModel? {
        topics.first { $0.id == selectedTopicId }
    }

    var messages: [Message] {
        messageListObserver.messages
    }

    /// Start gateway-dependent observation (session list via SyncBridge stream).
    /// Note: Session list is now driven by the local GRDB ValueObservation in MainWindow,
    /// so this only stores the syncBridge reference and starts gateway message streams.
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
        guard let key = selectedTopicId else { return }
        startLocalMessageObservation(for: key)
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

        // Start message observation for selected topic
        if let key = selectedTopicId, key != messageListObserver.sessionKey {
            if let syncBridge {
                messageListObserver.startObserving(syncBridge: syncBridge, sessionKey: key)
            } else {
                startLocalMessageObservation(for: key)
            }
        }
    }

    /// Select a topic by id.
    func selectTopic(id: String) {
        guard topics.contains(where: { $0.id == id }) else { return }
        selectedTopicId = id
        if let syncBridge = syncBridge {
            messageListObserver.startObserving(syncBridge: syncBridge, sessionKey: id)
        } else {
            startLocalMessageObservation(for: id)
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
        } else {
            startLocalMessageObservation(for: topic.id)
        }
    }

    /// Remove a topic by id (from manual delete).
    func removeTopic(id: String) {
        topics.removeAll { $0.id == id }
        if selectedTopicId == id {
            selectedTopicId = topics.first?.id
            if let key = selectedTopicId {
                if let syncBridge = syncBridge {
                    messageListObserver.startObserving(syncBridge: syncBridge, sessionKey: key)
                } else {
                    startLocalMessageObservation(for: key)
                }
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