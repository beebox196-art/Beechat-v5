import SwiftUI
import BeeChatPersistence

// MARK: - Transcript Engine
//
// `TranscriptEngine` selects which transcript rendering strategy is active.
// `.native` is the current SwiftUI/MessageCanvas implementation.
// `.web` is a stub for now (EmptyView) — the web engine ships in WP-3.
//
// The enum is `String, CaseIterable` so it can be persisted in UserDefaults
// directly (matching the existing `FeatureFlags` pattern). Adding a new engine
// is a compile-time-forced case update here.

enum TranscriptEngine: String, CaseIterable, Sendable {
    case native
    case web
}

// MARK: - TranscriptState
//
// Single bag of value-typed state that drives the transcript view.
// All fields are value types, so `TranscriptState` can be `Equatable` and
// SwiftUI can cheaply diff state to skip unnecessary view rebuilds.
//
// Why this is Equatable but `TranscriptCallbacks` is not:
// SwiftUI re-evaluates `transcriptView(...)` when its inputs change. For
// `TranscriptState` (Equatable), SwiftUI can detect "no actual change" via
// structural equality and skip the body call — a free optimisation.
// For `TranscriptCallbacks` (non-Equatable), SwiftUI treats every render
// as a fresh input. Callbacks are *captured at build time* — they don't
// drive equality, they only drive behaviour. This separation is intentional:
// future engines must NOT try to make callbacks Equatable (it would force
// stable closure identity, which SwiftUI cannot guarantee for captured
// closures).

struct TranscriptState: Equatable {
    /// Persisted messages from GRDB. Drives the message list rendering.
    let messages: [Message]
    /// Whether SyncBridge is currently streaming for this topic.
    let isStreaming: Bool
    /// Live streaming content captured from SyncBridge deltas.
    let streamingContent: String
    /// Bridge content: final assistant content captured when streaming ends,
    /// before GRDB delivers the settled message.
    let completedContent: String
    /// Current thinking indicator state.
    let thinkingState: ThinkingState
    /// Whether the user can paginate back to load earlier messages.
    let canLoadEarlier: Bool
    /// Topic identifier used as the scroll-view identity (forces rebuild on
    /// topic switch — see MessageCanvas v5 scroll philosophy).
    let topicId: String?

    init(
        messages: [Message],
        isStreaming: Bool,
        streamingContent: String,
        completedContent: String,
        thinkingState: ThinkingState,
        canLoadEarlier: Bool,
        topicId: String?
    ) {
        self.messages = messages
        self.isStreaming = isStreaming
        self.streamingContent = streamingContent
        self.completedContent = completedContent
        self.thinkingState = thinkingState
        self.canLoadEarlier = canLoadEarlier
        self.topicId = topicId
    }
}

// MARK: - TranscriptCallbacks
//
// View inputs that are NOT part of state equality — callbacks drive behaviour,
// not rendering diffs. Captured at view build time.
//
// NOT Equatable on purpose: see `TranscriptState` doc-comment above.

struct TranscriptCallbacks {
    let onLoadEarlier: () -> Void
    let onOpenLink: (URL) -> Void
    let onTapImage: () -> Void

    init(
        onLoadEarlier: @escaping () -> Void = {},
        onOpenLink: @escaping (URL) -> Void = { _ in },
        onTapImage: @escaping () -> Void = {}
    ) {
        self.onLoadEarlier = onLoadEarlier
        self.onOpenLink = onOpenLink
        self.onTapImage = onTapImage
    }
}

// MARK: - TranscriptState policy extensions (WP-1 §4.5)
//
// These two methods capture the EXACT pre-refactor behaviour of
// `MessageCanvas.showStreamingBubble` and `MessageCanvas.showCompletedBridge`
// (MessageCanvas.swift lines 37–60, before WP-1). Truth-table tests in
// `Tests/BeeChatAppTests/TranscriptStatePolicyTests.swift` enumerate every
// meaningful combination of inputs and assert these derived values match the
// old inline computation byte-for-byte. After WP-1, MessageCanvas consumes
// these methods instead of computing inline — proving behavioural equivalence
// by test, not by inspection.

extension TranscriptState {

    /// Whether the streaming bubble should be visible.
    ///
    /// Pre-refactor logic (MessageCanvas.swift:37–44):
    ///   1. If `streamingContent.isEmpty` → false.
    ///   2. If the last assistant message exists, has non-empty content, AND
    ///      its content exactly matches `streamingContent` → false (already
    ///      settled — no streaming bubble needed).
    ///   3. Otherwise → true.
    var showStreamingBubble: Bool {
        guard !streamingContent.isEmpty else { return false }
        if let lastAssistant = messages.last(where: { $0.role == "assistant" }),
           let content = lastAssistant.content,
           !content.isEmpty,
           content == streamingContent {
            return false
        }
        return true
    }

    /// Whether the completed-content bridge bubble should be visible.
    ///
    /// Pre-refactor logic (MessageCanvas.swift:48–60):
    ///   1. If `isStreaming` is true OR `completedContent.isEmpty` → false.
    ///   2. If the last assistant message exists with non-empty content →
    ///      false (the settled message already delivered — bridge not needed).
    ///   3. Otherwise → true.
    var showCompletedBridge: Bool {
        guard !isStreaming, !completedContent.isEmpty else { return false }
        if let lastAssistant = messages.last(where: { $0.role == "assistant" }),
           let content = lastAssistant.content, !content.isEmpty {
            return false
        }
        return true
    }

    /// HTML to render in the streaming bubble position.
    /// Nil when the bubble should not be shown. Both engines (`.native`,
    /// future `.web`) consume this single derived value.
    var streamingHTML: String? {
        showStreamingBubble ? streamingContent : nil
    }

    /// HTML to render in the completed-content bridge position.
    /// Nil when the bridge should not be shown. Both engines consume this
    /// single derived value.
    var settledBridgeHTML: String? {
        showCompletedBridge ? completedContent : nil
    }
}

// MARK: - NativeTranscriptView
//
// Rename-and-wrap of `canvasWithMacOS15Chrome(...)` (MainWindow.swift:953).
// **Zero logic changes** in this WP — same `MessageCanvas` + same
// macOS 15+ scroll-position chrome wrapper. The wrap exists so that
// `transcriptView(...)` below can dispatch on `engine` without inlining the
// chrome-availability check at the call site.

struct NativeTranscriptView: View {
    let state: TranscriptState
    let callbacks: TranscriptCallbacks

    var body: some View {
        let canvas = MessageCanvas(
            messages: state.messages,
            isStreaming: state.isStreaming,
            streamingHTML: state.streamingHTML,
            settledBridgeHTML: state.settledBridgeHTML,
            // Raw content still passed through for the typing-indicator
            // transition guard (`isStreaming && streamingContent.isEmpty`),
            // which is NOT part of the §4.5 policy move — only the streaming
            // bubble and completed-bridge visibility decisions move.
            streamingContent: state.streamingContent,
            completedContent: state.completedContent,
            thinkingState: state.thinkingState,
            canLoadEarlier: state.canLoadEarlier,
            topicId: state.topicId,
            onLoadEarlier: callbacks.onLoadEarlier
        )
        if #available(macOS 15.0, *) {
            MacOS15ScrollPositionChrome(topicId: state.topicId) { canvas }
        } else {
            canvas
        }
    }
}

// MARK: - WebTranscriptView (stub — WP-3 ships the real implementation)
//
// The web engine is NOT built yet. WP-3 (Swift Host) replaces this stub
// with a WKWebView-backed renderer consuming the same `TranscriptState`
// + `TranscriptCallbacks`. Per the WP-1 spec, the stub renders `EmptyView`
// — flipping the flag to `.web` should produce a clean blank transcript
// area with no crash.

struct WebTranscriptView: View {
    let state: TranscriptState
    let callbacks: TranscriptCallbacks

    var body: some View {
        // Stub: render nothing. WP-3 will replace this with a WKWebView host
        // that consumes state.streamingHTML / state.settledBridgeHTML.
        EmptyView()
    }
}

// MARK: - transcriptView free @ViewBuilder function
//
// Free function (not a View extension, not a computed property) per spec §2.1.
// Dispatches on `engine` to the appropriate concrete renderer. Both renderers
// consume the same `TranscriptState` + `TranscriptCallbacks`, guaranteeing
// behavioural parity on shared inputs.

@ViewBuilder
func transcriptView(
    engine: TranscriptEngine,
    state: TranscriptState,
    callbacks: TranscriptCallbacks
) -> some View {
    switch engine {
    case .native:
        NativeTranscriptView(state: state, callbacks: callbacks)
    case .web:
        WebTranscriptView(state: state, callbacks: callbacks)
    }
}
