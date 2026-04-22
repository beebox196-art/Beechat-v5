import Foundation
import BeeChatPersistence

/// UI-layer view model wrapping Topic for sidebar display.
/// Derives from Topic (NOT Session), adds UI-only presentation fields.
/// Topic ordering: alphabetical by name, case-insensitive.
struct TopicViewModel: Identifiable, Hashable {
    let id: String          // = Topic.id
    var title: String       // = Topic.name
    var icon: String?       // UI-only: SF Symbol name, stored in UserDefaults
    var sessionKey: String? // gateway session key for sending/observing messages
    var lastActivityAt: Date?
    var unreadCount: Int

    init(from topic: Topic, icon: String? = nil) {
        self.id = topic.id
        self.title = topic.name
        self.icon = icon
        self.sessionKey = topic.sessionKey
        self.lastActivityAt = topic.lastActivityAt
        self.unreadCount = topic.unreadCount
    }

    /// Sorted list of TopicViewModels — alphabetical by title, case-insensitive.
    static func sorted(from topics: [Topic]) -> [TopicViewModel] {
        topics
            .map { TopicViewModel(from: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}