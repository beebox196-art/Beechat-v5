import Foundation

/// Holds configuration for session reset behaviour.
/// The full auto-reset flow is now integrated directly into SyncBridge.sendMessage.
public actor SessionResetManager {
    public struct Config {
        public var redDotThreshold: Double = 0.50      // When the amber dot appears (manual reset available)
        public var autoResetThreshold: Double = 0.80   // When auto-reset fires on send (safety ceiling)
        public var cooldownMessages: Int = 5            // Auto-reset cooldown (manual resets skip this)
        public var showConfirmation: Bool = true         // Confirmation alert for manual reset
        public init() {}
    }

    public var config = Config()

    public init() {}
}
