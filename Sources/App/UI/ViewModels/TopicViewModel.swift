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
    var messageCount: Int
    var projectPath: String?  // NEW — sourced from Topic.metadataJSON (Phase 1)

    init(from topic: Topic, icon: String? = nil) {
        self.id = topic.id
        self.title = topic.name
        self.icon = icon
        self.sessionKey = topic.sessionKey
        self.lastActivityAt = topic.lastActivityAt
        self.unreadCount = topic.unreadCount
        self.messageCount = topic.messageCount
        self.projectPath = topic.projectPath  // NEW
    }

    // Explicit Hashable: identity-only (Kieran Critical-3)
    // Adding projectPath would silently change synthesized equality/hash,
    // breaking any Set/Dict usage keyed by TopicViewModel.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TopicViewModel, rhs: TopicViewModel) -> Bool {
        lhs.id == rhs.id
    }

    /// Sorted list of TopicViewModels — alphabetical by title, case-insensitive.
    static func sorted(from topics: [Topic]) -> [TopicViewModel] {
        topics
            .map { TopicViewModel(from: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}