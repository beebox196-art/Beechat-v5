import Foundation

/// Encapsulates the full session reset flow:
/// 1. Sends [SESSION-RESET] request via chat.send
/// 2. Captures the assistant summary from the final event
/// 3. Calls sessions.reset(reason: "new")
/// 4. Injects [SESSION-CONTEXT] summary via chat.send
public actor SessionResetManager {
    public struct Config {
        public var redDotThreshold: Double = 0.50
        public var summaryTimeout: TimeInterval = 45
        public var showConfirmation: Bool = false
        public init() {}
    }

    public enum Error: Swift.Error {
        case noSyncBridge
        case summaryTimeout
        case resetFailed
        case injectionFailed
    }

    public var config = Config()
    public private(set) var isResetting = false

    private var continuation: CheckedContinuation<String, Swift.Error>?
    private var timeoutTask: Task<Void, Never>?

    public init() {}

    /// Perform the full reset flow for a session.
    public func performReset(sessionKey: String, bridge: SyncBridge) async throws {
        guard !isResetting else { return }
        isResetting = true
        defer {
            isResetting = false
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        // Abort any in-flight generation before requesting summary
        try? await bridge.abortGeneration(sessionKey: sessionKey)

        // Step 1: Request summary
        let summaryRequest = "[SESSION-RESET] Please write a status summary for continuing this work in a new session. Include: current task, progress made, decisions, blockers, and next steps. Be thorough — this summary is the only context carried forward."
        _ = try await bridge.sendMessage(sessionKey: sessionKey, text: summaryRequest)

        // Step 2: Capture summary (wait for final event) with timeout
        let summary = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Swift.Error>) in
            self.continuation = cont
            self.timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(self.config.summaryTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.didFail(error: Error.summaryTimeout)
            }
        }

        // Step 3: Reset session
        let ok = try await bridge.resetSession(sessionKey: sessionKey)
        guard ok else { throw Error.resetFailed }

        // Step 4: Inject summary
        let contextMessage = "[SESSION-CONTEXT] This is a continuation from a previous session. Summary follows:\n\n" + summary
        do {
            _ = try await bridge.sendMessage(sessionKey: sessionKey, text: contextMessage)
        } catch {
            // Retry once
            _ = try? await bridge.sendMessage(sessionKey: sessionKey, text: contextMessage)
        }
    }

    /// Called by EventRouter/SyncBridge when a chat final event arrives.
    /// Only consumes the event if a reset is in progress.
    public func didReceiveFinal(sessionKey: String, text: String) {
        guard isResetting, let cont = continuation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
        cont.resume(returning: text)
    }

    /// Called to cancel an in-flight reset.
    public func didFail(error: Swift.Error) {
        guard let cont = continuation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
        cont.resume(throwing: error)
    }
}
