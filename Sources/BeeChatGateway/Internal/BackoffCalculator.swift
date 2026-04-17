import Foundation

public struct BackoffCalculator: Sendable {
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let maxRetries: Int
    
    public init(baseDelay: TimeInterval = 1.0, maxDelay: TimeInterval = 30.0, maxRetries: Int = 10) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetries = maxRetries
    }
    
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponential = min(baseDelay * pow(2.0, Double(attempt)), maxDelay)
        let jitter = exponential * 0.2 * Double.random(in: -1...1)
        return exponential + jitter
    }
}
