import SwiftUI

/// Horizontal topic bar — segmented control at top of chat window.
/// Displays topics as pills in a scrollable row with optional chevrons.
struct TopicBar: View {
    @Environment(ThemeManager.self) var themeManager

    let topics: [TopicViewModel]
    @Binding var selectedTopicId: String?
    let onCreateTopic: () -> Void
    let onDeleteTopic: (String) -> Void

    @State private var scrollOffset: CGFloat = 0
    @State private var canScrollLeft = false
    @State private var canScrollRight = false

    var body: some View {
        HStack(spacing: 0) {
            // Left chevron (visible when topics overflow)
            if canScrollLeft {
                Button(action: scrollLeft) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(themeManager.color(.textSecondary))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
            }

            // Scrollable topic pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(topics) { topic in
                        TopicPill(
                            title: topic.title,
                            isSelected: topic.id == selectedTopicId,
                            action: { selectedTopicId = topic.id }
                        )
                        .contextMenu {
                            Button("Delete Topic", role: .destructive) {
                                onDeleteTopic(topic.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            // Right chevron (visible when topics overflow)
            if canScrollRight {
                Button(action: scrollRight) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(themeManager.color(.textSecondary))
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
            }

            // Create topic button
            Button(action: onCreateTopic) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(themeManager.color(.accentPrimary))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
        }
        .frame(height: 56)
        .padding(.horizontal, 12)
        .background(themeManager.color(.bgPanel))
    }

    private func scrollLeft() {
        // ScrollView scroll programmatic control deferred — pills fit within typical widths
    }

    private func scrollRight() {
        // ScrollView scroll programmatic control deferred
    }
}