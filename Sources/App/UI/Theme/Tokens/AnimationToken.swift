import SwiftUI

/// Easing curve types for animations.
enum AnimationEasing: String, Sendable {
    case easeInOut
    case spring
    case linear

    /// SwiftUI animation for this easing with the given duration.
    func animation(duration: TimeInterval) -> Animation {
        switch self {
        case .easeInOut:
            return .easeInOut(duration: duration)
        case .spring:
            return .spring(duration: duration, bounce: 0.3, blendDuration: 1)
        case .linear:
            return .linear(duration: duration)
        }
    }
}

/// Animation token definition pairing duration with easing.
struct AnimationDefinition: Sendable {
    let duration: TimeInterval
    let easing: AnimationEasing

    /// SwiftUI animation for this definition.
    var animation: Animation {
        easing.animation(duration: duration)
    }
}

/// Animation duration tokens for consistent transition timing.
/// Matches DESIGN-SYSTEM.md animation definitions.
enum AnimationToken: String, CaseIterable, Sendable {
    case fast   // 0.15s — micro-interactions, state changes
    case micro  // 0.2s — subtle transitions
    case normal // 0.3s — standard transitions
    case slow   // 0.5s — emphasis, page transitions
    case slower // 0.6s — relaxed animations (e.g. typing indicator)

    var duration: TimeInterval {
        switch self {
        case .fast:   return 0.15
        case .micro:  return 0.2
        case .normal: return 0.3
        case .slow:   return 0.5
        case .slower: return 0.6
        }
    }

    /// Default easing for this token.
    var defaultEasing: AnimationEasing {
        switch self {
        case .fast:   return .easeInOut
        case .micro:  return .easeInOut
        case .normal: return .easeInOut
        case .slow:   return .easeInOut
        case .slower: return .easeInOut
        }
    }

    /// Full animation definition with default easing.
    var definition: AnimationDefinition {
        AnimationDefinition(duration: duration, easing: defaultEasing)
    }

    /// SwiftUI animation for this token with default easing.
    var animation: Animation {
        definition.animation
    }
}
