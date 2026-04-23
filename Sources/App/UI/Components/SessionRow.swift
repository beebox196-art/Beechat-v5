import SwiftUI

struct SessionRow: View {
    @Environment(ThemeManager.self) var themeManager
    let topic: TopicViewModel
    
    var healthColor: Color {
        if topic.messageCount < 50 {
            Color(red: 0.42, green: 0.75, blue: 0.54) // Sage green #6BBF8A
        } else if topic.messageCount <= 150 {
            Color(red: 0.91, green: 0.72, blue: 0.29) // Warm honey #E8B84B
        } else {
            Color(red: 0.85, green: 0.42, blue: 0.42) // Soft rose #D96B6B
        }
    }

    var healthDescription: String {
        if topic.messageCount < 50 {
            "Healthy"
        } else if topic.messageCount <= 150 {
            "Getting large"
        } else {
            "Bloated"
        }
    }

    var body: some View {
        HStack {
            Circle()
                .fill(healthColor)
                .frame(width: 8, height: 8)
                .accessibilityLabel("Topic health: \(healthDescription)")
                .accessibilityValue("\(topic.messageCount) messages")
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(topic.title), \(healthDescription), \(topic.messageCount) messages")
        .accessibilityHint("Select conversation")
    }
}