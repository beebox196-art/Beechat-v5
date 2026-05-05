import SwiftUI

/// Custom TextFieldStyle for ChatField that matches BeeChat's artisanal-tech theme.
///
/// ChatField v3.0.4 uses a closed `ChatFieldStyle` enum (only `.capsule`),
/// so we can't add a custom case. Instead, this TextFieldStyle is applied
/// via `.textFieldStyle(BeeChatChatFieldStyle())` on the ChatField view.
///
/// Note: ThemeManager is @MainActor-isolated, so we can't call it from the
/// nonisolated TextFieldStyle._body method. The text colour matches our
/// .textPrimary token (#2D2D2D). Background, clip shape, and accessory
/// colours are applied directly on the Composer view where ThemeManager
/// is accessible.
struct BeeChatChatFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
    }
}