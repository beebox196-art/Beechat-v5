import SwiftUI
import BeeChatPersistence
import UniformTypeIdentifiers

struct FolderPicker: View {
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss
    @State private var bookmarks: [Bookmark] = []
    @State private var showRemoveAlert = false
    @State private var bookmarkToRemove: Bookmark?
    @State private var showFileImporter = false

    private let columns = [
        GridItem(.adaptive(minimum: 180), spacing: 16)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { addFolders() }) {
                    Image(systemName: "plus.circle")
                        .font(themeManager.font(.subheading))
                        .foregroundColor(themeManager.color(.accentPrimary))
                }
                .buttonStyle(.plain)
                .help("Add Folder")
                .accessibilityLabel("Add Folder")
                .accessibilityHint("Add a folder to favourites")

                Spacer()

                Text("Folders")
                    .font(themeManager.font(.heading))
                    .foregroundColor(themeManager.color(.textPrimary))

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .font(themeManager.font(.subheading))
                .foregroundColor(themeManager.color(.accentPrimary))
            }
            .padding(.horizontal, themeManager.spacing(.xl))
            .padding(.vertical, themeManager.spacing(.lg))

            Divider()
                .background(themeManager.color(.borderSubtle))

            // Folder grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(bookmarks) { bookmark in
                        FolderCard(bookmark: bookmark)
                            .onTapGesture {
                                openFolder(bookmark)
                            }
                            .contextMenu {
                                Button("Remove from Favourites", role: .destructive) {
                                    bookmarkToRemove = bookmark
                                    showRemoveAlert = true
                                }
                            }
                    }
                }
                .padding(themeManager.spacing(.xl))
            }
            .background(themeManager.color(.bgSurface))
        }
        .frame(minWidth: 420, minHeight: 380)
        .background(themeManager.color(.bgSurface))
        .onAppear { loadBookmarks() }
        .alert("Remove Folder?", isPresented: $showRemoveAlert, presenting: bookmarkToRemove) { bookmark in
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) {
                removeBookmark(bookmark)
            }
        } message: { bookmark in
            Text("Remove \"\(bookmark.name)\" from favourites?")
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            handleFileImporterResult(result)
        }
    }

    private func loadBookmarks() {
        do {
            bookmarks = try BookmarkRepository().fetchAll()
        } catch {
            print("[FolderPicker] Failed to load bookmarks: \(error)")
        }
    }

    private func openFolder(_ bookmark: Bookmark) {
        let path = bookmark.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func removeBookmark(_ bookmark: Bookmark) {
        do {
            try BookmarkRepository().delete(id: bookmark.id)
            bookmarks.removeAll { $0.id == bookmark.id }
        } catch {
            print("[FolderPicker] Failed to delete bookmark: \(error)")
        }
    }

    private func addFolders() {
        showFileImporter = true
    }

    private func handleFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            let repo = BookmarkRepository()
            for url in urls {
                let path = url.path
                do {
                    if try repo.exists(path: path) { continue }

                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }

                    let bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )

                    let bookmark = Bookmark(
                        name: url.lastPathComponent,
                        path: path,
                        securityBookmark: bookmarkData
                    )
                    try repo.save(bookmark)
                } catch {
                    print("[FolderPicker] Failed to add folder \(path): \(error)")
                }
            }
            loadBookmarks()
        case .failure(let error):
            print("[FolderPicker] File importer failed: \(error)")
        }
    }
}

// MARK: - Folder Card

struct FolderCard: View {
    let bookmark: Bookmark
    @Environment(ThemeManager.self) var themeManager

    private var pathExists: Bool {
        FileManager.default.fileExists(atPath: bookmark.path)
    }

    var body: some View {
        VStack(spacing: themeManager.spacing(.sm)) {
            Image(systemName: pathExists ? "\(bookmark.iconName).fill" : "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(
                    pathExists
                        ? themeManager.color(.accentPrimary)
                        : themeManager.color(.textSecondary).opacity(0.5)
                )
                .frame(height: 32)

            Text(bookmark.name)
                .font(themeManager.font(.caption))
                .foregroundColor(pathExists ? themeManager.color(.textPrimary) : themeManager.color(.textSecondary))
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(themeManager.spacing(.md))
        .background(
            RoundedRectangle(cornerRadius: themeManager.radius(.lg))
                .fill(themeManager.color(.bgPanel))
        )
        .overlay(
            RoundedRectangle(cornerRadius: themeManager.radius(.lg))
                .stroke(themeManager.color(.borderSubtle), lineWidth: 1)
        )
        .opacity(pathExists ? 1.0 : 0.6)
        .accessibilityLabel(bookmark.name)
        .accessibilityHint(pathExists ? "Open in Finder" : "Folder not found")
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

#Preview {
    FolderPicker()
        .environment(ThemeManager())
}