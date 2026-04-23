import SwiftUI

struct SessionRow: View {
    @Environment(ThemeManager.self) var themeManager
    let topic: TopicViewModel
    
    var body: some View {
        HStack {
            Text(topic.title)
                .font(themeManager.font(.body))
                .lineLimit(1)
            Spacer()
            if topic.unreadCount > 0 {
                Text("\(topic.unreadCount)")
                    .font(.caption)
                    .foregroundColor(themeManager.color(.textSecondary))
            }
        }
        .accessibilityLabel(topic.title)
        .accessibilityHint("Select conversation")
        .accessibilityAddTraits(.isButton)
    }
}