import SwiftUI

/// Wing path + flapping animation (SwiftUI only, no Lottie).
struct BeeWingsAnimation: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    let size: ThinkingBeeSize
    let isThinking: Bool

    // MARK: - Wing Flap State

    @State private var wingAngle: Double = 0

    var body: some View {
        HStack(spacing: 0) {
            // Left wing
            wing(rotateLeft: true)
            // Right wing
            wing(rotateLeft: false)
        }
        .frame(width: size.wingSize.width * 2 + size.capsuleSize.width,
               height: size.wingSize.height)
        .onAppear {
            guard isThinking && !reduceMotion else { return }
            startFlapping()
        }
        .onChange(of: isThinking) { _, newValue in
            if newValue && !reduceMotion {
                startFlapping()
            } else {
                wingAngle = 0
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                wingAngle = 0
            } else if isThinking {
                startFlapping()
            }
        }
    }

    // MARK: - Wing View

    @ViewBuilder
    private func wing(rotateLeft: Bool) -> some View {
        Ellipse()
            .fill(size.wingColor(theme: themeManager, isThinking: isThinking))
            .frame(width: size.wingSize.width, height: size.wingSize.height)
            .rotation3DEffect(
                .degrees(rotateLeft ? -wingAngle : wingAngle),
                axis: (x: 0, y: 1, z: 0),
                anchor: rotateLeft ? .trailing : .leading
            )
    }

    // MARK: - Animation

    private func startFlapping() {
        withAnimation(.easeInOut(duration: 0.12).repeatForever(autoreverses: true)) {
            wingAngle = 30
        }
    }
}