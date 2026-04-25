import SwiftUI

/// Main view for the Thinking Bee indicator.
/// Supports two modes: `.thinking` (buzzing bee in message area) and `.dormant` (sleeping bee in sidebar).
struct ThinkingBeeIndicator: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    let mode: ThinkingBeeIndicatorMode

    // MARK: - Animation State

    @State private var bounceOffset: CGFloat = 0
    @State private var opacityValue: Double = 1.0
    @State private var zzzOpacity: Double = 0
    @State private var hasAnnouncedThinking = false

    var body: some View {
        switch mode {
        case .thinking:
            thinkingBee
                .accessibilityLabel("AI is thinking")
                .accessibilityHint("Waiting for response")
                .onAppear {
                    announceThinking()
                }
        case .dormant:
            dormantBee
                .accessibilityHidden(true)
        }
    }

    // MARK: - Thinking Bee (Buzzing)

    private var thinkingBee: some View {
        VStack(spacing: 2) {
            BeeWingsAnimation(size: ThinkingBeeSize.canvas, isThinking: true)

            Capsule()
                .fill(ThinkingBeeSize.canvas.bodyColor(theme: themeManager, isThinking: true))
                .frame(width: ThinkingBeeSize.canvas.capsuleSize.width,
                       height: ThinkingBeeSize.canvas.capsuleSize.height)
        }
        .frame(width: ThinkingBeeSize.canvas.bodySize.width, height: ThinkingBeeSize.canvas.bodySize.height)
        .offset(y: reduceMotion ? 0 : bounceOffset)
        .opacity(reduceMotion ? opacityValue : 1.0)
        .onAppear {
            if reduceMotion {
                startOpacityPulse()
            } else {
                startBounce()
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                bounceOffset = 0
                startOpacityPulse()
            } else {
                opacityValue = 1.0
                startBounce()
            }
        }
    }

    // MARK: - Dormant Bee (Sleeping)

    private var dormantBee: some View {
        HStack(spacing: 1) {
            VStack(spacing: 0) {
                // Folded wings (static)
                HStack(spacing: 0) {
                    Ellipse()
                        .fill(ThinkingBeeSize.sidebar.wingColor(theme: themeManager, isThinking: false))
                        .frame(width: ThinkingBeeSize.sidebar.wingSize.width, height: ThinkingBeeSize.sidebar.wingSize.height)
                        .rotationEffect(.degrees(-20))
                    Ellipse()
                        .fill(ThinkingBeeSize.sidebar.wingColor(theme: themeManager, isThinking: false))
                        .frame(width: ThinkingBeeSize.sidebar.wingSize.width, height: ThinkingBeeSize.sidebar.wingSize.height)
                        .rotationEffect(.degrees(20))
                }

                Capsule()
                    .fill(ThinkingBeeSize.sidebar.bodyColor(theme: themeManager, isThinking: false))
                    .frame(width: ThinkingBeeSize.sidebar.capsuleSize.width,
                           height: ThinkingBeeSize.sidebar.capsuleSize.height)
            }

            // Zzz text
            Text("z")
                .font(.system(size: ThinkingBeeSize.sidebar.zzzFontSize))
                .foregroundColor(themeManager.color(.textSecondary).opacity(0.5))
                .opacity(zzzOpacity)
        }
        .frame(width: ThinkingBeeSize.sidebar.bodySize.width, height: ThinkingBeeSize.sidebar.bodySize.height)
        .onAppear {
            startZzzAnimation()
        }
    }

    // MARK: - Animations

    private func startBounce() {
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            bounceOffset = -2
        }
    }

    private func startOpacityPulse() {
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            opacityValue = 0.6
        }
    }

    private func startZzzAnimation() {
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            zzzOpacity = 1.0
        }
    }

    private func announceThinking() {
        guard !hasAnnouncedThinking else { return }
        hasAnnouncedThinking = true
        AccessibilityNotification.Announcement("AI is thinking").post()
    }
}

// MARK: - Indicator Mode

enum ThinkingBeeIndicatorMode {
    case thinking   // Buzzing bee in message canvas
    case dormant    // Sleeping bee in sidebar
}