import Foundation
import BeeChatPersistence
import BeeChatSyncBridge

/// UI-layer view model wrapping Topic for sidebar display.
/// Derives from Topic (NOT Session), adds UI-only presentation fields.
/// Topic ordering: alphabetical by name, case-insensitive.
@Observable
final class TopicViewModel: Identifiable {
    let id: String          // = Topic.id
    var title: String       // = Topic.name
    var icon: String?       // UI-only: SF Symbol name, stored in UserDefaults
    var sessionKey: String? // gateway session key for sending/observing messages
    var lastActivityAt: Date?
    var unreadCount: Int
    var messageCount: Int
    var projectPath: String?  // Phase 1 — sourced from Topic.metadataJSON

    // Phase 2 — topic summary save state
    var isSaving = false
    var saveStatus: TopicSaveStatus = .idle

    init(from topic: Topic, icon: String? = nil) {
        self.id = topic.id
        self.title = topic.name
        self.icon = icon
        self.sessionKey = topic.sessionKey
        self.lastActivityAt = topic.lastActivityAt
        self.unreadCount = topic.unreadCount
        self.messageCount = topic.messageCount
        self.projectPath = topic.projectPath
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

    /// Phase 2.1a: Save topic summary via the extraction + write pipeline.
    ///
    /// Called from SessionRow's context menu. Updates `isSaving` and `saveStatus`
    /// so the UI can show transient status.
    ///
    /// - Parameter bridge: The SyncBridge instance (passed from the view layer).
    func saveTopicSummary(bridge: SyncBridge) async {
        isSaving = true
        saveStatus = .saving

        let result = await bridge.triggerTopicSummary(topicId: id)

        switch result {
        case .success:
            saveStatus = .success
        case .noContent:
            saveStatus = .empty
        case .timedOut:
            saveStatus = .timedOut
        case .failed(let reason):
            saveStatus = .failed(reason: reason)
        }

        isSaving = false

        // Auto-reset status after a delay (success=2s, empty=2s, timedOut=4s, error=4s)
        let delay: UInt64
        switch saveStatus {
        case .success, .empty:
            delay = 2_000_000_000 // 2 seconds
        case .timedOut, .failed:
            delay = 4_000_000_000 // 4 seconds — persists as tooltip
        case .idle, .saving:
            delay = 0
        }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
            // Don't reset failed/timedOut status — it persists until retry/success/topic change
            if case .success = saveStatus {
                saveStatus = .idle
            } else if case .empty = saveStatus {
                saveStatus = .idle
            }
        }
    }
}

/// Transient save status for the topic summary UI.
enum TopicSaveStatus: Equatable {
    case idle
    case saving
    case success
    case empty           // No durable content to save
    case timedOut        // Extraction timed out (180s) — Phase 2.1a
    case failed(reason: String)
}
