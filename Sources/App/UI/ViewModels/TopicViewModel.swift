import SwiftUI
import BeeChatPersistence

/// UI-layer view model wrapping Session for topic display.
/// Derives from Session, adds UI-only presentation fields.
/// Topic ordering: alphabetical by title, case-insensitive.
@Observable
final class TopicViewModel: Identifiable {
    let id: String          // = Session.id (session key)
    var title: String       // = Session.title ?? "Untitled"
    var icon: String?       // UI-only: SF Symbol name, stored in UserDefaults
    var lastMessageAt: Date?
    var unreadCount: Int

    init(from session: Session, icon: String? = nil) {
        self.id = session.id
        self.title = session.title ?? "Untitled"
        self.icon = icon
        self.lastMessageAt = session.lastMessageAt
        self.unreadCount = session.unreadCount
    }

    /// Update from a fresh Session object (keeps icon intact).
    func update(from session: Session) {
        self.title = session.title ?? "Untitled"
        self.lastMessageAt = session.lastMessageAt
        self.unreadCount = session.unreadCount
    }

    /// Sorted list of TopicViewModels — alphabetical by title, case-insensitive.
    static func sorted(from sessions: [Session]) -> [TopicViewModel] {
        sessions
            .map { TopicViewModel(from: $0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}