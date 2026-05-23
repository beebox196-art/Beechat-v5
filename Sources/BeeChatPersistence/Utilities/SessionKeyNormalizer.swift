import Foundation

// MARK: - Session Key Normalization
public enum SessionKeyNormalizer {
    /// Strips the `agent:main:` prefix from a gateway session key.
    public static func stripPrefix(_ key: String) -> String {
        let prefix = "agent:main:"
        if key.hasPrefix(prefix) {
            return String(key.dropFirst(prefix.count))
        }
        return key
    }
}
