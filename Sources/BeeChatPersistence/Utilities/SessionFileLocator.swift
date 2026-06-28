import Foundation

/// Resolves on-disk session file paths from a session key.
///
/// The gateway stores per-session files (`.jsonl`, `.trajectory.jsonl`, `.jsonl.lock`)
/// under `~/.openclaw/agents/<agentId>/sessions/`, named by an internal session UUID.
///
/// For sessions created locally, that UUID matches the suffix of the session key
/// (`agent:main:<uuid>`). For Telegram (and other surfaced-channel) sessions, the
/// gateway assigns a separate UUID that is recorded in `sessions.json` and exposed
/// only via the gateway's session list response (which the macOS app does not currently
/// deserialize). For these, this locator falls back to reading `sessions.json` directly
/// from disk to discover the UUID.
public struct SessionFileLocator {

    /// Filesystem layout assumed by this locator.
    public static let agentsRoot = "\(NSHomeDirectory())/.openclaw/agents"

    /// Result of resolving session files for a given key.
    public struct Location {
        /// Absolute path to the trajectory file (if it exists or would exist).
        public let trajectoryURL: URL
        /// Absolute path to the session lock file (if it exists or would exist).
        public let lockURL: URL
        /// Absolute path to the session transcript file (if it exists or would exist).
        public let transcriptURL: URL
        /// The directory the files live in.
        public let directory: URL
    }

    public init() {}

    /// Resolve the file paths associated with the given session key, without
    /// checking disk for existence. Returns paths based on the most plausible
    /// session UUID — prefer the session-key suffix when it looks like a UUID,
    /// otherwise consult `sessions.json` on disk to look up the gateway's UUID.
    ///
    /// - Parameters:
    ///   - sessionKey: The session key (e.g. `agent:main:telegram:group:-...:topic:1`
    ///     or `agent:main:<uuid>`).
    ///   - agentId: The agent id (e.g. `main`). Defaults to the agent parsed from
    ///     `sessionKey` (e.g. `agent:main:...` → `main`), falling back to `main`.
    public func resolve(sessionKey: String, agentId: String? = nil) -> Location? {
        let resolvedAgentId = agentId ?? Self.agentId(fromSessionKey: sessionKey) ?? "main"
        guard let sessionId = Self.sessionId(fromSessionKey: sessionKey) ?? Self.lookupSessionIdInSessionsJson(sessionKey: sessionKey, agentId: resolvedAgentId)
        else { return nil }

        let directory = URL(fileURLWithPath: "\(Self.agentsRoot)/\(resolvedAgentId)/sessions", isDirectory: true)
        return Location(
            trajectoryURL: directory.appendingPathComponent("\(sessionId).trajectory.jsonl"),
            lockURL: directory.appendingPathComponent("\(sessionId).jsonl.lock"),
            transcriptURL: directory.appendingPathComponent("\(sessionId).jsonl"),
            directory: directory
        )
    }

    /// Best-effort cleanup of the trajectory and lock files for `sessionKey`.
    /// Returns the URLs that were deleted (so the caller can log). Errors are
    /// swallowed and logged — cleanup must never block a reset.
    @discardableResult
    public func cleanupTrajectoryAndLock(sessionKey: String, agentId: String? = nil) -> [URL] {
        guard let location = resolve(sessionKey: sessionKey, agentId: agentId) else {
            return []
        }
        var deleted: [URL] = []
        for url in [location.trajectoryURL, location.lockURL] {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                    deleted.append(url)
                }
            } catch {
                print("[SessionFileLocator] failed to delete \(url.path): \(error)")
            }
        }
        return deleted
    }

    // MARK: - Helpers

    /// Extract the agent id from a session key of the form `agent:<agentId>:<rest>`.
    public static func agentId(fromSessionKey sessionKey: String) -> String? {
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 1, parts[0] == "agent" else { return nil }
        return String(parts[1])
    }

    /// If `sessionKey` is `agent:<agentId>:<uuid>`, return the UUID. Otherwise nil.
    /// Used for locally-created sessions where the session-key suffix IS the file UUID.
    public static func sessionId(fromSessionKey sessionKey: String) -> String? {
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "agent" else { return nil }
        let suffix = String(parts[2])
        // UUIDs are 36 chars (with dashes) or 32 chars (no dashes). Match by length
        // and hex+dash shape.
        if suffix.count == 36, looksLikeUUID(suffix) { return suffix }
        if suffix.count == 32, suffix.allSatisfy({ $0.isHexDigit }) { return suffix }
        return nil
    }

    /// Best-effort lookup of the gateway's session UUID by reading `sessions.json`
    /// from the agent's sessions directory. The gateway records
    /// `agent:<agentId>:<rest>` → `{ "sessionId": "<uuid>", ... }` mappings there.
    private static func lookupSessionIdInSessionsJson(sessionKey: String, agentId: String) -> String? {
        let sessionsJSON = URL(fileURLWithPath: "\(agentsRoot)/\(agentId)/sessions/sessions.json")
        guard FileManager.default.fileExists(atPath: sessionsJSON.path),
              let data = try? Data(contentsOf: sessionsJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = json[sessionKey] as? [String: Any],
              let sessionId = entry["sessionId"] as? String,
              looksLikeUUID(sessionId)
        else { return nil }
        return sessionId
    }

    private static func looksLikeUUID(_ s: String) -> Bool {
        guard s.count == 36 else { return false }
        let chars = Array(s)
        let dashPositions = [8, 13, 18, 23]
        for pos in dashPositions where chars[pos] != "-" { return false }
        for (i, c) in chars.enumerated() where !dashPositions.contains(i) && !c.isHexDigit {
            return false
        }
        return true
    }
}
