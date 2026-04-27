import Foundation

/// Holds configuration for session reset behaviour.
/// The full auto-reset flow is now integrated directly into SyncBridge.sendMessage.
public actor SessionResetManager {
    public struct Config {
        public var redDotThreshold: Double = 0.50
        public var summaryTimeout: TimeInterval = 45
        public var showConfirmation: Bool = false
        public init() {}
    }

    public var config = Config()

    public init() {}
}
