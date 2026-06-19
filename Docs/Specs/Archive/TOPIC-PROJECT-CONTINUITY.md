# Spec: Topic–Project Context Continuity

**Created:** 2026-05-30T18:31:00+01:00  
**Author:** Q (sub-agent, Adam via Bee)  
**Status:** DRAFT v4 — All reviews applied + final gate fixes (path normalization, iOS wording, call-sites, accessibility). Adam approved for implementation. 🚀
**Reviewed by:** Kieran (2026-05-30) — APPROVE-WITH-CHANGES (3 critical + 5 warnings resolved) | Mel (2026-05-30) — APPROVE-WITH-CHANGES (2 critical + 6 warnings)  
**Target:** BeeChat-v5 (macOS app + iOS via gateway)

---

## 1. Root Cause Analysis

### 1.1 What exists today

`Topic.swift` already stores `projectPath` inside `metadataJSON` and validates it on macOS.  
`SyncBridge.sendMessage()` already injects a `[TOPIC-CONTEXT]` / `[PROJECT-CONTEXT]` header — **but it only tells the agent to read the files, it doesn't read them itself**:

```swift
func buildContextHeader(topic: Topic) -> String {
    var header = "[TOPIC-CONTEXT]\nTopic: \(topic.name)"
    if let projectPath = topic.projectPath {
        header += "\n[PROJECT-CONTEXT]\nProject: \(projectPath)"
        header += "\nRead \(projectPath)STATUS.md for project context."
        header += "\nRead \(projectPath)decisions.md and \(projectPath)corrections.md if they exist."
        header += "\nWhen this session ends or significant progress is made, append a dated entry to \(projectPath)ACTIVITY.md using the format: ### YYYY-MM-DD — One-line summary."
    }
    return header
}
```

This header instructs the agent to use `read` tool calls to fetch STATUS.md, README.md, decisions.md, corrections.md — **on every new session**. That means:

1. **Extra token burn** — agent spends tokens discovering and reading files each time.
2. **Stale project state** — project files never get updated by the conversation. Adam has to manually tell the agent what happened.
3. **No continuity between sessions** — after a reset, the agent forgets everything the user and agent decided together.
4. **iOS blind spot** — on iOS, `projectPath` exists in metadata but there's no local filesystem to read from; the Mac must provide the file content.

### 1.2 The metadata drop-through bug

There's a second, independent defect in `MessageViewModel.sendMessage()`:

```swift
let topic: Topic? = topics.first(where: { $0.id == topicId })
    .map { Topic(id: $0.id, name: $0.title, sessionKey: $0.sessionKey) }
```

`TopicViewModel` does **not** carry `metadataJSON` or `projectPath`. The `Topic` object passed to `SyncBridge.sendMessage()` is reconstructed from `TopicViewModel` fields — **without** `metadataJSON`. So even though the topic has a project binding in the database, the injected Topic object has `projectPath == nil`. The context header is never built for project-bound topics in the current code.

### 1.3 Summary of gaps

| Gap | Impact |
|---|---|
| `buildContextHeader` tells agent to read files but doesn't provide content | Wastes tokens; agent must spend turn 1 reading files |
| `TopicViewModel` drops `metadataJSON` | Project context header is never injected even when bound |
| No write-back to project files | Conversation knowledge dies with the session |
| No cross-device content sharing | iOS cannot read project files |

---

## 2. Evaluated Approaches

### Approach A: App-Level File Read + Prompt Injection (Recommended)

**What:** When a project-bound topic is active, BeeChat reads STATUS.md, README.md, and optionally decisions.md/corrections.md from the local filesystem, then prepends their content to the `[PROJECT-CONTEXT]` header sent to the agent. No gateway protocol change needed — it's just longer text in `chat.send`.

**Mechanism:**
1. `SyncBridge.buildContextHeader(topic:)` is upgraded to actually read the files at `projectPath`.
2. File content is injected inline into the context header.
3. On first send to a project-bound session, the agent receives full project state as part of the system message.
4. `TopicViewModel` gains `metadataJSON` passthrough so the project path survives the UI→Bridge pipeline.

**Pros:**
- Simple — no protocol changes, no new RPCs
- Works on both macOS and iOS (Mac reads files, iOS receives content via gateway text)
- Deterministic — files are read at send time, always fresh
- Token-efficient — one read per session start instead of agent-driven multi-tool discovery
- No new UI surface

**Cons:**
- Project file content adds ~2-8KB to first message per session (budget: 100K context window)
- Files must exist at `projectPath` (error handling required)
- Doesn't write back to project files (see Approach B for write-back)

### Approach B: Auto Write-Back to Project STATUS.md (Phase 2)

**What:** After every N messages (default 5) or after session stream ends, BeeChat appends a dated summary entry to `projectPath/ACTIVITY.md` and optionally updates `STATUS.md` with current work status.

**Mechanism:**
1. New `ProjectFileWriter` utility reads recent messages from local SQLite.
2. On `processChatFinal` or after message-count threshold, generates a 1-2 line summary.
3. Appends to `projectPath/ACTIVITY.md` with format: `### YYYY-MM-DD — Summary`.
4. Writes happen on Mac only (file system access), paths validated.

**Pros:**
- Project files stay current without manual intervention
- Next session's read picks up the latest state
- Creates a dated activity log useful for Adam

**Cons:**
- Non-trivial: summarisation needs either an LLM call or heuristic extraction
- Risk of noisy write-backs (garbage summaries degrade STATUS.md quality)
- iOS cannot write directly — needs gateway RPC to ask Mac to write
- Adds complexity: threshold config, dedup, error recovery

**Verdict:** Valuable, but should be Phase 2. Phase 1 (read-only injection) delivers 80% of the value at 20% of the complexity.

### Approach C: Project Context Panel in UI (Supplementary)

**What:** Show STATUS.md content in a sidebar panel within the topic view.

**Pros:**
- User-visible, so Adam can verify what context the agent sees
- Useful for quick reference without switching to project folder

**Cons:**
- Purely cosmetic — doesn't solve the agent context gap
- Additional UI surface in an already crowded sidebar
- Requires separate state management, refresh logic

**Verdict:** Nice-to-have. Not a core solution. Can be built later as a polish feature.

### Approach D: Gateway Session Metadata (Rejected)

**What:** Store project context in gateway session metadata so any agent spawned for that topic automatically gets the files.

**Pros:**
- Clean architectural boundary

**Cons:**
- Requires gateway protocol changes (`sessions.setMetadata` or similar)
- Gateway is a separate component (OpenClaw core) — we cannot modify it without upstream changes
- Doesn't solve iOS content delivery (gateway metadata is local to the Mac)
- Over-engineered for a problem solvable at the app level

**Verdict:** Blocked by gateway protocol. Not viable as a BeeChat-only change.

---

## 3. Recommended Implementation

### Phase 1: Read Project Files into Context Header

#### 3.1 Fix the metadata passthrough (Kieran Critical-3: Hashable identity)

**File:** `Sources/App/UI/ViewModels/TopicViewModel.swift`

Add `projectPath` as a computed passthrough. **Critical:** explicit `Hashable` conformance that only considers `id` — prevents silent breakage of any `Set`/`Dictionary` keyed by `TopicViewModel`.

```swift
struct TopicViewModel: Identifiable, Hashable {
    let id: String
    var title: String
    var icon: String?
    var sessionKey: String?
    var lastActivityAt: Date?
    var unreadCount: Int
    var messageCount: Int
    var projectPath: String?  // NEW — sourced from Topic.metadataJSON

    init(from topic: Topic, icon: String? = nil) {
        self.id = topic.id
        self.title = topic.name
        self.icon = icon
        self.sessionKey = topic.sessionKey
        self.lastActivityAt = topic.lastActivityAt
        self.unreadCount = topic.unreadCount
        self.messageCount = topic.messageCount
        self.projectPath = topic.projectPath  // NEW
    }

    // Explicit Hashable: identity-only (Kieran Critical-3)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TopicViewModel, rhs: TopicViewModel) -> Bool {
        lhs.id == rhs.id
    }
}
```

**File:** `Sources/App/UI/ViewModels/MessageViewModel.swift`

Change the Topic reconstruction in `sendMessage()` to include `metadataJSON`:

```swift
let topic: Topic? = topics.first(where: { $0.id == topicId }).map { vm in
    var t = Topic(id: vm.id, name: vm.title, sessionKey: vm.sessionKey, metadataJSON: nil)
    // Set projectPath via the mutating setter
    if let path = vm.projectPath {
        try? t.setProjectPath(path)
    }
    return t
}
```

Or better: add `metadataJSON` to `TopicViewModel` and pass it through directly, avoiding the round-trip through `setProjectPath()`.

#### 3.2 New utility: read project files (Kieran Critical-1: Path traversal, Critical-2: Byte counting)

**File:** `Sources/BeeChatSyncBridge/Utilities/ProjectContextReader.swift` (NEW)

Key fixes from Kieran review:
- **Critical-1:** Path validation inside `read()` — rejects anything outside `/Users/openclaw/Projects/`
- **Critical-2:** UTF-8 byte-counting for truncation, not `String.count` (character count)
- **Warning-4:** Extension whitelist — only reads `.md`, `.txt`, `.json`, `.yaml`, `.yml`, `.toml`

```swift
import Foundation

/// Reads project context files from a project directory.
/// Returns a formatted string suitable for injection into the context header.
public enum ProjectContextReader {

    /// Allowed path prefix for security (Kieran Critical-1)
    private static let allowedPrefix = "/Users/openclaw/Projects/"

    /// Allowed file extensions for safety (Kieran Warning-4)
    private static let allowedExtensions = Set(["md", "txt", "json", "yaml", "yml", "toml"])

    /// Files to read, in order. Each entry: (filename, required, maxBytes)
    private static let contextFiles: [(name: String, required: Bool, maxBytes: Int)] = [
        ("STATUS.md", true, 8192),
        ("README.md", false, 8192),
        ("decisions.md", false, 4096),
        ("corrections.md", false, 4096),
    ]

    /// Validate that projectPath is within the allowed directory and resolves cleanly.
    /// Resolves symlinks to defeat symlink-escape attacks.
    private static func validatePath(_ projectPath: String) -> Bool {
        // Kieran residual: normalize path before prefix check
        // Defeats /./..// traversal tricks
        let normalized = (projectPath as NSString).standardizingPath

        // Resolve symlinks to canonical path
        let resolved: String
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: normalized) {
            resolved = (dest as NSString).standardizingPath
        } else {
            resolved = normalized
        }
        guard resolved.hasPrefix(allowedPrefix) else { return false }
        guard FileManager.default.fileExists(atPath: resolved) else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else { return false }
        return true
    }

    /// Read and format project context files.
    /// - Parameters:
    ///   - projectPath: Absolute path to the project directory.
    ///   - maxTotalBytes: Cap on total output size in UTF-8 bytes (default 16KB).
    /// - Returns: Formatted context string, or empty string if projectPath is nil/invalid.
    public static func read(projectPath: String, maxTotalBytes: Int = 16_384) -> String {
        // Kieran Critical-1: validate path before any file access
        guard validatePath(projectPath) else {
            print("[ProjectContextReader] Rejected path: \(projectPath)")
            return ""
        }

        var output: [String] = []
        var totalBytes = 0

        for (filename, required, maxBytes) in contextFiles {
            guard totalBytes < maxTotalBytes else { break }

            // Kieran Warning-4: extension check
            let ext = (filename as NSString).pathExtension
            guard allowedExtensions.contains(ext) else { continue }

            let filePath = (projectPath as NSString).appendingPathComponent(filename)
            guard let content = readFile(at: filePath, maxBytes: maxBytes) else {
                if required {
                    output.append("** \(filename) NOT FOUND **")
                }
                continue
            }

            // Kieran Critical-2: byte-based truncation, not character count
            let contentBytes = content.utf8
            let remainingBytes = maxTotalBytes - totalBytes
            let truncated: String
            if contentBytes.count > remainingBytes {
                let prefixBytes = contentBytes.prefix(remainingBytes)
                truncated = String(data: Data(prefixBytes), encoding: .utf8) ?? ""
                    + "\n... [truncated to \(remainingBytes) bytes]"
            } else {
                truncated = content
            }

            output.append("--- \(filename) ---\n\(truncated)")
            totalBytes += truncated.utf8.count
        }

        if output.isEmpty { return "" }
        return output.joined(separator: "\n\n")
    }

    private static func readFile(at path: String, maxBytes: Int) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard var content = String(data: data, encoding: .utf8) else { return nil }

        // Kieran Critical-2: UTF-8 byte truncation
        let contentBytes = content.utf8
        if contentBytes.count > maxBytes {
            let prefixBytes = contentBytes.prefix(maxBytes)
            content = String(data: Data(prefixBytes), encoding: .utf8) ?? content
        }
        return content
    }
}
```

#### 3.3 Upgrade `buildContextHeader` (Kieran Warning-3: Context budget guard, Warning-5: File modification timestamp)

**File:** `Sources/BeeChatSyncBridge/SyncBridge.swift`

Key fixes:
- **Warning-3:** Combined context-size guard (auto-reset + topic context capped at 50KB)
- **Warning-5:** "Read at" timestamp uses file modification date, not `Date.now`

```swift
func buildContextHeader(topic: Topic) -> String {
    var header = "[TOPIC-CONTEXT]\nTopic: \(topic.name)"

    guard let projectPath = topic.projectPath else { return header }

    header += "\n[PROJECT-CONTEXT]\nProject: \(URL(fileURLWithPath: projectPath).lastPathComponent)"
    header += "\nProject path: \(projectPath)"
    header += "\n---"

    // Read and inject actual file content
    let projectContent = ProjectContextReader.read(projectPath: projectPath)
    if !projectContent.isEmpty {
        header += "\n\(projectContent)"
    } else {
        header += "\n(no project files found)"
    }

    header += "\n---"
    // Kieran Warning-5: use file modification time, not Date.now
    let statusPath = (projectPath as NSString).appendingPathComponent("STATUS.md")
    if let modDate = try? FileManager.default.attributesOfItem(atPath: statusPath)[.modificationDate] as? Date {
        header += "\nProject context read at \(modDate.formatted(date: .abbreviated, time: .shortened))."
    } else {
        header += "\nProject context read at \(Date.now.formatted(date: .abbreviated, time: .shortened))."
    }
    header += "\nUse the project files above as your working context. Reference STATUS.md for current state before making changes."

    return header
}
```

**Context budget guard (Kieran Warning-3):** In `SyncBridge.sendMessage()`, the guard `if !didAutoReset` already prevents topic context injection when auto-reset fires. To add an explicit safety net:

```swift
// After building combined context (auto-reset + topic):
let combinedContext = autoResetContext + topicContextHeader
if combinedContext.utf8.count > 50_000 {
    // Cap at 50KB total — trim topic context first, keep auto-reset (conversation history)
    let remaining = 50_000 - autoResetContext.utf8.count
    if remaining > 0 {
        topicContextHeader = String(topicContextHeader.utf8.prefix(remaining)) + "\n... [context truncated]"
    } else {
        topicContextHeader = ""  // Auto-reset alone exceeds budget; skip topic context
    }
}
```

#### 3.4 Cross-platform safety (Kieran Warning-1: Injectable protocol; Mel Critical-1: iOS data path; Mel Warning-5: Structured result)

**Mel Critical-1:** The iOS data path must be explicit. `StubProjectFileProvider` returns a placeholder, not real project context. Unless there is a Mac-side gateway injection path, iOS sends from project-bound topics will reach the agent without actual file content.

**iOS data path (Phase 1):**
- macOS: `LocalProjectFileProvider` reads files and injects content via `chat.send` text — **works fully**.
- iOS: `StubProjectFileProvider` returns a structured result indicating degraded context. The agent receives the project name and path but not file content.
- UI must reflect this difference (see Section 3.5 UI additions).

**Mel Warning-5:** The provider protocol returns structured metadata, not just a raw string, so the UI and tests can distinguish capability states.

```swift
/// Result of a project context read operation (Mel Warning-5)
public struct ProjectContextReadResult {
    public var text: String
    public var files: [ProjectContextFileStatus]
    public var totalBytes: Int
    public var truncated: Bool
    public var unavailableReason: String?

    public struct ProjectContextFileStatus: Codable {
        public var filename: String
        public var status: FileStatus // found, missing, truncated
        public var bytes: Int

        public enum FileStatus: String, Codable { case found, missing, truncated }
    }
}

/// Protocol for platform-specific project file access (Kieran Warning-1, Mel Critical-1)
public protocol ProjectFileProvider {
    func readContextFiles(projectPath: String) -> ProjectContextReadResult
}

/// macOS: reads files directly from the filesystem
public struct LocalProjectFileProvider: ProjectFileProvider {
    public func readContextFiles(projectPath: String) -> ProjectContextReadResult {
        let text = ProjectContextReader.read(projectPath: projectPath)
        return ProjectContextReadResult(
            text: text,
            files: ProjectContextReader.getFileStatuses(projectPath: projectPath),
            totalBytes: text.utf8.count,
            truncated: text.contains("[truncated]"),
            unavailableReason: nil
        )
    }
}

/// Utility: get per-file status for UI display (Mel Warning-4, Q impl note)
extension ProjectContextReader {
    public static func getFileStatuses(projectPath: String) -> [ProjectContextReadResult.ProjectContextFileStatus] {
        guard validatePath(projectPath) else { return [] }
        return contextFiles.map { (filename, _, maxBytes) in
            let filePath = (projectPath as NSString).appendingPathComponent(filename)
            guard let data = FileManager.default.contents(atPath: filePath) else {
                return ProjectContextReadResult.ProjectContextFileStatus(
                    filename: filename, status: .missing, bytes: 0)
            }
            let bytes = data.count
            let status: ProjectContextReadResult.ProjectContextFileStatus.FileStatus =
                bytes > maxBytes ? .truncated : .found
            return ProjectContextReadResult.ProjectContextFileStatus(
                filename: filename, status: status, bytes: bytes)
        }
    }
}

/// iOS: project files live on the Mac; return degraded result (Mel Critical-1)
public struct StubProjectFileProvider: ProjectFileProvider {
    public func readContextFiles(projectPath: String) -> ProjectContextReadResult {
        let name = URL(fileURLWithPath: projectPath).lastPathComponent
        return ProjectContextReadResult(
            text: "[Project: \(name) — project files accessible on Mac only; context unavailable on this device.]",
            files: [],
            totalBytes: 0,
            truncated: false,
            unavailableReason: "iOS device — project files accessible on Mac only"
        )
    }
}
```

Inject the provider at `SyncBridge` construction:

```swift
// macOS app
let bridge = SyncBridge(fileProvider: LocalProjectFileProvider())

// iOS app (or test)
let bridge = SyncBridge(fileProvider: StubProjectFileProvider())
```

This makes both code paths testable on any platform and avoids `#if` compilation walls.

#### 3.5 Files to modify

| File | Change |
|---|---|
| `Sources/App/UI/ViewModels/TopicViewModel.swift` | Add `projectPath` field + explicit identity-only `Hashable` |
| `Sources/App/UI/ViewModels/MessageViewModel.swift` | Pass `projectPath`/`metadataJSON` through Topic reconstruction |
| `Sources/BeeChatSyncBridge/SyncBridge.swift` | Replace `buildContextHeader` with file-reading version; adopt `ProjectFileProvider`; add default `fileProvider: ProjectFileProvider? = nil` parameter to init |
| `Sources/BeeChatSyncBridge/Utilities/ProjectContextReader.swift` | **NEW** — file reading utility with path validation + byte-count truncation |
| `Sources/BeeChatSyncBridge/Utilities/ProjectFileProvider.swift` | **NEW** — protocol + macOS/iOS implementations + `ProjectContextReadResult` + `getFileStatuses()` extension |
| `Sources/App/UI/Components/SessionRow.swift` | Add small project-context indicator (Mel Warning-3) |
| `Sources/App/UI/Components/EditTopicSheet.swift` | Add context files status section (Mel Warning-4) |

**Call-site updates (Mel + Q impl notes):**
- **macOS:** `AppRootView.swift` — existing `SyncBridge()` construction gains `fileProvider: LocalProjectFileProvider()`. If `SyncBridge.init` has a default parameter, no change needed.
- **iOS (BeeChat-Mobile):** `BeeChatMobileViewModel.connect()` — existing `SyncBridge(config: bridgeConfig)` gains `fileProvider: StubProjectFileProvider()`. If default parameter is nil and iOS `projectPath` is always nil, this is a no-op until future sync sends `metadataJSON`.
- **Tests:** Any `SyncBridge` instantiation in test targets gains explicit `fileProvider`.

**Non-negotiable implementation constraint (Mel Critical-2):**
Project file reads must **never** run on the main actor or inside SwiftUI observation/refresh paths. Specifically:
- `ProjectContextReader.read()` is only called inside `SyncBridge.buildContextHeader()` during `sendMessage()`.
- Never call file reads inside `TopicViewModel` init, `SessionRow.body`, `EditTopicSheet.body`, or topic observation callbacks.
- If a future preview feature is added, it must be async/cached/cancellable.

### 3.6 Phase 1 UI additions (Mel Warning-3, Warning-4 + final gate fixes)

**SessionRow project indicator:**
- Add a small folder glyph/icon to `SessionRow` for project-bound topics.
- Tooltip/`.help`: "Project context linked: [project name]".
- `.accessibilityLabel`: "Project bound to [project name]".
- On macOS: show green indicator when context successfully injected.
- On iOS: show amber indicator with `.accessibilityHint`: "Project context unavailable on this device — files are read by the Mac" (Mel Critical-1).
- If context injection fails or files are missing, show a subtle warning icon with `.accessibilityLabel`: "Project context unavailable — [reason]".
- This provides a low-cost visual check that metadata survived the `Topic → TopicViewModel` hop.

**Send-time transient status:**
- During first send after binding/requeue, show compact status near existing reset indicator.
- States: "Adding project context..." → "Project context added" or "Project context unavailable".
- Non-blocking, disappears after 2 seconds.
- `.accessibilityLabel` and `.accessibilityValue` for each state so VoiceOver announces the transition.

**EditTopicSheet context files section:**
- After project selection, show a compact "Context files" section.
- List `STATUS.md`, `README.md`, `decisions.md`, `corrections.md` with found/missing/truncated status and approximate size.
- Include a collapsed "Preview" disclosure (`.accessibilityLabel`: "Preview project context files") for a short capped preview (not always-visible full text).
- If required `STATUS.md` is missing, surface a visible warning before Save.
- Each file status row has `.accessibilityLabel` (e.g., "STATUS.md, found, 3.2KB") and `.accessibilityValue` for truncation state.

**Guardrail (Mel Warning-2):** Local user-message insertion in `MessageViewModel.sendMessage()` must remain **before** the bridge call with file reads. A slow project read must not make the composer appear to eat input before the message appears.

**Kieran Warning-2:** The existing `formatSessionSummary` in `SyncBridge.swift` produces low-quality heuristic summaries (e.g., "We were discussing Add validation and Fix the bug"). Writing these to project files would actively degrade their quality.

### Phase 2: Auto Write-Back to Project Files (DEFERRED — Kieran Warning-2, Mel consensus)

**Kieran Warning-2:** The existing `formatSessionSummary` in `SyncBridge.swift` produces low-quality heuristic summaries. Writing these to project files would actively degrade their quality.

**Mel consensus:** Phase 1 UI surface (indicator + status) is sufficient for now. No write-back until summarisation quality is validated.

**Phase 2 requirements before starting:**
- Must use LLM-generated summaries (not heuristic first-line extraction)
- Needs validation against real conversation data before shipping
- Needs deduplication (avoid repeated entries for same work)
- Needs concurrency guard (two sessions on same project must not interleave writes)
- Needs error recovery (failed writes must not silently lose data)

**Deferred indefinitely.**

### Phase 3: UI Context Panel (Polish)

- Show STATUS.md content in a collapsible panel in the topic view
- Optional: live refresh on file change via `ValueObservation` on the file

---

## 4. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Project files too large → blow context budget | Medium | High | `maxTotalBytes` cap at 16KB; truncate per-file |
| Files don't exist or are unreadable | Low | Medium | Graceful fallback: show "not found" notice, don't fail the send |
| iOS crash on filesystem read | Medium | High | `#if os(iOS)` guard — skip read, show project name only |
| Stale content between sends | Low | Medium | Files are re-read on every send after reset; between sends, conversation carries the context forward |
| Metadata passthrough regression | Low | High | Unit test: Topic → TopicViewModel → Topic round-trip preserves projectPath |
| SyncBridge actor reentrancy (file I/O inside actor) | Medium | Medium | `ProjectContextReader.read()` is synchronous, non-throwing, pure function — safe inside actor |
| Permission denied on project path | Low | Low | Path validation already exists in `setProjectPath()`; files are within `/Users/openclaw/Projects/` |
| Path traversal via malformed metadataJSON | Low (now mitigated) | High | `ProjectContextReader.validatePath()` rejects paths outside `/Users/openclaw/Projects/` (Kieran Critical-1) |
| Byte budget exceeded due to character-count truncation | Medium (now mitigated) | High | UTF-8 byte-counting used for all truncation (Kieran Critical-2) |
| TopicViewModel Hashable breaks Set/Dict usage | Medium (now mitigated) | High | Explicit `Hashable` conformance — identity-only (Kieran Critical-3) |
| Context budget collision (auto-reset + topic) | Low (now mitigated) | Medium | Combined 50KB cap with topic-context-first trimming (Kieran Warning-3) |
| Synchronous file I/O blocks actor executor | Low | Medium | 4 small files in local Projects dir — acceptable. Monitor if projects move to slow filesystems (Kieran Observation-1) |

---

## 5. Verification Checklist

### Unit Tests
- [ ] **TopicViewModel passthrough** — Create a Topic with `projectPath`, convert to `TopicViewModel`, verify `projectPath` survives and `Hashable` is identity-only.
- [ ] **TopicViewModel Hashable** — Two `TopicViewModel` instances with same `id` but different `projectPath` must compare equal (Mel Warning-1).
- [ ] **ProjectContextReader** — Given a temp directory with STATUS.md and README.md, verify formatted output contains both file contents.
- [ ] **ProjectContextReader truncation** — Given a STATUS.md > 8KB, verify output is truncated to UTF-8 byte limit, not character count (Kieran Critical-2).
- [ ] **ProjectContextReader path traversal** — Given a path outside `/Users/openclaw/Projects/`, verify `read()` returns empty string (Kieran Critical-1).
- [ ] **ProjectContextReader symlink escape** — Given a symlink inside Projects/ pointing outside, verify rejection (Kieran Critical-1).
- [ ] **ProjectContextReader missing files** — Given a project directory with no STATUS.md, verify header still builds gracefully.
- [ ] **ProjectFileProvider structured result** — Verify `ProjectContextReadResult` contains correct `files`, `totalBytes`, `truncated` status (Mel Warning-5).
- [ ] **buildContextHeader with project** — Given a Topic with `projectPath`, verify header includes actual file content.
- [ ] **buildContextHeader without project** — Given a Topic with no `projectPath`, verify header contains only topic name.
- [ ] **buildContextHeader timestamp** — Verify header uses file modification date, not `Date.now` (Kieran Warning-5).

### Integration Tests
- [ ] **sendMessage flow** — Send a message from a project-bound topic; verify the injected text contains `[PROJECT-CONTEXT]` with file content.
- [ ] **TopicViewModel → Topic round-trip** — Verify the Topic passed to `sendMessage()` has the correct `projectPath` from the UI.
- [ ] **Local message insertion order** — Verify user message is inserted locally BEFORE bridge send with file reads (Mel Warning-2).
- [ ] **No main-actor file reads** — Verify `ProjectContextReader.read()` is never called during `TopicViewModel` init, `SessionRow.body`, or topic observation (Mel Critical-2).

### Manual Tests
- [ ] **macOS end-to-end** — Bind a topic to a project with a STATUS.md, send a message, verify agent responds with project-aware behavior.
- [ ] **iOS degraded context** — Same project-bound topic viewed on iOS; verify no crash, UI shows "Linked on Mac" indicator, agent receives project name but not file content (Mel Critical-1).
- [ ] **Project binding change** — Change a topic's project binding, send a message; verify new project's files are injected (use `requeueContextInjection`).
- [ ] **No project bound** — Topic with no project binding; verify `[PROJECT-CONTEXT]` section is absent from header.
- [ ] **SessionRow indicator** — Verify project-bound topics show folder glyph in sidebar; tooltip shows project name.
- [ ] **EditTopicSheet file status** — Verify the new "Context files" section shows found/missing/truncated status for each file (Mel Warning-4).
- [ ] **Send-time transient status** — Verify "Adding project context..." → "Project context added" appears on first send after binding.
- [ ] **Scroll bounce regression** — Verify message list scroll behavior is unchanged after implementation (Mel Observation-1).

---

## 6. Implementation Order

1. **TopicViewModel projectPath passthrough + explicit Hashable** — 1 file, ~15 lines. Unblocks everything else.
2. **ProjectFileProvider protocol + implementations** — 1 new file, protocol + macOS/iOS providers + `ProjectContextReadResult`.
3. **ProjectContextReader utility** — 1 new file, ~80 lines. Pure function with path validation + byte-count truncation.
4. **buildContextHeader upgrade** — Modify existing method in SyncBridge.swift. Uses ProjectFileProvider.
5. **MessageViewModel sendMessage fix** — Ensure Topic passed to bridge has projectPath.
6. **Context budget guard** — Add 50KB combined cap in `sendMessage()`.
7. **SessionRow project indicator** — Small folder glyph + tooltip (Mel Warning-3).
8. **EditTopicSheet context files section** — File status display + preview disclosure (Mel Warning-4).
9. **Send-time transient status** — Compact status near reset indicator.
10. **Tests** — Unit + integration + manual tests per verification checklist.

**Estimated effort:** 4-5 hours for Phase 1 (includes writing tests, UI additions, and auditing for Hashable-dependent code).

---

## 7. Why This Approach

The core problem is not architectural — it's a **data flow gap**. The project path exists in the database but gets dropped before reaching the agent. The agent is told to read project files but must do so at runtime, wasting tokens and requiring manual nudging.

Fixing this requires:
1. **Don't lose the data** — pass `projectPath` through the UI layer (TopicViewModel fix).
2. **Don't make the agent discover** — read the files in the app and inject content directly (ProjectContextReader + buildContextHeader).
3. **Don't break iOS** — conditional compilation for filesystem access.

All of this is app-level code. No gateway protocol changes. No OpenClaw prompt file modifications. The existing `chat.send` text channel carries the enriched context.
