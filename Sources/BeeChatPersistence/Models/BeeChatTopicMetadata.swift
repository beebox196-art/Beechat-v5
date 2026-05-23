import Foundation

/// Typed representation of `pluginExtensions.beechat.metadata` from the gateway.
/// Used to carry topic-specific state (archive status, project binding, topic ID)
/// across devices via the gateway's session model.
public struct BeeChatTopicMetadata: Codable, Sendable, Equatable {
    /// UUID that MUST match the suffix of the session key (`agent:main:<topicId.lowercased()>`).
    public let topicId: String
    /// Whether the topic has been archived on the master device (Mac).
    public let isArchived: Bool
    /// Optional project/workspace path bound to this topic.
    public let projectPath: String?
    /// ISO 8601 timestamp of the last metadata update from the master device.
    public let updatedAt: String

    public init(
        topicId: String,
        isArchived: Bool = false,
        projectPath: String? = nil,
        updatedAt: String
    ) {
        self.topicId = topicId
        self.isArchived = isArchived
        self.projectPath = projectPath
        self.updatedAt = updatedAt
    }
}