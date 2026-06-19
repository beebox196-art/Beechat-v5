# FEAT-010: Clickable File Links in Messages

**Priority:** Medium
**Status:** Spec reviewed — implementation in progress
**Author:** Bee (Coordinator)
**Reviewer:** Kieran
**Date:** 2026-05-06

## Problem

Assistant messages frequently contain file paths and file URLs (e.g. `/Users/openclaw/Desktop/report.md`, `~/Projects/file.swift`, `file:///Users/...`) and backtick-wrapped paths (`` `/some/path` ``). These are currently rendered as plain text in `MessageContent.swift` — users cannot open them without manually copying and pasting the path into Finder or Terminal.

## Goal

Detect file paths and `file://` URLs in message text and render them as tappable links that open the file or folder in the appropriate macOS application. Preserve existing text selection and theme styling. Keep streaming message rendering unchanged for v1.

## Scope

### 1. Path Detection Regex

Match the following patterns in message content:

| Pattern | Example |
|---|---|
| Absolute paths under `/Users/...` | `/Users/openclaw/Projects/BeeChat-v5/README.md` |
| Home-relative paths starting with `~/` | `~/.zshrc`, `~/Projects/foo.swift` |
| `file:///` URLs | `file:///Users/openclaw/Desktop/report.pdf` |
| Backtick-wrapped paths | `` `/Users/openclaw/Desktop/report.md` `` |

**Backtick handling:** When a path is wrapped in backticks, render the clickable text as the path without backticks but styled as a link. The backticks themselves are not displayed; they serve purely as a detection hint.

**Explicitly excluded (must NOT match):**
- `https://` or `http://` URLs — let the browser handle these elsewhere if needed
- JSON keys, Swift imports, or other slash-containing code snippets that do not resolve to actual file system paths
- Relative paths (e.g. `./foo.swift`, `../bar.md`) — high false-positive rate; defer to future spec
- Paths outside known safe prefixes (e.g. `/usr/bin/`, `/System/`) — limit to user data directories for v1

**Regex approach (v1):**
```swift
let patterns = [
    #"`(/Users/[^`\s]+)`"#,                        // backtick absolute (checked first)
    #"`(~/[^`\s]+)`"#,                             // backtick home-relative (checked first)
    #"file://(/[^\s]+)"#,                          // captures path after file://
    #"/Users/[^\s\.\)\]\,\;]+"#,                  // absolute user paths — trailing punctuation stripped
    #"~/[^\s\.\)\]\,\;]+"#                        // home-relative — trailing punctuation stripped
]
```

**Trailing punctuation stripping:** Before running the existence check, strip any trailing `.`, `,`, `)`, `]`, `:`, `;` from matched bare paths. The regex above excludes these characters from the match itself, but if a future regex revision allows them, the parser must strip them before resolving the path.

### 1a. Pattern Priority

Backtick-wrapped patterns are checked **first** and mark their matched ranges as consumed. Bare absolute/home-relative patterns run second and skip any ranges already consumed by backtick matches. This prevents a backtick-wrapped path like `` `/Users/foo/bar.md` `` from also being partially matched as a bare `/Users/foo/bar.md` inside the backticks.

### 2. Rendering: Composite Text View with AttributedString

**Approach:** Parse message content into segments — a mix of plain `String` text runs and `FileLink` link objects — then build a composite SwiftUI `Text` view by concatenating `Text` instances.

```swift
enum ContentSegment {
    case text(String)
    case link(path: String, displayText: String)
}
```

Build process:
1. Scan content left-to-right with regexes (backtick first, then bare)
2. Strip trailing punctuation from bare matches before storing
3. Produce `[ContentSegment]` preserving order
4. Build composite `Text`:
   ```swift
   var result = Text("")
   for segment in segments {
       switch segment {
       case .text(let str):
           result = result + Text(str)
       case .link(let path, let display):
           var attr = AttributedString(display)
           attr.foregroundColor = themeManager.color(.accentPrimary)
           attr.underlineStyle = .single
           // tap handling — see Section 3
           result = result + Text(attr)
       }
   }
   ```

**Preserve existing styling:**
- `.font(themeManager.font(.body))` applied to the outer container
- `.textSelection(.enabled)` applied to the outer container — users can still select and copy the full message including links

**Text selection vs tap gesture conflict (Known Issue):** SwiftUI's `.onTapGesture` inside `.textSelection(.enabled)` text can conflict. Must be validated in UI testing. Consider `.simultaneousGesture` or a short-threshold `DragGesture` to distinguish taps from selection drags.

**No model changes needed:** `Message` in `BeeChatPersistence` remains `content: String?`.

### 3. Link Tap Action

**Tilde resolution (Kieran fix):** Replace naive `replacingOccurrences(of: "~", with: ...)` with proper single-leading-tilde resolution. Only replace a leading `~` using `NSString.standardizingPath` or manual `hasPrefix("~")` + `dropFirst()` + home directory prepend. Do NOT replace `~` characters that appear later in the path.

```swift
func resolvePath(_ path: String) -> String {
    if path.hasPrefix("~") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }
    return path
}
```

**Path traversal guard (post-match validation):** After resolving a path, validate that the standardised path starts with `/Users/`. Reject paths that resolve outside the user's home directory tree. This is a defence-in-depth step after regex matching.

```swift
let resolved = (path as NSString).standardizingPath
let home = FileManager.default.homeDirectoryForCurrentUser.path
let usersPrefix = "/Users/"
guard resolved.hasPrefix(usersPrefix) || resolved.hasPrefix(home) else {
    // Treat as plain text — do not render as link
    return .text(originalMatch)
}
```

**Tap handler (macOS):**
```swift
let resolvedPath = resolvePath(path)
let url = URL(fileURLWithPath: resolvedPath)
if FileManager.default.fileExists(atPath: url.path) {
    NSWorkspace.shared.open(url)
} else {
    // Greyed-out style already applied at render time; tap is no-op
}
```

**Visual feedback for missing files:**
- If file DOES NOT exist at render time: apply secondary/grey colour and remove underline
- If file DOES exist: apply accent colour + underline
- Render-time existence check is lightweight (single `FileManager` call per link)

**Right-click / long-press (Out of Scope for v1):** A context menu with "Show in Finder" is desirable but deferred to FEAT-011. For v1, a single tap opens the file directly.

### 3a. Existence Cache

Add a `[String: Bool]` cache in the `FileLinkText` helper, keyed by resolved absolute path. This avoids re-running `FileManager.fileExists` on every scroll re-render.

- Cache entry includes a 30-second TTL (timestamp + result)
- Invalidate on `onDisappear` of the view
- If a file is created after message render, the link stays greyed-out until the view re-renders (acceptable for v1)

```swift
struct FileExistenceCache {
    private var entries: [String: (result: Bool, timestamp: Date)] = [:]
    private let ttl: TimeInterval = 30

    mutating func check(_ path: String) -> Bool {
        let now = Date()
        if let entry = entries[path], now.timeIntervalSince(entry.timestamp) < ttl {
            return entry.result
        }
        let result = FileManager.default.fileExists(atPath: path)
        entries[path] = (result, now)
        return result
    }

    mutating func invalidate() {
        entries.removeAll()
    }
}
```

### 4. Link Visual Style

| State | Style |
|---|---|
| File exists | Accent colour (`themeManager.color(.accentPrimary)`), single underline |
| File missing | Secondary/grey colour, no underline, still selectable as text |
| Hover | macOS standard pointer cursor change (`.onHover` → `NSCursor.pointingHand`) |

**Underlining:** Use `AttributedString` `.underlineStyle = .single` for the link portion only. Plain text runs remain ununderlined.

### 5. StreamingBubble — Excluded from Link Detection

**Decision:** `StreamingBubble.swift` renders text as it arrives from the AI. Detecting paths during streaming is risky because:
- Partial paths (e.g. `/Users/openclaw/Pro`) are not valid and would produce broken links
- Regex re-evaluation on every character update is wasteful
- The streaming text is transient; the final rendered message in `MessageContent` is canonical

**Action:** Leave `StreamingBubble` unchanged for v1. Once the message is persisted and rendered via `MessageContent`, links appear.

### 6. Security Considerations

| Concern | Mitigation |
|---|---|
| Code execution | Only `NSWorkspace.shared.open(URL)` — opens in default app, never executes |
| Unsafe paths | Regex limited to `/Users/`, `~/`, and `file:///Users/` prefixes only |
| Auto-open | Always requires explicit user tap; no automatic opening |
| Sandbox | BeeChat currently does not use App Sandbox; if sandboxed later, add `com.apple.security.files.user-selected.read-only` entitlement |
| Symlinks / traversal | `FileManager.fileExists(atPath:)` resolves symlinks; paths outside `/Users/` rejected by traversal guard |
| Path traversal guard | Post-match validation ensures standardised resolved path starts with `/Users/` |

## Architecture

### Files Changed

| File | Change |
|---|---|
| `Sources/App/UI/Components/MessageContent.swift` | **MODIFY** — replace plain `Text(content)` with `FileLinkText(content: content)` |
| `Sources/App/UI/Components/FileLinkText.swift` | **NEW** — helper view that builds composite `Text` from `[ContentSegment]`, includes regex parser, existence cache, tilde resolution, and path traversal guard |

### No changes to:
- `MessageBubble.swift` — wraps `MessageContent` unchanged
- `StreamingBubble.swift` — excluded from link detection per Section 5
- `Message` model — `content: String?` remains sufficient
- `ThemeManager` — existing accent colour and font APIs used as-is

### Data Flow

```
Message persisted in GRDB
    ↓
MessageViewModel loads messages
    ↓
MessageBubble renders MessageContent(message)
    ↓
FileLinkText parses content into [ContentSegment]
    ├── regex scan: backtick patterns first, then bare patterns
    ├── strip trailing punctuation from bare matches
    ├── resolve tilde → home directory (single leading ~ only)
    ├── path traversal guard (must be under /Users/)
    ├── existence check per resolved path (cached, 30s TTL)
    └── build AttributedString links + plain text runs
    ↓
Composite Text view rendered with .textSelection(.enabled)
    ↓
User taps link → NSWorkspace.open(URL)
```

## Edge Cases

| Case | Behaviour |
|---|---|
| Path at end of sentence (e.g. "see `/Users/foo.md`.") | Trailing punctuation stripped before existence check; period remains plain text |
| Multiple paths in one message | Each matched independently; all rendered as separate links |
| Path inside a code block (triple backticks) | Same regex applies; paths become clickable links. If this proves noisy, revisit in v2. |
| Path contains spaces | Not matched by v1 regex (spaces terminate match). User can still select/copy. |
| `~` resolved to different home directory | Uses `FileManager.default.homeDirectoryForCurrentUser` at runtime |
| File deleted after render | Tap is no-op; greyed-out style already indicates missing file |
| File created after render | Style reflects existence at render time only; accept minor staleness for v1 |
| Backtick path overlaps bare path | Backtick pattern runs first and marks range consumed; bare regex skips consumed ranges |
| Tilde in middle of path | Only leading `~` is resolved; `~` elsewhere is preserved as literal character |
| Symlink resolves outside /Users/ | Traversal guard checks standardised resolved path; rejects if outside `/Users/` |

## Out of Scope (Explicit)

- Relative paths (`./`, `../`) — high false-positive rate in code discussion
- `http://` / `https://` URL rendering — distinct feature, may conflict with existing link handling
- Right-click "Show in Finder" context menu — deferred to FEAT-011
- Link detection in `StreamingBubble` — streaming text is partial and transient
- Dynamic style updates when file appears/disappears after render
- Non-`Users` paths (e.g. `/Applications/`, `/Library/`) — limit to user data for v1
- Custom link hover tooltip with file metadata

## Testing Approach

1. **Unit test regex matcher:** Create `FilePathParserTests.swift` with a table of inputs and expected `[ContentSegment]` outputs covering all match/exclude cases above.
2. **UI test:** Send a message containing a valid `/Users/...` path → verify link renders in accent colour and tapping it opens the file.
3. **UI test:** Send a message containing an invalid path → verify link renders grey with no underline and tapping is no-op.
4. **Regression test:** Confirm `.textSelection(.enabled)` still allows full-message selection and copy.
5. **Regression test:** Confirm `StreamingBubble` continues to render streaming text without link styling.
6. **UI test:** Confirm tap gesture does not interfere with text selection drag gestures.

## Review History

- **Kieran review (2026-05-06):** 7 findings incorporated:
  1. Trailing punctuation stripping added to regex spec and parser logic
  2. Backtick pattern priority documented — backtick patterns run first, mark consumed ranges
  3. Tilde resolution fixed — single leading `~` only, no `replacingOccurrences`
  4. Path traversal guard added — standardised path must start with `/Users/`
  5. Existence cache added — `[String: Bool]` with 30-second TTL, invalidated on disappear
  6. Text selection vs tap gesture noted as known issue requiring UI testing
  7. Staleness note added — file created after render stays grey until re-render (acceptable for v1)
