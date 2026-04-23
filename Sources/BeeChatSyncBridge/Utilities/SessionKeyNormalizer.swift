import Foundation
import BeeChatPersistence

// MARK: - Session Key Normalization

/// Centralises all gateway session-key handling logic.
/// Gateway keys look like "agent:main:<uuid>" (lowercase). Local topic IDs
/// are the original UUID (case may differ). This struct encapsulates the
/// prefix stripping and suffix matching so it isn't copy-pasted across
/// `SyncBridge`, `Reconciler`, and `EventRouter`.
public struct SessionKeyNormalizer: Sendable {
    public static let prefix = "agent:main:"

    /// Strip the `agent:main:` prefix if present.
    public static func stripPrefix(_ key: String) -> String {
        if key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return key
    }

    /// Returns `true` if the key has the `agent:main:` prefix.
    public static func hasPrefix(_ key: String) -> Bool {
        key.hasPrefix(prefix)
    }

    /// Returns both the original key and the stripped version (if different).
    /// Useful for fallback lookups.
    public static func variants(of key: String) -> (original: String, stripped: String) {
        let stripped = stripPrefix(key)
        return (key, stripped)
    }
}

// MARK: - BeeChat Session Filter

/// Shared logic for determining whether a gateway session key belongs to a
/// BeeChat topic. Used by both `SyncBridge` and `Reconciler` so the rules
/// live in one place.
///
/// Implemented as an `enum` (no stored state) to avoid `Sendable` issues with
/// the non-Sendable `TopicRepository` class.
public enum BeeChatSessionFilter {
    /// Check whether a session key maps to a known BeeChat topic.
    public static func isBeeChatSession(_ sessionKey: String) throws -> Bool {
        let topicRepo = TopicRepository()
        // Direct lookup
        if try topicRepo.resolveTopicId(for: sessionKey) != nil {
            return true
        }
        // Suffix lookup (handles "agent:main:<uuid>" format)
        let stripped = SessionKeyNormalizer.stripPrefix(sessionKey)
        if stripped != sessionKey,
           try topicRepo.resolveTopicIdBySuffix(gatewayKey: sessionKey, stripped: stripped) != nil {
            return true
        }
        return false
    }

    /// Normalize a gateway session key to the local topic ID.
    public static func normalize(_ gatewayKey: String) throws -> String {
        let stripped = SessionKeyNormalizer.stripPrefix(gatewayKey)
        if let topicId = try TopicRepository().resolveTopicIdBySuffix(gatewayKey: gatewayKey, stripped: stripped) {
            return topicId
        }
        return gatewayKey
    }
}
