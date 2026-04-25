import SwiftUI

/// Isolated state for the thinking indicator.
/// Does not touch existing state — observes it.
enum ThinkingState: Sendable, Equatable {
    case idle       // No activity — show dormant bee in sidebar
    case thinking   // Message sent, waiting for first delta — show buzzing bee
    case streaming  // Deltas arriving — hide bee, StreamingBubble handles it
}