import SwiftUI
import BeeChatPersistence

/// Renders the content inside a message bubble — text and future media.
struct MessageContent: View {
    @Environment(ThemeManager.self) var themeManager
    let message: Message

    var body: some View {
        if let content = message.content, !content.isEmpty {
            Text(content)
                .font(themeManager.font(.body))
                .textSelection(.enabled)
        } else {
            Text(" ")
                .font(themeManager.font(.body))
        }
    }
}