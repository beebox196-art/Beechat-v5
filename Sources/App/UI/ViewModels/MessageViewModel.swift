import SwiftUI
import BeeChatPersistence
import BeeChatSyncBridge
import GRDB

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

    func start(syncBridge: SyncBridge) {
        self.syncBridge = syncBridge
    }

    func stop() {
        messageListObserver.stopObserving()
        localMessageCancellable?.cancel()
        localMessageCancellable = nil
        syncBridge = nil
    }

    func startLocalMessageObservation() {
        guard let topicId = selectedTopicId else { return }
        startLocalMessageObservation(for: topicId)
    }

    func startGatewayMessageObservation(sessionKey: String) {
        guard let bridge = syncBridge else { return }
        localMessageCancellable?.cancel()
        localMessageCancellable = nil
        messageListObserver.startObserving(syncBridge: bridge, sessionKey: sessionKey)
    }

    func updateTopics(from topics: [Topic]) {
        let previousIcons = Dictionary(uniqueKeysWithValues: self.topics.compactMap { t -> (String, String)? in
            guard let icon = t.icon else { return nil }
            return (t.id, icon)
        })
        let previousSelection = selectedTopicId

        self.topics = TopicViewModel.sorted(from: topics)

        for i in self.topics.indices {
            if let icon = previousIcons[self.topics[i].id] {
                self.topics[i].icon = icon
            }
        }

        if let prev = previousSelection, self.topics.contains(where: { $0.id == prev }) {
            selectedTopicId = prev
        } else {
            selectedTopicId = self.topics.first?.id
        }

        startObservationForSelectedTopic()
    }

    func selectTopic(id: String) {
        guard topics.contains(where: { $0.id == id }) else { return }
        BeeChatLogger.log("[ThinkingBee] selectTopic — id=\(id)")
        selectedTopicId = id
        startObservationForSelectedTopic()
    }

    func sendMessage(text: String) async throws {
        guard let topicId = selectedTopicId else {
            BeeChatLogger.log("[ThinkingBee] sendMessage ABORTED — no selectedTopicId")
            return
        }

        let sessionKey: String
        if let vmKey = topics.first(where: { $0.id == topicId })?.sessionKey, !vmKey.isEmpty {
            sessionKey = vmKey
        } else if let resolvedKey = try topicRepo.resolveSessionKey(topicId: topicId), !resolvedKey.isEmpty {
            sessionKey = resolvedKey
        } else {
            sessionKey = topicId
        }

        BeeChatLogger.log("[ThinkingBee] MessageViewModel.sendMessage — topicId=\(topicId), sessionKey=\(sessionKey), text=\(text.prefix(50))")

        let userMessage = Message(
            id: UUID().uuidString,
            sessionId: sessionKey,
            role: "user",
            content: text,
            timestamp: Date()
        )
        try DatabaseManager.shared.write { db in
            var msg = userMessage
            try msg.insert(db)
        }

        guard let bridge = syncBridge else {
            BeeChatLogger.log("[ThinkingBee] sendMessage ABORTED — no syncBridge")
            return
        }
        BeeChatLogger.log("[ThinkingBee] sendMessage — calling bridge.sendMessage for sessionKey=\(sessionKey)")
        _ = try await bridge.sendMessage(sessionKey: sessionKey, text: text)
        BeeChatLogger.log("[ThinkingBee] sendMessage — bridge.sendMessage RETURNED for sessionKey=\(sessionKey)")

        if sessionKey == topicId {
            try topicRepo.updateSessionKey(topicId: topicId, sessionKey: sessionKey)
            try topicRepo.saveBridge(topicId: topicId, sessionKey: sessionKey)
            if let idx = topics.firstIndex(where: { $0.id == topicId }) {
                topics[idx].sessionKey = sessionKey
            }
        }
    }

    func fetchHistory() async throws {
        guard let topicId = selectedTopicId else { return }
        let sessionKey = (try topicRepo.resolveSessionKey(topicId: topicId)) ?? topicId
        guard let bridge = syncBridge else { return }
        _ = try await bridge.fetchHistory(sessionKey: sessionKey)
    }

    func addLocalTopic(_ topic: Topic) {
        let vm = TopicViewModel(from: topic)
        topics.append(vm)
        topics.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        selectedTopicId = topic.id
        startObservationForSelectedTopic()
    }

    func removeTopic(id: String) {
        topics.removeAll { $0.id == id }
        if selectedTopicId == id {
            selectedTopicId = topics.first?.id
            startObservationForSelectedTopic()
        }
    }


    private func startObservationForSelectedTopic() {
        guard let topicId = selectedTopicId else { return }

        let sessionKey: String
        if let vmKey = topics.first(where: { $0.id == topicId })?.sessionKey, !vmKey.isEmpty {
            sessionKey = vmKey
        } else {
            do {
                if let resolvedKey = try topicRepo.resolveSessionKey(topicId: topicId), !resolvedKey.isEmpty {
                    sessionKey = resolvedKey
                } else {
                    sessionKey = topicId
                }
            } catch {
                print("[MessageViewModel] Failed to resolve session key: \(error)")
                sessionKey = topicId
            }
        }

        if sessionKey != messageListObserver.sessionKey {
            if let syncBridge = syncBridge {
                messageListObserver.startObserving(syncBridge: syncBridge, sessionKey: sessionKey)
            } else {
                startLocalMessageObservation(for: sessionKey)
            }
        }
    }


    private func startLocalMessageObservation(for sessionKey: String) {
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
                    BeeChatLogger.log("[ThinkingBee] Local message observation error: \(error)")
                },
                onChange: { [weak self] messages in
                    self?.messageListObserver.updateMessages(messages)
                }
            )
        } catch {
            BeeChatLogger.log("[ThinkingBee] Failed to start local message observation: \(error)")
        }
    }
}