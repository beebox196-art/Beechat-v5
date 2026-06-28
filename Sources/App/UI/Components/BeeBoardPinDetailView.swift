import SwiftUI
import BeeBoard

struct BeeBoardPinDetailView: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss
    @Binding var pin: Pin
    @State private var isShowingMarkdownPreview = true
    @State private var newLinkURL = ""

    var onAddAttachment: (URL) -> Void
    var onRemoveAttachment: (String) -> Void
    var onAddLink: (String) -> Void
    var onRemoveLink: (String) -> Void

    var currentPinData: PinData {
        guard let data = pin.pinData?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(PinData.self, from: data) else {
            return PinData()
        }
        return decoded
    }

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

                    // ─── Attachments ───
                    attachmentsSection

                    // ─── Links ───
                    linksSection
                }
                .padding(themeManager.spacing(.xl))
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .background(themeManager.color(.bgSurface))
    }

    // MARK: - Attachments Section

    @ViewBuilder
    private var attachmentsSection: some View {
        let data = currentPinData

        VStack(alignment: .leading, spacing: themeManager.spacing(.md)) {
            HStack {
                Text("Attachments")
                    .font(themeManager.font(.subheading))
                    .foregroundColor(themeManager.color(.textPrimary))
                Spacer()
            }

            if data.attachments.isEmpty {
                dropPlaceholder
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: themeManager.spacing(.md)) {
                        ForEach(data.attachments) { attachment in
                            attachmentView(for: attachment)
                        }
                    }
                }
                .frame(height: 110)
            }
        }
        .padding(themeManager.spacing(.md))
        .background(
            RoundedRectangle(cornerRadius: themeManager.radius(.md))
                .fill(themeManager.color(.bgPanel).opacity(0.5))
                .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async {
                        onAddAttachment(url)
                    }
                }
            }
            return true
        }
    }

    private var dropPlaceholder: some View {
        HStack {
            Spacer()
            VStack(spacing: themeManager.spacing(.sm)) {
                Image(systemName: "arrow.down.doc")
                    .font(themeManager.font(.display))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.5))
                Text("Drop files here")
                    .font(themeManager.font(.caption))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.6))
            }
            Spacer()
        }
        .frame(height: 90)
        .background(
            RoundedRectangle(cornerRadius: themeManager.radius(.md))
                .stroke(themeManager.color(.borderSubtle).opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [6]))
        )
    }

    @ViewBuilder
    private func attachmentView(for attachment: PinAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                let url = AttachmentStorage.url(for: attachment.relativePath)
                NSWorkspace.shared.open(url)
            } label: {
                if attachment.isImage {
                    if let image = NSImage(contentsOf: AttachmentStorage.url(for: attachment.relativePath)) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 120, maxHeight: 90)
                            .clipShape(RoundedRectangle(cornerRadius: themeManager.radius(.sm)))
                            .overlay(
                                RoundedRectangle(cornerRadius: themeManager.radius(.sm))
                                    .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
                            )
                    } else {
                        fallbackFileIcon(for: attachment)
                    }
                } else {
                    fallbackFileIcon(for: attachment)
                }
            }
            .buttonStyle(.plain)

            Button(action: { onRemoveAttachment(attachment.id) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.textSecondary))
                    .background(Circle().fill(themeManager.color(.bgSurface)))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func fallbackFileIcon(for attachment: PinAttachment) -> some View {
        VStack(spacing: themeManager.spacing(.xs)) {
            Image(systemName: fileIconName(for: attachment.fileExtension))
                .font(themeManager.font(.display))
                .foregroundColor(themeManager.color(.accentPrimary))
            Text(attachment.fileName)
                .font(themeManager.font(.caption))
                .foregroundColor(themeManager.color(.textSecondary))
                .lineLimit(1)
                .frame(maxWidth: 100)
        }
        .frame(width: 120, height: 90)
        .background(
            RoundedRectangle(cornerRadius: themeManager.radius(.sm))
                .fill(themeManager.color(.bgElevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: themeManager.radius(.sm))
                .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
        )
    }

    private func fileIconName(for ext: String?) -> String {
        switch ext?.lowercased() {
        case "pdf": return "doc.fill"
        case "doc", "docx": return "doc.text.fill"
        case "xls", "xlsx": return "tablecells.fill"
        case "zip", "tar", "gz": return "doc.zipper"
        default: return "doc"
        }
    }

    // MARK: - Links Section

    @ViewBuilder
    private var linksSection: some View {
        let data = currentPinData

        VStack(alignment: .leading, spacing: themeManager.spacing(.md)) {
            HStack {
                Text("Links")
                    .font(themeManager.font(.subheading))
                    .foregroundColor(themeManager.color(.textPrimary))
                Spacer()
            }

            // Add link row
            HStack(spacing: themeManager.spacing(.sm)) {
                TextField("https://...", text: $newLinkURL)
                    .textFieldStyle(.plain)
                    .font(themeManager.font(.body))
                    .foregroundColor(themeManager.color(.textPrimary))
                    .padding(.horizontal, themeManager.spacing(.sm))
                    .padding(.vertical, themeManager.spacing(.xs))
                    .background(
                        RoundedRectangle(cornerRadius: themeManager.radius(.md))
                            .fill(themeManager.color(.bgElevated))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: themeManager.radius(.md))
                            .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
                    )

                Button("Add") {
                    let trimmed = newLinkURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, URL(string: trimmed) != nil {
                        onAddLink(trimmed)
                        newLinkURL = ""
                    }
                }
                .font(themeManager.font(.subheading))
                .foregroundColor(themeManager.color(.accentPrimary))
                .disabled(newLinkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if data.links.isEmpty {
                Text("No links yet")
                    .font(themeManager.font(.caption))
                    .foregroundColor(themeManager.color(.textSecondary).opacity(0.6))
            } else {
                VStack(alignment: .leading, spacing: themeManager.spacing(.sm)) {
                    ForEach(data.links) { link in
                        linkRow(for: link)
                    }
                }
            }
        }
        .padding(themeManager.spacing(.md))
        .background(
            RoundedRectangle(cornerRadius: themeManager.radius(.md))
                .fill(themeManager.color(.bgPanel).opacity(0.5))
                .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func linkRow(for link: PinLink) -> some View {
        HStack(spacing: themeManager.spacing(.sm)) {
            Button {
                if let url = URL(string: link.url) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: themeManager.spacing(.sm)) {
                    Image(systemName: "link")
                        .font(themeManager.font(.caption))
                        .foregroundColor(themeManager.color(.accentPrimary))

                    VStack(alignment: .leading, spacing: 2) {
                        if let title = link.title {
                            Text(title)
                                .font(themeManager.font(.body))
                                .foregroundColor(themeManager.color(.textPrimary))
                                .lineLimit(1)
                        } else {
                            Text(link.url)
                                .font(themeManager.font(.body))
                                .foregroundColor(themeManager.color(.textSecondary))
                                .lineLimit(1)
                        }
                        Text(domain(from: link.url))
                            .font(themeManager.font(.caption))
                            .foregroundColor(themeManager.color(.textSecondary).opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }

            Spacer()

            Button(action: { onRemoveLink(link.id) }) {
                Image(systemName: "xmark")
                    .font(themeManager.font(.caption2))
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, themeManager.spacing(.xs))
    }

    private func domain(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else {
            return urlString
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

#Preview {
    BeeBoardPinDetailView(
        pin: .constant(Pin(boardId: "preview", title: "Example Pin", content: "Some **markdown** content")),
        onAddAttachment: { _ in },
        onRemoveAttachment: { _ in },
        onAddLink: { _ in },
        onRemoveLink: { _ in }
    )
    .environment(ThemeManager())
}
