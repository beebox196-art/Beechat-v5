# BeeChat v5 — Phase 4 UI Specification

**Document Type:** UI/UX Specification  
**Version:** 1.0  
**Date:** 2026-04-18  
**Author:** Bee (AI Sister / Chief of Staff)  
**Reviewers:** Adam (Product), Mel (Design), Neo (Architecture)  
**Status:** APPROVED (Kieran review v1 — FAILs/WARNs resolved)

**Minimum Deployment Target:** macOS 14.0 (Sonoma) — required for `@Observable`, `@Environment(ThemeManager.self)`, Swift Observation framework

---

## Executive Summary

Phase 4 delivers the **macOS chat interface** for BeeChat v5: a focused, full-screen messaging experience between Adam and Bee. This is **not** a system control panel—it's a pure chat application with topic support, premium design, and robust media handling.

**Key Design Decisions:**
- ✅ **Single-canvas layout** — no sidebar, full-screen messaging focus
- ✅ **Top-bar topic cycling** — horizontal segmented control (macOS adaptation of iOS roladex)
- ✅ **Full message display** — no live streaming text; show complete responses only
- ✅ **Typing indicator** — visual feedback that Bee is responding
- ✅ **Artisanal Tech theme** — warm premium productivity aesthetic (earthy palette, serif + sans pairing)
- ✅ **Centralised theming** — design token system supports 8 themes, re-skinning without code changes

**Product Decisions (Adam, 2026-04-18):**
- ✅ **Topic creation:** Manual only (create + delete). No auto-creation from gateway sessions. Project folder linking is a future feature.
- ✅ **Media storage:** Outside `.openclaw` directory. Dedicated `~/BeeChat/Media/` folder.
- ✅ **Voice note format:** M4A (most common, broad compatibility)
- ✅ **Voice note duration:** 30 seconds max
- ✅ **Deleted messages:** Remove entirely (no placeholder/tombstone)
- ✅ **Topic ordering:** Alphanumeric left-to-right. Drag-to-reorder is a future feature.
- ✅ **Message bubble width:** Fixed at 66% of window width. No user resizing (future consideration only).

**Phase 4 is the user-facing layer** built on top of the existing backend:
- **SyncBridge** → state management, event streaming, RPC calls
- **GRDB Persistence** → message/session storage, real-time observations
- **Gateway Client** → WebSocket connection, Ed25519 auth, "chat" events

---

## 1. Layout Architecture

### 1.1 Recommendation: Single-Canvas Layout

**Decision:** Single-canvas (full-screen messaging) with top-bar navigation.

**Rationale:**
- Adam's explicit requirement: "NO sidebar — full-screen messaging focus"
- BeeChat is a **direct conversation** between Adam and Bee (not multi-agent, not multi-channel)
- Topics provide context switching, not separate conversations
- Maximises vertical space for message history

### 1.2 Layout Zones

```
┌─────────────────────────────────────────────────────────────┐
│  TOP BAR (56pt height)                                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  [◀]  Topic 1  |  Topic 2  |  Topic 3  |  Topic 4  [▶] │   │
│  └─────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  MESSAGE CANVAS (flexible height)                          │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                                                     │   │
│  │  [Message bubbles, media, system messages]         │   │
│  │                                                     │   │
│  │                                                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│  COMPOSER (120-200pt height, auto-expand)                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  [+ Attach]  [Text input...]            [🎤][Send] │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 Layout Specifications

| Zone | Height | Behavior |
|------|--------|----------|
| Top Bar | 56pt (fixed) | Sticky at top, contains topic cycling |
| Message Canvas | Flexible (fills available space) | Scrollable, auto-scrolls to bottom on new message |
| Composer | 120pt (min) → 200pt (max) | Auto-expands with text input, fixed on screen bottom |

### 1.3.1 Window Configuration (macOS)

**Minimum deployment target:** macOS 14.0 (Sonoma)

```swift
@main
struct BeeChatApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
        .windowStyle(.hiddenTitleBar)  // Clean look, custom title area
        .defaultSize(width: 800, height: 600)
        .windowResizability(.contentMinSize(width: 500, height: 400))
        .commands {
            CommandGroup(replacing: .newItem) { }  // Remove File > New
            CommandMenu("Chat") {
                Button("New Topic") { /* create topic */ }
                Button("Next Topic") { /* cycle right */ }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Topic") { /* cycle left */ }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
            }
        }
    }
}
```

- Window uses `.hiddenTitleBar` for the clean, full-screen messaging aesthetic
- Default size: 800×600pt
- Minimum size: 500×400pt (prevents bubbles from becoming unusably narrow)
- Menu bar includes Chat menu with topic navigation shortcuts

### 1.4 Comparison: Why Not 2-Pane or 3-Pane?

| Layout Type | Use Case | Why Not for BeeChat |
|-------------|----------|---------------------|
| **3-Pane** (Sidebar + Topic List + Messages) | Multi-agent, multi-channel apps (Slack, Discord) | BeeChat is single-agent (Bee), single-channel (Adam↔Bee) |
| **2-Pane** (Sidebar + Messages) | Multi-conversation apps (Messages, Telegram) | Topics are context switches, not separate conversations |
| **Single-Canvas** | Focused 1:1 chat (iMessage, WhatsApp mobile) | ✅ Matches Adam's requirement, maximises message space |

---

## 2. Topic Navigation

### 2.1 Mechanism: Horizontal Segmented Control

**Decision:** macOS-native segmented control with gesture support.

**Rationale:**
- Familiar macOS pattern (Xcode, Finder tabs)
- Supports swipe gestures (trackpad-friendly)
- Keyboard navigable (Tab, Arrow keys)
- Accessible (VoiceOver, keyboard focus)

### 2.2 Topic Bar Component

```swift
struct TopicBar: View {
    @Environment(ThemeManager.self) var themeManager
    @Binding var selectedTopic: Topic
    let topics: [Topic]
    
    var body: some View {
        HStack(spacing: 0) {
            // Left chevron (if topics overflow)
            if canScrollLeft {
                Button(action: scrollLeft) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
            }
            
            // Segmented control
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(topics) { topic in
                        TopicPill(
                            topic: topic,
                            isSelected: topic.id == selectedTopic.id,
                            action: { selectedTopic = topic }
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
            
            // Right chevron (if topics overflow)
            if canScrollRight {
                Button(action: scrollRight) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(height: 56)
        .background(themeManager.color(.bgPanel))
    }
}
```

### 2.3 Topic Pill Design

**States:**
- **Default:** Subtle background, secondary text colour
- **Selected:** Accent primary background, text primary colour, subtle shadow
- **Hover (macOS):** Slightly elevated, cursor pointer
- **Focused (keyboard):** Focus ring (accessibility)

**Dimensions:**
- Height: 32pt
- Min width: 80pt
- Max width: 200pt (truncate long titles with ellipsis)
- Padding: 12pt horizontal, 6pt vertical
- Corner radius: 16pt (fully rounded)

**Typography:**
- Font: SF Pro (or theme-defined base font)
- Size: 13pt
- Weight: Medium (selected), Regular (default)

### 2.4 Gesture Support

| Gesture | Action |
|---------|--------|
| **Swipe left/right (trackpad)** | Cycle to next/previous topic |
| **Click topic pill** | Select topic |
| **Arrow keys (when focused)** | Navigate between topics |
| **Cmd+1, Cmd+2, etc.** | Jump to topic by index (optional shortcut) |

### 2.5 Topic Data Model

`Topic` is a **UI-layer view model** wrapping the `Session` persistence model. It does NOT have its own database table — it derives from `Session` plus UI-only fields.

```swift
// UI layer — wraps Session, adds UI-only presentation fields
@Observable
class TopicViewModel {
    let id: String          // = Session.id (session key)
    var title: String       // = Session.title ?? "Untitled"
    var icon: String?       // UI-only: SF Symbol name, stored in UserDefaults
    var lastMessageAt: Date? // = Session.lastMessageAt
    var unreadCount: Int    // = Session.unreadCount
    
    init(from session: Session, icon: String? = nil) {
        self.id = session.id
        self.title = session.title ?? "Untitled"
        self.icon = icon
        self.lastMessageAt = session.lastMessageAt
        self.unreadCount = session.unreadCount
    }
}
```

**Topic Management (Adam's decisions):**
- **Creation:** Manual — user creates topics via "+" button in TopicBar
- **Deletion:** Manual — user deletes topics via context menu or swipe
- **Ordering:** Sorted alphabetically by `title`, case-insensitive, left-to-right
- **No auto-generation** from gateway sessions — topics are user-controlled
- **`icon`** is a UI-only field stored in UserDefaults (not in GRDB)

**Backend Mapping:**
- `TopicViewModel` derives from `Session` in GRDB
- `TopicViewModel.id` = `Session.id` (session key)
- `TopicViewModel.title` = `Session.title ?? "Untitled"` (handle nil safely)
- `TopicViewModel.lastMessageAt` = `Session.lastMessageAt`
- `TopicViewModel.unreadCount` = `Session.unreadCount`

---

## 3. Message Display

### 3.1 Message Bubble Design

**Adam's messages (right-aligned):**
- Background: Accent primary colour (amber/honey in Artisanal Tech)
- Text: Text primary (contrasting colour)
- Corner radius: 16pt (asymmetric: top-right squared for "sent" look)
- Max width: 66% of canvas width (fixed, no resizing)

**Bee's messages (left-aligned):**
- Background: Bg surface colour (ivory in Artisanal Tech)
- Text: Text primary colour (charcoal in Artisanal Tech)
- Corner radius: 16pt (asymmetric: top-left squared for "received" look)
- Max width: 66% of canvas width (fixed, no resizing)

**System messages (centered):**
- Background: Transparent
- Text: Text secondary colour, italicised
- Font size: 12pt
- Padding: 8pt vertical

### 3.2 Message Bubble Component

```swift
struct MessageBubble: View {
    @Environment(ThemeManager.self) var themeManager
    let message: Message
    let isFromUser: Bool
    
    var body: some View {
        HStack {
            if isFromUser {
                Spacer()
            }
            
            VStack(alignment: isFromUser ? .trailing : .leading, spacing: 4) {
                // Message content
                MessageContent(message: message)
                
                // Timestamp
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isFromUser ? themeManager.color(.accentPrimary) : themeManager.color(.bgSurface))
            )
            .foregroundColor(isFromUser ? themeManager.color(.textOnAccent) : themeManager.color(.textPrimary))
            .shadow(color: themeManager.color(.shadowMedium).opacity(0.1), radius: 4, x: 0, y: 2)
            
            if !isFromUser {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}
```

### 3.3 Media Handling

**Supported Media Types:**
- **Images** (inline display)
- **Files** (attachment cards with download)
- **Voice notes** (audio player with waveform)
- **Links** (rich previews, optional)

### 3.4 Image Display

```swift
struct ImageAttachment: View {
    let url: URL?
    let localPath: String?
    @State private var isExpanded = false
    
    var body: some View {
        Group {
            if let path = localPath, FileManager.default.fileExists(atPath: path) {
                Image(nsImage: NSImage(contentsOfFile: path)!)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 400, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { isExpanded = true }
            } else if let url = url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 400, maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onTapGesture { isExpanded = true }
                    case .failure:
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    @unknown default: EmptyView()
                    }
                }
            }
        }
        .sheet(isPresented: $isExpanded) {
            MediaViewer(imageURL: url, localPath: localPath)
        }
    }
}
```

### 3.5 File Attachment Card

```swift
struct FileAttachmentCard: View {
    @Environment(ThemeManager.self) var themeManager
    let fileName: String
    let fileSize: Int?
    let mimeType: String?
    let url: URL?
    let localPath: String?
    
    var body: some View {
        HStack(spacing: 12) {
            // File icon
            Image(systemName: iconForMimeType(mimeType))
                .font(.system(size: 32))
                .foregroundColor(themeManager.color(.accentPrimary))
            
            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(fileName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                
                if let size = fileSize {
                    Text(formatFileSize(size))
                        .font(.caption)
                        .foregroundColor(themeManager.color(.textSecondary))
                }
            }
            
            Spacer()
            
            // Download button (if remote)
            if url != nil && localPath == nil {
                Button(action: downloadFile) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 20))
                }
                .buttonStyle(.borderless)
            }
            
            // Open button
            Button(action: openFile) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(themeManager.color(.bgPanel))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 400)
    }
}
```

### 3.6 Voice Note Player

```swift
struct VoiceNotePlayer: View {
    @Environment(ThemeManager.self) var themeManager
    let audioURL: URL
    let duration: TimeInterval
    
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    
    var body: some View {
        HStack(spacing: 12) {
            // Play/Pause button
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 40, height: 40)
                    .background(themeManager.color(.accentPrimary))
                    .foregroundColor(themeManager.color(.textOnAccent))
                    .clipShape(Circle())
            }
            .buttonStyle(.borderless)
            
            // Waveform / progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Rectangle()
                        .fill(themeManager.color(.bgPanel))
                        .frame(height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    
                    // Progress
                    Rectangle()
                        .fill(themeManager.color(.accentPrimary))
                        .frame(width: geometry.size.width * (currentTime / duration), height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    
                    // Waveform overlay (optional, decorative)
                    WaveformView(progress: currentTime / duration)
                        .frame(height: 32)
                }
            }
            .frame(width: 200, height: 32)
            
            // Duration
            Text(formatTime(duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(themeManager.color(.textSecondary))
                .frame(width: 40)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(themeManager.color(.bgSurface))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
```

### 3.7 Typing Indicator

**Placement:** Bottom of message canvas, left-aligned (Bee's side), appears when `SyncBridge.didStartStreaming` is triggered.

**Behavior:**
- Shows when Bee starts generating response
- Hides when response is complete (`didStopStreaming`)
- Animates in/out with 200ms fade

**Design:**
- Three animated dots (classic typing indicator)
- Subtle bounce animation (sequential, 150ms delay between dots)
- Container: rounded rectangle, bg panel colour

```swift
struct TypingIndicator: View {
    @Environment(ThemeManager.self) var themeManager
    @State private var animations: [Bool] = [false, false, false]
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(themeManager.color(.textSecondary))
                    .frame(width: 8, height: 8)
                    .scaleEffect(animations[index] ? 1.2 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animations[index]
                    )
                    .onAppear {
                        animations[index] = true
                    }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(themeManager.color(.bgPanel))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 100, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
```

**Integration with SyncBridge:**
```swift
@ObservationIgnored
@Environment(SyncBridge.self) var syncBridge

var body: some View {
    ScrollView {
        // Messages...
        
        if syncBridge.isStreaming {
            TypingIndicator()
                .transition(.opacity)
        }
    }
}
```

> **HARD CONSTRAINT:** The `streamingBuffer` content is **NEVER** displayed in the UI. Only the `TypingIndicator` animation is shown while `isStreaming` is true. When streaming completes, the full message appears as a complete `MessageBubble`. No live/progressive text rendering.
```

---

## 4. Composer

### 4.1 Layout

```
┌─────────────────────────────────────────────────────────┐
│  [+ Attach]  [Multiline text input...]     [🎤] [Send] │
│              [Auto-expands: 2-6 lines]                  │
└─────────────────────────────────────────────────────────┘
```

**Dimensions:**
- Min height: 56pt (single line)
- Max height: 200pt (6 lines)
- Horizontal padding: 16pt
- Attachment button: 40x40pt touch target
- Send button: 40x40pt touch target
- Voice button: 40x40pt touch target

### 4.2 Composer Component

```swift
struct Composer: View {
    @Environment(ThemeManager.self) var themeManager
    @Binding var text: String
    @State private var isRecording = false
    @State private var showAttachmentPicker = false
    
    let onSend: () -> Void
    let onAttach: (AttachmentType) -> Void
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Attachment button
            Button(action: { showAttachmentPicker = true }) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 24))
                    .foregroundColor(themeManager.color(.textSecondary))
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .confirmationDialog("Attach", isPresented: $showAttachmentPicker) {
                Button("Photo") { onAttach(.image) }
                Button("File") { onAttach(.file) }
                Button("Voice Note") { onStartRecording() }
            }
            
            // Text input — NSTextView wrapper for reliable macOS auto-expand
            // (SwiftUI TextEditor has known quirks with .lineLimit ranges on macOS)
            MacTextView(text: $text)
                .font(.body)
                .frame(minHeight: 40, maxHeight: 160)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(themeManager.color(.bgPanel))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: text) { _, newText in
                    // Auto-scroll if needed
                }
            
            // Voice recording button
            Button(action: toggleRecording) {
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20))
                    .foregroundColor(isRecording ? .red : themeManager.color(.textSecondary))
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .background(isRecording ? Color.red.opacity(0.1) : Color.clear)
            .clipShape(Circle())
            
            // Send button
            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20))
                    .foregroundColor(text.isEmpty ? themeManager.color(.textSecondary) : themeManager.color(.textOnAccent))
            }
            .buttonStyle(.borderless)
            .frame(width: 40, height: 40)
            .background(
                Circle()
                    .fill(text.isEmpty ? themeManager.color(.bgPanel) : themeManager.color(.accentPrimary))
            )
            .disabled(text.isEmpty && !isRecording)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(themeManager.color(.bgSurface))
    }
    
    private func toggleRecording() {
        if isRecording {
            onStopRecording()
        } else {
            onStartRecording()
        }
        isRecording.toggle()
    }
}
```

### 4.3 Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| **Cmd+Enter** | Send message |
| **Enter** (default) | New line (multiline input) |
| **Cmd+Shift+A** | Open attachment picker |
| **Cmd+Shift+V** | Start/stop voice recording |
| **Escape** | Cancel recording / clear input |

### 4.4 Attachment Types

```swift
enum AttachmentType {
    case image(URL, Data?)
    case file(URL, String fileName, Int fileSize)
    case voiceNote(URL, TimeInterval duration, Data waveform)
}
```

**Backend Integration:**
- Attachments are uploaded to gateway via `chat.send` RPC call
- `attachments` parameter: array of `{ type, url, fileName, mimeType, fileSize }`
- Local media stored in `~/BeeChat/Media/` (outside `.openclaw` directory)
- Remote attachments cached on-view (download when first displayed, stored locally)
- Voice notes: M4A format, 30-second max duration
- Deleted messages: removed entirely (no placeholder/tombstone)

---

## 5. Theming Architecture

### 5.1 Design Token System

**Token Categories:**
1. **Colour Tokens** — semantic colour definitions
2. **Typography Tokens** — font families, sizes, weights
3. **Spacing Tokens** — margins, padding, gaps
4. **Radius Tokens** — corner radii
5. **Shadow Tokens** — shadows, glows
6. **Animation Tokens** — durations, easing curves

### 5.2 Colour Tokens (Artisanal Tech Base Theme)

```swift
enum ColorToken {
    // Backgrounds
    case bgSurface      // Ivory (#F8F6F0)
    case bgPanel        // Warm light gray (#EAE6DF)
    case bgElevated     // White (#FFFFFF)
    
    // Text
    case textPrimary    // Charcoal (#2D2D2D)
    case textSecondary  // Warm gray (#6B6B6B)
    case textOnAccent   // White (#FFFFFF)
    
    // Accents
    case accentPrimary  // Amber/Honey (#D4A574)
    case accentSecondary // Sage Green (#8FA895)
    case accentTertiary  // Terracotta (#C77D63)
    
    // Semantic
    case success        // Green (#4CAF50)
    case warning        // Amber (#FFC107)
    case error          // Red (#F44336)
    case info           // Blue (#2196F3)
    
    // Borders
    case borderSubtle   // Light gray (#E0E0E0)
    case borderDefault  // Medium gray (#BDBDBD)
}
```

### 5.3 Theme Manager

```swift
@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()
    
    var currentTheme: Theme
    var availableThemes: [ThemeMetadata]
    
    init() {
        self.currentTheme = .artisanalTech // Default
        self.availableThemes = [
            .dark, .light, .starfleetLCARS, .artisanalTech,
            .minimal, .holographicImperial, .waterFluidUI, .livingCrystal
        ]
        loadPersistedTheme()
    }
    
    func loadTheme(named id: String) async throws {
        // Load theme JSON from bundle
        // Apply tokens to appearance
    }
    
    func switchTheme(to id: String) async {
        guard let theme = availableThemes.first(where: { $0.id == id }) else { return }
        currentTheme = theme
        persistTheme(id: id)
    }
    
    func color(_ token: ColorToken) -> Color {
        currentTheme.colors[token] ?? .black
    }
    
    func font(_ token: TypographyToken) -> Font {
        currentTheme.typography[token]
    }
    
    func spacing(_ token: SpacingToken) -> CGFloat {
        currentTheme.spacing[token] ?? 0
    }
    
    private func loadPersistedTheme() {
        if let id = UserDefaults.standard.string(forKey: "selectedTheme") {
            // Load theme
        }
    }
    
    private func persistTheme(id: String) {
        UserDefaults.standard.set(id, forKey: "selectedTheme")
    }
}
```

### 5.4 Theme Switching Mechanism

**User Flow:**
1. User opens Settings → Appearance
2. Sees grid of 8 theme preview cards
3. Clicks theme card → preview applies immediately
4. Confirms selection → theme persists to UserDefaults

**Implementation:**
```swift
struct ThemePicker: View {
    @Environment(ThemeManager.self) var themeManager
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 16) {
                ForEach(themeManager.availableThemes) { theme in
                    ThemePreviewCard(theme: theme)
                        .onTapGesture {
                            Task {
                                await themeManager.switchTheme(to: theme.id)
                            }
                        }
                }
            }
            .padding()
        }
    }
}
```

### 5.5 Design Token Mapping to SwiftUI

```swift
// Example: MessageBubble using tokens
struct MessageBubble: View {
    @Environment(ThemeManager.self) var themeManager
    
    var body: some View {
        Text("Hello!")
            .font(themeManager.font(.body))
            .foregroundColor(themeManager.color(.textPrimary))
            .padding(themeManager.spacing(.md))
            .background(
                RoundedRectangle(cornerRadius: themeManager.radius(.lg))
                    .fill(themeManager.color(.bgSurface))
                    .shadow(
                        color: themeManager.color(.shadowMedium),
                        radius: themeManager.shadow(.md).blur,
                        x: themeManager.shadow(.md).offsetX,
                        y: themeManager.shadow(.md).offsetY
                    )
            )
    }
}
```

---

## 6. Component Inventory

### 6.1 Core Views

| Component | File | Purpose |
|-----------|------|---------|
| `AppRootView` | `UI/AppRootView.swift` | App entry point, `WindowGroup`, NSWindow configuration |
| `MainWindow` | `UI/MainWindow.swift` | Main chat window container |
| `MacTextView` | `UI/Components/MacTextView.swift` | `NSTextView` wrapper for reliable macOS multiline input |
| `SyncBridgeObserver` | `UI/Observers/SyncBridgeObserver.swift` | Bridges actor state to `@Observable` for SwiftUI |
| `TopicBar` | `UI/Components/TopicBar.swift` | Horizontal topic cycling |
| `TopicPill` | `UI/Components/TopicPill.swift` | Individual topic button |
| `MessageCanvas` | `UI/Components/MessageCanvas.swift` | Scrollable message list |
| `MessageBubble` | `UI/Components/MessageBubble.swift` | Individual message display (66% fixed width) |
| `MessageContent` | `UI/Components/MessageContent.swift` | Renders text + media blocks |
| `Composer` | `UI/Components/Composer.swift` | Input field + attachments (uses MacTextView) |
| `TypingIndicator` | `UI/Components/TypingIndicator.swift` | Bee's "thinking" state |

### 6.2 Media Components

| Component | File | Purpose |
|-----------|------|---------|
| `ImageAttachment` | `UI/Media/ImageAttachment.swift` | Inline image display |
| `FileAttachmentCard` | `UI/Media/FileAttachmentCard.swift` | File download card |
| `VoiceNotePlayer` | `UI/Media/VoiceNotePlayer.swift` | Audio playback with waveform |
| `MediaViewer` | `UI/Media/MediaViewer.swift` | Full-screen image/media viewer |
| `WaveformView` | `UI/Media/WaveformView.swift` | Audio waveform visualization (decorative — simple capsule progress bar in v1, full waveform deferred) |

### 6.3 Theming Components

| Component | File | Purpose |
|-----------|------|---------|
| `ThemeManager` | `UI/Theme/ThemeManager.swift` | Centralised theme state |
| `ThemePreviewCard` | `UI/Theme/ThemePreviewCard.swift` | Theme selection card |
| `ThemePicker` | `UI/Theme/ThemePicker.swift` | Settings panel for themes |
| `ColorToken` | `UI/Theme/Tokens/ColorToken.swift` | Colour token enum |
| `TypographyToken` | `UI/Theme/Tokens/TypographyToken.swift` | Typography token enum |
| `SpacingToken` | `UI/Theme/Tokens/SpacingToken.swift` | Spacing token enum |
| `RadiusToken` | `UI/Theme/Tokens/RadiusToken.swift` | Radius token enum |
| `ShadowToken` | `UI/Theme/Tokens/ShadowToken.swift` | Shadow token enum |
| `AnimationToken` | `UI/Theme/Tokens/AnimationToken.swift` | Animation token enum |

### 6.4 Utility Components

| Component | File | Purpose |
|-----------|------|---------|
| `ActivityIndicator` | `UI/Utilities/ActivityIndicator.swift` | Loading spinner |
| `ErrorBanner` | `UI/Utilities/ErrorBanner.swift` | Error message display |
| `ConfirmationDialog` | `UI/Utilities/ConfirmationDialog.swift` | Reusable dialog |
| `KeyboardShortcuts` | `UI/Utilities/KeyboardShortcuts.swift` | Global shortcut handler |

---

## 7. State Management

### 7.1 Data Flow Architecture

```
┌─────────────────┐
│   SyncBridge    │  ← WebSocket events, RPC calls
│   (Actor)       │
└────────┬────────┘
         │
         │ AsyncStream<[Session]>
         │ AsyncStream<[Message]>
         │
         ▼
┌─────────────────┐
│   GRDB          │  ← Persistence layer
│   (Database)    │
└────────┬────────┘
         │
         │ ValueObservation
         │
         ▼
┌─────────────────┐
│   SwiftUI       │  ← UI layer
│   (Views)       │
└─────────────────┘
```

### 7.2 Session State Flow

1. **SyncBridge** fetches sessions via `sessions.list` RPC
2. Sessions persisted to GRDB (`Session` table)
3. **SessionObserver** tracks changes via `ValueObservation`
4. SwiftUI views observe `SessionObserver` (not SyncBridge directly)
5. TopicBar updates when sessions change

```swift
// SessionObserver wraps GRDB ValueObservation
// ViewModel consumes from Observer, NOT from SyncBridge
@Observable
class SessionViewModel {
    private let observer: SessionObserver
    var sessions: [Session] = []
    var selectedSession: Session?
    
    init(observer: SessionObserver) {
        self.observer = observer
        Task {
            for await sessions in observer.sessionListStream() {
                self.sessions = sessions
            }
        }
    }
}
```

> **Note:** SyncBridge is an actor. ViewModels never access it directly for read operations. All reads flow through GRDB → ValueObservation → Observer → ViewModel. SyncBridge is only called directly for write operations (RPC calls like `chat.send`).
```

### 7.3 Message State Flow

1. **SyncBridge** receives `"chat"` events from gateway
2. Messages persisted to GRDB (`Message` table)
3. **MessageObserver** tracks changes per session
4. MessageCanvas observes `MessageObserver` (not SyncBridge directly)
5. Bubbles update in real-time

```swift
// MessageObserver wraps GRDB ValueObservation
// ViewModel consumes from Observer, NOT from SyncBridge
@Observable
class MessageViewModel {
    private let observer: MessageObserver
    var messages: [Message] = []
    let sessionKey: String
    
    init(observer: MessageObserver, sessionKey: String) {
        self.observer = observer
        self.sessionKey = sessionKey
        Task {
            for await messages in observer.messageStream(sessionKey: sessionKey) {
                self.messages = messages
            }
        }
    }
}
```
```

### 7.4 Streaming State

**SyncBridge Properties:**
- `currentStreamingSessionKey: String?` — which session is streaming
- `streamingBuffer: [String: String]` — accumulated text per session
- `isStreaming: Bool` — computed property

**UI Integration:**

SyncBridge is an actor — its properties cannot be read synchronously from SwiftUI. A `SyncBridgeObserver` bridges actor state to `@Observable`:

```swift
// Bridges actor state to @Observable for SwiftUI consumption
@Observable
class SyncBridgeObserver {
    var isStreaming: Bool = false
    var streamingSessionKey: String?
    
    init(syncBridge: SyncBridge) {
        Task {
            for await state in syncBridge.streamingStateStream() {
                self.isStreaming = state.isStreaming
                self.streamingSessionKey = state.sessionKey
            }
        }
    }
}

struct MessageCanvas: View {
    @Environment(SyncBridgeObserver.self) var observer
    @State var messages: [Message] = []
    
    var body: some View {
        ScrollView {
            ForEach(messages) { message in
                MessageBubble(message: message)
            }
            
            // Typing indicator only — buffer content is NEVER displayed
            if observer.isStreaming {
                TypingIndicator()
                    .transition(.opacity)
            }
        }
    }
}
```

> **HARD CONSTRAINT (repeated):** `streamingBuffer` content is **NEVER** rendered in the UI. The `TypingIndicator` animation is the only visible sign of streaming. When streaming completes, the full message appears as a complete `MessageBubble`.
```

### 7.5 Composer State

The Composer uses a custom `NSTextView` wrapper (not SwiftUI `TextEditor`) for reliable multiline auto-expand on macOS:

```swift
@Observable
class ComposerViewModel {
    var inputText: String = ""
    var isRecording: Bool = false
    var attachments: [Attachment] = []
    
    func sendMessage(sessionKey: String) async throws {
        guard !inputText.isEmpty else { return }
        try await syncBridge.sendMessage(
            sessionKey: sessionKey,
            text: inputText,
            attachments: attachments.map { $0.toDict() }
        )
        inputText = ""
        attachments = []
    }
    
    func startRecording() {
        isRecording = true
        // Start audio capture
    }
    
    func stopRecording() {
        isRecording = false
        // Process audio, create attachment
    }
}
```

---

## 8. Phase 4A/4B/4C Breakdown

### 8.1 Phase 4A: Core Chat Interface (Week 1-2)

**Goal:** Working chat UI with basic messaging, topic cycling, and typing indicator.

**Deliverables:**
- [ ] `AppRootView` — app entry point, window setup
- [ ] `MainWindow` — layout container (TopBar + Canvas + Composer)
- [ ] `TopicBar` + `TopicPill` — horizontal topic cycling
- [ ] `MessageCanvas` — scrollable message list
- [ ] `MessageBubble` — basic text messages (no media yet)
- [ ] `Composer` — text input + send button
- [ ] `TypingIndicator` — streaming state visual
- [ ] Theme integration (Artisanal Tech default)
- [ ] SyncBridge wiring (session list, message stream)

**Acceptance Criteria:**
- ✅ Can cycle through topics via top bar
- ✅ Can send text messages to Bee
- ✅ Bee's responses appear (full text, no streaming)
- ✅ Typing indicator shows while Bee is generating
- ✅ Messages persist across app restarts (GRDB)
- ✅ Artisanal Tech theme applied

**Not Included:**
- Media attachments (images, files, voice notes)
- Theme switching UI
- Keyboard shortcuts
- Advanced composer features (auto-expand, formatting)

---

### 8.2 Phase 4B: Media & Polish (Week 3-4)

**Goal:** Full media support, refined UX, keyboard shortcuts.

**Deliverables:**
- [ ] `ImageAttachment` — inline image display
- [ ] `FileAttachmentCard` — file download cards
- [ ] `VoiceNotePlayer` — audio playback
- [ ] `MediaViewer` — full-screen media viewer
- [ ] `Composer` — attachment picker, voice recording
- [ ] `KeyboardShortcuts` — Cmd+Enter send, Cmd+Shift+A attach
- [ ] `ThemePicker` — theme selection panel
- [ ] Auto-expand composer (2-6 lines)
- [ ] Message timestamps, read states

**Acceptance Criteria:**
- ✅ Can attach images (inline display)
- ✅ Can attach files (download card)
- ✅ Can record & send voice notes
- ✅ Can view media full-screen
- ✅ Cmd+Enter sends message
- ✅ Can switch themes via Settings
- ✅ Composer auto-expands with text

**Not Included:**
- Link previews
- Message reactions
- Search functionality
- Settings beyond theme picker

---

### 8.3 Phase 4C: Accessibility & Performance (Week 5)

**Goal:** Accessibility compliance, performance optimisation, bug fixes.

**Deliverables:**
- [ ] VoiceOver labels on all interactive elements
- [ ] Keyboard navigation (Tab, Arrow keys)
- [ ] Focus rings for accessibility
- [ ] Reduce Motion support (animated effects)
- [ ] Performance profiling (60 FPS target)
- [ ] Memory optimisation (< 200MB)
- [ ] Bug fixes from 4A/4B testing
- [ ] Documentation (README, component docs)

**Acceptance Criteria:**
- ✅ VoiceOver announces all buttons, messages, topics
- ✅ Full keyboard navigation (no mouse required)
- ✅ Reduce Motion disables animations
- ✅ App maintains 60 FPS during scrolling
- ✅ Memory usage < 200MB (typical session)
- ✅ All critical bugs resolved
- ✅ Documentation complete

---

## 9. Integration Points

### 9.1 SyncBridge Integration

**Required SyncBridge Methods:**
```swift
// Session management
func sessionListStream() -> AsyncStream<[Session]>
func fetchSessions() async throws -> [Session]

// Message management
func messageStream(sessionKey: String) -> AsyncStream<[Message]>
func fetchHistory(sessionKey: String, limit: Int?) async throws -> [Message]
func sendMessage(sessionKey: String, text: String, thinking: String?, attachments: [[String: Any]]?) async throws -> String

// Streaming state
var currentStreamingSessionKey: String? { get }
var isStreaming: Bool { get }

// Connection state
func connectionStateStream() -> AsyncStream<ConnectionState>
```

### 9.2 Persistence Integration

**GRDB Tables:**
- `sessions` — topic/session metadata
- `messages` — message content + metadata
- `attachments` — file/image/voice note metadata

**ValueObservations:**
- `SessionObserver.observeSessions()` — topic list updates
- `MessageObserver.observeMessages(sessionKey:)` — message list updates

### 9.3 Gateway Integration

**RPC Calls:**
- `sessions.list` — fetch all sessions (topics)
- `sessions.subscribe` — subscribe to session changes
- `chat.history` — fetch message history
- `chat.send` — send message (with attachments)
- `chat.abort` — abort streaming response

**Events:**
- `"chat"` — streaming events (delta/final/error)
- `"sessions.changed"` — session list invalidation

---

## 10. Decisions Log (Resolved)

### 10.1 Topic Management

**Q1:** Can users create/delete topics, or are they auto-generated from sessions?
- **DECISION (Adam, 2026-04-18):** Manual creation and deletion only. No auto-generation from gateway sessions. Project folder linking is a future feature.

**Q2:** How are topics ordered?
- **DECISION (Adam, 2026-04-18):** Alphanumeric left-to-right. Drag-to-reorder is a future feature.

### 10.2 Media Storage

**Q3:** Where are attachments stored locally?
- **DECISION (Adam, 2026-04-18):** Outside `.openclaw` directory. Dedicated `~/BeeChat/Media/` folder.

**Q4:** Do we cache remote attachments, or download on-demand?
- **DECISION:** Cache on-view (download when first displayed, store locally in `~/BeeChat/Media/`)

### 10.3 Voice Notes

**Q5:** Voice note format?
- **DECISION (Adam, 2026-04-18):** M4A (most common, broad compatibility)

**Q6:** Max voice note duration?
- **DECISION (Adam, 2026-04-18):** 30 seconds

### 10.4 Deleted Messages

- **DECISION (Adam, 2026-04-18):** Remove entirely. No placeholder/tombstone.

### 10.5 Message Bubble Width

- **DECISION (Adam, 2026-04-18):** 66% of window width as default. User-resizable bubbles (drag to adjust width) is a future feature.

---

## 11. Appendix

### 11.1 Artisanal Tech Theme Specification

**Colours:**
```
bgSurface:      #F8F6F0  (Ivory)
bgPanel:        #EAE6DF  (Warm light gray)
bgElevated:     #FFFFFF  (White)
textPrimary:    #2D2D2D  (Charcoal)
textSecondary:  #6B6B6B  (Warm gray)
accentPrimary:  #D4A574  (Amber/Honey)
accentSecondary:#8FA895  (Sage Green)
accentTertiary: #C77D63  (Terracotta)
```

**Typography:**
```
font-family-base: SF Pro (or theme serif: Literata, Merriweather)
font-family-mono: SF Mono
font-size-sm:     12pt
font-size-md:     14pt
font-size-lg:     16pt
font-size-xl:     20pt
```

**Spacing:**
```
spacing-xs:  4pt
spacing-sm:  8pt
spacing-md:  12pt
spacing-lg:  16pt
spacing-xl:  24pt
spacing-xxl: 32pt
```

**Radius:**
```
radius-sm:  4pt
radius-md:  8pt
radius-lg:  12pt
radius-xl:  16pt
radius-full: 9999pt
```

---

### 11.2 Component Compliance Checklist

All components must comply with:
- [ ] Design token usage (no hard-coded colours/sizes)
- [ ] Theme Manager integration
- [ ] Accessibility labels (VoiceOver)
- [ ] Keyboard navigation
- [ ] Hover states (macOS)
- [ ] Error handling (graceful degradation)
- [ ] Performance (60 FPS target)

---

### 11.3 Related Documents

- `TEAM-CONSENSUS-SIMPLIFIED-PATH.md` — Backend architecture consensus
- `DESIGN-SYSTEM.md` — Cross-platform design token system
- `COMPONENT-3-SYNC-BRIDGE-SPEC.md` — SyncBridge specification
- `COMPONENT-1-PERSISTENCE-SPEC.md` — GRDB persistence spec

---

**Last Updated:** 2026-04-18  
**Next Review:** After Adam/Mel/Neo feedback  
**Implementation Start:** Upon approval
