# Folder Favourites Spec

**Date:** 2026-04-23
**Author:** Bee (Coordinator)
**Builder:** Q
**Reviewer:** Kieran

## Goal
Add a folder favourites picker to BeeChat that follows the same sheet-based UX pattern as ThemePicker, allowing Adam to quickly open bookmarked folders in Finder without leaving the app.

## Design Principle
**Consistency with ThemePicker.** Same sheet layout, same Done button, same grid pattern. User already knows how to use it — zero learning curve.

## Scope (4 items)

### 1. Bookmarks Database Table + Migration
**Required:**
- Add `Migration008_CreateBookmarks` to DatabaseManager
- New table: `bookmarks`
  - `id TEXT PRIMARY KEY` — UUID
  - `name TEXT NOT NULL` — display name (defaults to folder's last path component)
  - `path TEXT NOT NULL UNIQUE` — full filesystem path (UNIQUE prevents duplicates)
  - `securityBookmark DATA` — security-scoped bookmark data (nullable — `Data?`)
  - `iconName TEXT` — SF Symbol name for the folder icon (default "folder")
  - `sortOrder INTEGER DEFAULT 0` — for manual ordering
  - `createdAt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP`
- Add `Bookmark` model (Codable, Identifiable) in BeeChatPersistence
- Add `BookmarkRepository` with CRUD operations including `delete(id:)`
- **⚠️ Kieran conditions:**
  - `securityBookmark` must be nullable (`Data?`) — pre-sandboxed bookmarks may have nil
  - `path` must have UNIQUE constraint to prevent duplicate folders
  - Default query order: `ORDER BY sortOrder, createdAt`

### 2. Folder Picker Sheet (UI Component)
**Current pattern (ThemePicker):**
- Header with title + Done button
- ScrollView with grid of cards
- Card shows preview + name + selected state

**Folder Picker follows same pattern:**
- Header: "Folders" + Done button (same layout as ThemePicker's "Appearance" + Done)
- ScrollView with grid of folder cards
- Each FolderCard shows:
  - SF Symbol icon (folder.fill by default, or custom per bookmark)
  - Folder name (display name)
  - Path subtitle (truncated, e.g. "~/Desktop/Gav-Reports")
  - File count badge (optional, can be slow — only show if quick to compute)
- Tap a folder → opens it in Finder using `NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath:)`
- **⚠️ Filesystem validation:** Before opening, check `FileManager.default.fileExists(atPath:)`. If folder doesn't exist, show dimmed card with "Folder not found" subtitle and skip opening.
- **Add button** (+) in the header (left side, opposite Done button) → opens NSOpenPanel
- **Folder removal:** Right-click context menu on FolderCard with "Remove from Favourites" → confirmation alert → delete from DB

**Implementation:**
- Create `Sources/App/UI/Components/FolderPicker.swift`
- Mirror ThemePicker structure: VStack → Header → Divider → ScrollView → LazyVGrid
- FolderCard mirrors ThemeCard: icon + name + path, selected border on active
- "Add Folder" button in header triggers NSOpenPanel

### 3. Sidebar Button
**Current sidebar bar has:** [+] [palette] [trash]

**Add folder button:** [+] [folder] [palette] [trash]
- SF Symbol: `folder.badge.plus` (indicates "folders + add")
- Tap → opens FolderPicker sheet
- Accessibility: label "Folders", hint "Open favourite folders"

**Implementation:**
- Add Button in `MainWindow.swift` sidebar bar, between the + and palette buttons
- Same style as existing buttons (`.buttonStyle(.plain)`, `.help()`, accessibility labels)
- `@State private var showFolderPicker = false`
- `.sheet(isPresented: $showFolderPicker) { FolderPicker() }`

### 4. NSOpenPanel for Adding Folders
**Required:**
- Native macOS folder selection dialog
- Can only select directories (not files)
- Allows multiple selection (add several folders at once)
- On selection: create Bookmark entries with security-scoped bookmarks
- Security-scoped bookmark persistence: store the bookmark data in the `bookmarks` table so access survives app restarts

**Implementation:**
- **⚠️ Use `NSOpenPanel.beginSheetModal(for:)`** — NOT `runModal()` which blocks the main thread and conflicts with SwiftUI lifecycle
- Wrap NSOpenPanel in a SwiftUI ViewModifier or use `NSApplication.shared.windows.first` to get the parent window
- Configure: `.canChooseDirectories = true`, `.canChooseFiles = false`, `.allowsMultipleSelection = true`
- For each selected URL:
  1. Check for duplicate: query DB for existing `path` — skip if already bookmarked
  2. Create security-scoped bookmark: `try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)`
  3. Save bookmark data to DB
  4. Add to the picker's observed list
- **Best practice:** Call `startAccessingSecurityScopedResource()` when resolving bookmark URLs, even in dev builds

## Acceptance Criteria
1. Folder button appears in sidebar bar between + and palette
2. Tapping it opens a sheet styled like ThemePicker
3. Sheet shows all bookmarked folders as cards with icon + name + path
4. Tapping a folder card opens it in Finder
5. "+" button in sheet opens native NSOpenPanel for folder selection
6. Selected folders are saved to the database and persist across restarts
7. Folders can be removed (context menu or swipe to delete)
8. Build succeeds clean

## Files to Create
- `Sources/BeeChatPersistence/Models/Bookmark.swift`
- `Sources/BeeChatPersistence/Repositories/BookmarkRepository.swift`
- `Sources/App/UI/Components/FolderPicker.swift`

## Files to Modify
- `Sources/BeeChatPersistence/Database/DatabaseManager.swift` — Migration008
- `Sources/App/UI/MainWindow.swift` — folder button + sheet state
- `Package.swift` — if needed for new source structure

## Out of Scope
- Inline file preview (future: show first N lines of a file)
- Inline file browsing (just opens Finder)
- File upload/attachment to chat (separate feature)
- Context-aware folder suggestions
- Custom folder icons (beyond SF Symbols)

## Process
1. **Spec** → This document
2. **Review** → Kieran reviews for gaps, edge cases, correctness
3. **Build** → Q implements all 4 items
4. **Tech Validation** → Kieran reviews code
5. **UX Validation** → Bee launches app, tests folder picker
6. **Commit** → After all gates pass