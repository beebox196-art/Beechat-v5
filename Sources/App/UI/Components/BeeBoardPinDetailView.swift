import SwiftUI
import BeeBoard

struct BeeBoardPinDetailView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss
    @Binding var pin: Pin
    @State private var isShowingMarkdownPreview = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Pin Detail")
                    .font(themeManager.font(.heading))
                    .foregroundColor(themeManager.color(.textPrimary))

                Spacer()

                Button(action: { isShowingMarkdownPreview.toggle() }) {
                    Image(systemName: isShowingMarkdownPreview ? "text.alignleft" : "eye")
                        .font(themeManager.font(.body))
                        .foregroundColor(themeManager.color(.accentPrimary))
                }
                .buttonStyle(.plain)
                .help(isShowingMarkdownPreview ? "Edit" : "Preview")

                Button("Close") {
                    dismiss()
                }
                .font(themeManager.font(.subheading))
                .foregroundColor(themeManager.color(.accentPrimary))
            }
            .padding(.horizontal, themeManager.spacing(.xl))
            .padding(.vertical, themeManager.spacing(.lg))

            Divider()
                .background(themeManager.color(.borderSubtle))

            ScrollView {
                VStack(alignment: .leading, spacing: themeManager.spacing(.xl)) {
                    // Title
                    TextField("Title", text: Binding(
                        get: { pin.title },
                        set: { pin.title = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .font(themeManager.font(.heading))
                    .foregroundColor(themeManager.color(.textPrimary))

                    // Body
                    if isShowingMarkdownPreview {
                        if let content = pin.content, !content.isEmpty {
                            if let attributed = try? AttributedString(
                                markdown: content,
                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                            ) {
                                Text(attributed)
                                    .font(themeManager.font(.body))
                                    .foregroundColor(themeManager.color(.textPrimary))
                            } else {
                                Text(content)
                                    .font(themeManager.font(.body))
                                    .foregroundColor(themeManager.color(.textPrimary))
                            }
                        } else {
                            Text("No content yet. Switch to edit mode to write.")
                                .font(themeManager.font(.body))
                                .foregroundColor(themeManager.color(.textSecondary))
                        }
                    } else {
                        TextEditor(text: Binding(
                            get: { pin.content ?? "" },
                            set: { pin.content = $0.isEmpty ? nil : $0 }
                        ))
                        .font(themeManager.font(.body))
                        .foregroundColor(themeManager.color(.textPrimary))
                        .frame(minHeight: 200)
                        .padding(themeManager.spacing(.sm))
                        .background(
                            RoundedRectangle(cornerRadius: themeManager.radius(.md))
                                .fill(themeManager.color(.bgPanel))
                        )
                    }
                }
                .padding(themeManager.spacing(.xl))
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(themeManager.color(.bgSurface))
    }
}

#Preview {
    BeeBoardPinDetailView(
        pin: .constant(Pin(boardId: "preview", title: "Example Pin", content: "Some **markdown** content"))
    )
    .environment(ThemeManager())
}
