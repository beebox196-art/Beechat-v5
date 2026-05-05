import SwiftUI

/// Custom TextFieldStyle for ChatField that matches BeeChat's artisanal-tech theme.
///
/// ChatField v3.0.4 uses a closed `ChatFieldStyle` enum (only `.capsule`),
/// so we can't add a custom case. Instead, this TextFieldStyle is applied
/// via `.textFieldStyle(BeeChatChatFieldStyle())` on the ChatField view,
/// which propagates to the inner TextField via SwiftUI's environment.
///
/// **Why hardcoded values instead of ThemeManager tokens:**
/// ThemeManager is @MainActor-isolated, but TextFieldStyle._body is a
/// nonisolated protocol requirement. We can't call ThemeManager from here.
/// The values below match our artisanal-tech theme tokens:
///   - Font: .system(size: 14) ≈ themeManager.font(.body)
///   - Foreground: .primary (adapts to light/dark mode automatically)
///   - Padding matches the old MacTextView textContainerInset
///
/// Background, clip shape, and accessory colours are applied directly on
/// the Composer view where ThemeManager is accessible.
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