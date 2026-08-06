import SwiftUI
import WebKit
import BeeChatPersistence
import os

/// One `WKWebView`, app-lifetime, drives the Fable-approved
/// `TranscriptTemplate.html` (route plan `single-webview-transcript-plan.md` §5).
///
/// This is the **WP-2I minimal slice** — enough to render a real topic
/// end-to-end with streaming so Adam can smoke-test the WP-2 document.
/// Full hardening (context-menu filtering, bundle-id fix, NSCache memoization,
/// parity matrix P1–P16) remains WP-3.
///
/// ## What it does
///
/// - Loads `TranscriptTemplate.html` via `loadHTMLString(_, baseURL: nil)`.
/// - Pushes `TranscriptState` deltas to the document as JS calls
///   (`setTopic`, `upsertMessages`, `setStreaming`, `setThinking`, `setTheme`, `setFontScale`)
///   against the §4.3 contract.
/// - Handles `bcReady, bcLink, bcImage, bcLoadEarlier, bcCopyMessage` per §4.5.
/// - Self-heals `webViewWebContentProcessDidTerminate` by reloading and letting
///   `bcReady` replay state from `pendingState`.
///
/// ## Reuse
///
/// - `WeakScriptMessageHandler` — copy of the pattern from `MessageWebView.swift`,
///   needed here too because `WKUserContentController` retains its handler proxy.
/// - `WebViewCensus` — same mount/teardown hooks.
/// - `LinkPolicy.isAllowed/open` — same choke point as the legacy path.
///
/// ## State model
///
/// - `appliedState`: last state pushed to the document. Used for diffing in `updateNSView`.
/// - `pendingState`: the most recent state from `updateNSView` that arrived BEFORE `bcReady`.
///   Held and replayed once the template is ready.
struct WebTranscriptView: View {
    let state: TranscriptState
    let callbacks: TranscriptCallbacks

    @Environment(ThemeManager.self) private var themeManager

    var body: some View {
        TranscriptHost(
            state: state,
            callbacks: callbacks,
            themeTokens: themeManager.cssTokens,
            fontScale: themeManager.fontScale
        )
    }
}

// MARK: - NSViewRepresentable host

private struct TranscriptHost: NSViewRepresentable {
    let state: TranscriptState
    let callbacks: TranscriptCallbacks
    let themeTokens: [String: String]
    let fontScale: CGFloat

    private static let logger = Logger(subsystem: "com.beebox.beechat", category: "WebTranscriptView")

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        // Weak proxy breaks the WKUserContentController → handler retain cycle.
        let proxy = WeakScriptMessageHandler(context.coordinator)
        for name in ["bcReady", "bcLink", "bcImage", "bcLoadEarlier", "bcCopyMessage"] {
            controller.add(proxy, name: name)
        }

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Web Inspector on the live transcript (Safari ▸ Develop ▸ <Mac> ▸ BeeChatApp).
        // Deliberately unconditional: BeeChat is a local single-user app, builds
        // installed via scripts/build-and-install.sh are debug, and the absence of
        // this line is why the WP-2I upsertMessages defect was chased with `otool`
        // binary forensics instead of a console. Gate behind #if DEBUG only if the
        // project ever ships release builds.
        webView.isInspectable = true
        // Transparency: same posture as MessageWebView — underPageBackgroundColor
        // covers the overscroll/paint flash, drawsBackground via KVO kills the
        // initial white flash.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        // Match native controls to theme brightness (verbatim from MessageWebView).
        let isDarkTheme = themeTokens["--bc-appearance"] == "dark"
        webView.appearance = NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)
        webView.loadHTMLString(TranscriptTemplate.html, baseURL: nil)
        WebViewCensus.recordMount()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // Push state to coordinator. If template is ready, apply immediately;
        // otherwise it'll be replayed when bcReady arrives.
        context.coordinator.pendingState = state
        context.coordinator.pendingTokens = themeTokens
        context.coordinator.pendingScale = fontScale
        context.coordinator.applyStateIfReady(to: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        WebViewCensus.recordTeardown()
        let controller = webView.configuration.userContentController
        for name in ["bcReady", "bcLink", "bcImage", "bcLoadEarlier", "bcCopyMessage"] {
            controller.removeScriptMessageHandler(forName: name)
        }
        coordinator.templateReady = false
        coordinator.appliedState = nil
        coordinator.appliedTokens = nil
        coordinator.appliedScale = nil
        coordinator.pendingState = nil
        coordinator.pendingTokens = nil
        coordinator.pendingScale = nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: TranscriptHost

        // What the document currently has applied. Nil until bcReady fires.
        var appliedState: TranscriptState?
        var appliedTokens: [String: String]?
        var appliedScale: CGFloat?

        // What the Swift side most recently sent. Held before bcReady so we can replay.
        var pendingState: TranscriptState?
        var pendingTokens: [String: String]?
        var pendingScale: CGFloat?

        var templateReady = false

        // WP-2I Fix 1a (defer setTopic): when a topic switch arrives but the new
        // topic's messages are still empty (MessageListObserver.startObserving
        // sets messages = [] at line 23 of Sources/App/UI/Observers/MessageListObserver.swift),
        // we must NOT call setTopic({messages: []}) — that would blank the screen.
        // Hold the topic transition pending until messages arrive; on the next
        // non-empty state, do the atomic setTopic swap.
        var pendingTopicSwitch: Bool = false

        init(_ parent: TranscriptHost) { self.parent = parent }

        /// Push the diff between `pendingState` and `appliedState` to the document.
        ///
        /// Called from `updateNSView` (when state changes) AND from `bcReady` (template
        /// just loaded or recovered). First-load and recovery share this code path —
        /// `appliedState == nil` is treated as "nothing applied yet", NOT as an error
        /// (per Kieran must-fix #1 / §3.1 `bcReady` inverse invariant).
        func applyStateIfReady(to webView: WKWebView) {
            guard templateReady,
                  let state = pendingState else { return }

            // Build the JS calls via the pure TranscriptJSBuilder. The builder
            // returns a list of statements (each `window.bc.<fn>(...)`); we
            // concatenate with `;` so multi-call atomic transitions (Fix 1b:
            // streaming-end + message-arrival) execute in one JS task with no
            // intermediate frame. See TranscriptJSBuilder for the strategy.
            let plan = TranscriptJSBuilder.build(
                applied: appliedState,
                next: state,
                messagesPayload: messagesToPayload(state.messages)
            )

            // FIX 1a — topic switch with empty messages: hold pending.
            // If the topic changed and the new messages are empty (transient
            // state after MessageListObserver.startObserving), DO NOT call
            // setTopic — the template's setTopic clears the DOM. Hold the
            // previous transcript on screen; on the next non-empty state,
            // appliedState is reset to nil so we fall through to setTopic.
            if plan.holdsTopicTransition {
                pendingTopicSwitch = true
                appliedState = nil  // force setTopic on next non-empty state
                return
            }
            // If we held before and now have messages, the plan emits setTopic.
            // Clear the hold flag.
            if pendingTopicSwitch {
                pendingTopicSwitch = false
            }

            // Execute the JS plan as one concatenated script.
            if !plan.statements.isEmpty {
                evaluate(webView, plan.statements.joined(separator: ";"))
            }

            applyThemeAndScale(state: state, to: webView)
            appliedState = state
        }

        private func applyThemeAndScale(state: TranscriptState, to webView: WKWebView) {
            if let tokens = pendingTokens, tokens != appliedTokens {
                evaluate(webView, "window.bc.setTheme(\(Self.jsonString(tokens)))")
                appliedTokens = tokens
            }
            if let scale = pendingScale, scale != appliedScale {
                evaluate(webView, "window.bc.setFontScale(\(Double(scale)))")
                appliedScale = scale
            }
        }

        // MARK: - Diffing helpers

        /// Convert a `[Message]` into the payload the template's `setTopic` /
        /// `upsertMessages` consumes: `{id, role, senderName?, badge?, timeLabel, html}`.
        /// `html` is pre-rendered (caller responsibility upstream of the host).
        /// `timeLabel` already locale-formatted. For the WP-2I minimal slice we
        /// pass through the Message fields the template needs and let the template
        /// handle rendering — pre-sanitization is the caller's contract.
        // Payload building is delegated to the internal `TranscriptPayloadBuilder`
        // so the WP-2I contract is unit-testable (regression guard: payload `html`
        // must be markdown→sanitized, never raw).
        func messagesToPayload(_ messages: [Message]) -> [[String: Any]] {
            messages.map { TranscriptPayloadBuilder.messagePayload($0) }
        }

        private static func jsonString(_ value: Any) -> String {
            // Best-effort JSON encoding for JS evaluation. We avoid the Swift
            // JSONEncoder for nested [String: Any] because it doesn't preserve
            // nil-as-omitted (which the template expects); instead we hand-roll
            // a small encoder that handles the shapes we use (String, Int, Double,
            // Bool, [String: Any], [[String: Any]], nil → omit).
            return JSONStringEncoder.encode(value)
        }

        private func evaluate(_ webView: WKWebView, _ js: String) {
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    TranscriptHost.logger.error("JS eval error: \(error.localizedDescription, privacy: .public) for: \(js.prefix(120), privacy: .public)")
                }
            }
        }

        // MARK: - WKScriptMessageHandler

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "bcReady":
                // Per Kieran must-fix #1 / §3.1 `bcReady` inverse invariant:
                // ALWAYS replay pendingState, regardless of appliedState value.
                // appliedState == nil is the normal first-load — NOT an anomaly.
                // (Do NOT replicate the .fault tripwire at MessageWebView.swift:157
                //  here — it was correct for the per-message model but masks the
                //  single-WebView transcript's first-load as an error.)
                templateReady = true
                if let webView = message.webView {
                    applyStateIfReady(to: webView)
                }

            case "bcLink":
                guard let raw = message.body as? String,
                      let url = URL(string: raw),
                      LinkPolicy.isAllowed(url) else { return }
                Task { @MainActor [callbacks = parent.callbacks] in
                    callbacks.onOpenLink(url)
                }

            case "bcImage":
                // Native full-screen image viewer remains a TODO (parity with the
                // per-message model). The bridge handler must exist so the template's
                // bcImage posts don't error, but no native action yet.
                Task { @MainActor [callbacks = parent.callbacks] in
                    callbacks.onTapImage()
                }

            case "bcLoadEarlier":
                Task { @MainActor [callbacks = parent.callbacks] in
                    callbacks.onLoadEarlier()
                }

            case "bcCopyMessage":
                // Per §3.1: the template's helper does the pasteboard write in-DOM
                // (navigator.clipboard.writeText inside a user-click handler).
                // Swift receives `{id, ok}` — `ok` is informational (template already
                // wrote). We do NOT write to pasteboard in Swift (redundant + blocks
                // if the DOM write is gated on a user gesture we don't see).
                // Capture `ok` for telemetry once that lands in WP-3.
                if let body = message.body as? [String: Any],
                   let ok = body["ok"] as? Bool, !ok {
                    let messageId = (body["id"] as? String) ?? "?"
                    TranscriptHost.logger.error("bcCopyMessage: template-side pasteboard write failed for id=\(messageId, privacy: .public)")
                }

            default:
                break
            }
        }

        // MARK: - WKNavigationDelegate

        /// Deny all navigation except the initial template load.
        /// Links arrive via `bcLink`, never through WebKit navigation.
        /// Identical to MessageWebView's posture.
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }

        /// WebContent process died (crash / memory pressure). Per §3.1 — the WP-2I
        /// minimal slice includes the basic reload handler (~3 lines). The kill-9
        /// self-test, logging polish, and telemetry land in WP-3.
        /// After reload, `bcReady` fires → coordinator replays pendingState →
        /// transcript self-restores at the bottom (within ~1s).
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            TranscriptHost.logger.error("WebContent process terminated — reloading transcript template")
            templateReady = false
            appliedState = nil
            appliedTokens = nil
            appliedScale = nil
            webView.loadHTMLString(TranscriptTemplate.html, baseURL: nil)
        }
    }
}

// MARK: - WeakScriptMessageHandler (copy of MessageWebView.swift pattern)
//
// Breaks the WKUserContentController → handler strong retain cycle. Without
// this, every WebView retains its coordinator + view hierarchy permanently.
// The handler here is file-internal because TranscriptHost is the only consumer.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// MARK: - JSONStringEncoder (small JSON encoder for [String: Any] payloads)
//
// Swift's `JSONSerialization` is not great at producing JS-friendly JSON (nil
// values, optional handling), and `JSONEncoder` rejects `[String: Any]` because
// `Any` isn't `Encodable`. This mini-encoder handles the four payload shapes
// we emit: primitives, [String: Any] (object), [Any] (array), nil → omit.
//
// It's strictly internal: the only consumer is the JS bridge evaluation.
private enum JSONStringEncoder {
    static func encode(_ value: Any) -> String {
        var out = ""
        encodeValue(value, into: &out)
        return out
    }

    private static func encodeValue(_ value: Any, into out: inout String) {
        switch value {
        case let s as String:
            out += encodeString(s)
        case let b as Bool:
            out += b ? "true" : "false"
        case let i as Int:
            out += String(i)
        case let d as Double:
            // Avoid scientific notation / NaN issues that break JS.
            if d.isFinite {
                out += String(d)
            } else {
                out += "null"
            }
        case let n as NSNumber:
            // Bool arrives as NSNumber too; check objCType.
            let t = String(cString: n.objCType)
            if t == "c" {
                out += n.boolValue ? "true" : "false"
            } else {
                out += n.stringValue
            }
        case let dict as [String: Any]:
            out += "{"
            var first = true
            for (k, v) in dict {
                if !first { out += "," }
                first = false
                out += encodeString(k) + ":"
                encodeValue(v, into: &out)
            }
            out += "}"
        case let arr as [Any]:
            out += "["
            for (idx, v) in arr.enumerated() {
                if idx > 0 { out += "," }
                encodeValue(v, into: &out)
            }
            out += "]"
        case is NSNull:
            out += "null"
        case Optional<Any>.none:
            out += "null"
        default:
            // Last-ditch: stringify. Should never hit in our call sites.
            out += encodeString(String(describing: value))
        }
    }

    private static func encodeString(_ s: String) -> String {
        // Minimal JSON string escaping for the values we emit. JS-side parsing is
        // permissive about non-control characters but strict about quotes/backslashes.
        var escaped = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            default:
                if ch.value < 0x20 {
                    escaped += String(format: "\\u%04x", ch.value)
                } else {
                    escaped += String(ch)
                }
            }
        }
        escaped += "\""
        return escaped
    }
}

// MARK: - Message helpers
//
// The host's payload contract for the template's `setTopic` / `upsertMessages`
// is `{id, role, html}` plus optional `{senderName, timeLabel, badge}`. The
// `Message` struct already has `senderName`; `timeLabel` and `badge` are
// derived (not stored on `Message`) so we synthesise them via extensions here.
// `html` is pre-rendered content — the host runs the markdown→HTML→sanitize
// pipeline itself (see `messagesToPayload`) because the template assigns
// `bubble.innerHTML = html` directly and MUST NOT receive raw/unsanitized input.
//
// These live here (rather than as extensions on Message in BeeChatPersistence)
// because the host's payload contract is host-specific — adding them to
// BeeChatPersistence would expand its public API surface for one consumer.
private extension Message {
    /// Locale-friendly time label derived from the message timestamp. Pass nil
    /// to let the template fall back to its JS-side Date formatting.
    var timeLabel: String? {
        // WP-2I minimal slice: format as HH:mm. Future: honour locale + 12/24h
        // preference via DateFormatter cached on the host.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: timestamp)
    }
    /// Optional per-message badge (e.g. "thinking"). Reserved for future use.
    var badge: String? {
        return nil
    }
}

// MARK: - TranscriptPayloadBuilder (internal, testable)
//
// Builds the message payload the template's `setTopic` / `upsertMessages`
// consume: `{id, role, senderName?, badge?, timeLabel, html}`.
//
// CRITICAL contract (route plan §4.3/§5): the template assigns
// `bubble.innerHTML = html` directly, so `html` MUST be pre-rendered AND
// sanitized — `HTMLSanitizer.sanitize(MarkdownToHTML.convert(content))`,
// exactly as the native path (MessageContent / StreamingBubble) does.
//
// Regression: Q's first WP-2I build passed raw `msg.content` (markdown) as
// `html`, which left the live transcript blank and skipped the sanitizer.
// Caught by Adam's smoke test 2026-08-06. Extracted as an internal type so
// `TranscriptHostPayloadTests` can guard the contract.

// MARK: - TranscriptJSBuilder (pure, testable) — WP-2I smoke-test fixes
//
// Pure function that takes (appliedState, nextState, messagesPayload) and
// produces the JS statements the Coordinator should execute in ONE call.
//
// Three responsibilities (each addresses a smoke-test bug):
//
// 1. **Fix 1a — defer setTopic on empty messages.** When the topic changes
//    AND `next.messages` is empty (MessageListObserver.startObserving just
//    cleared it), DO NOT emit setTopic. Return `holdsTopicTransition = true`
//    so the Coordinator can mark `appliedState = nil` and retry on the next
//    non-empty state. The previous transcript stays on screen; no flash.
//
// 2. **Fix 1b — atomic settle.** When we WERE showing a streaming node
//    (`appliedState.streamingHTML != nil`) AND the new state has a settled
//    assistant message in `messages`, emit
//        `setStreaming(null); upsertMessages([settled], false)`
//    in ONE concatenated statement. The route plan §4.3 R4 collapse — the
//    streaming node disappears and the settled .msg article appears in the
//    same JS task. No intermediate frame shows nothing.
//
// 3. **Fix 2a — template width.** Not a host responsibility; lives in the
//    HTML. See commit message.
//
// The builder is intentionally side-effect-free: it returns a `Plan` struct.
// Tests assert the JS strings, the holdsTopicTransition flag, and the
// statement ordering. The Coordinator only does I/O (evaluateJavaScript).
struct TranscriptJSBuilder {
    /// One unit of JS work. The Coordinator concatenates statements with `;`
    /// and executes them in one `evaluateJavaScript` call. Multi-statement
    /// plans run in the same JS task — atomic from the DOM's perspective.
    struct Plan: Equatable {
        /// Ordered JS statements, each a complete `window.bc.<fn>(...)` call.
        var statements: [String] = []
        /// True when the topic changed but messages are empty; Coordinator
        /// must mark appliedState = nil and retry on the next state.
        var holdsTopicTransition: Bool = false

        static let empty = Plan()
    }

    /// Build the JS plan for a state diff.
    ///
    /// - Parameters:
    ///   - applied: The last state we successfully pushed to the document.
    ///     Nil = nothing applied yet (first load / recovery).
    ///   - next: The new state from `updateNSView` / `pendingState`.
    ///   - messagesPayload: Pre-rendered `[Message]` payload array — already
    ///     markdown→sanitized (via `TranscriptPayloadBuilder.messagePayload`).
    static func build(
        applied: TranscriptState?,
        next: TranscriptState,
        messagesPayload: [[String: Any]]
    ) -> Plan {
        var plan = Plan()

        // ----- Fix 1a: defer setTopic on empty messages -------------------
        let topicChanged = applied?.topicId != next.topicId
        if topicChanged && next.messages.isEmpty {
            plan.holdsTopicTransition = true
            return plan
        }

        // ----- Topic switch (atomic swap) ----------------------------------
        if topicChanged {
            let payload: [String: Any] = [
                "topicId": next.topicId as Any,
                "messages": messagesPayload,
                "canLoadEarlier": next.canLoadEarlier,
            ]
            plan.statements.append("window.bc.setTopic(\(jsonString(payload)))")
            // After setTopic, also push streaming/thinking state for the new topic
            // (the old streaming bubble has been removed by setTopic's atomic swap).
            appendStreamingAndThinking(into: &plan, applied: applied, next: next)
            return plan
        }

        // ----- Fix 1b: atomic settle ---------------------------------------
        // If we were streaming (applied.streamingHTML != nil) AND the new state
        // has a new assistant message AND the new state's streamingHTML is nil,
        // the user just sent a message and it settled. Collapse the two JS calls
        // into one task to avoid the empty-frame gap.
        let wasStreaming = applied?.streamingHTML != nil
        let nowSettled = next.streamingHTML == nil
        let hasNewAssistant = hasNewAssistantMessage(
            applied: applied?.messages ?? [],
            next: next.messages
        )

        if wasStreaming && nowSettled && hasNewAssistant {
            // Atomic settle: hide the streaming node AND insert the settled
            // message in one JS task. The route plan §4.3 R4 collapse.
            let settledOnly = messagesPayload.filter { dict in
                if let role = dict["role"] as? String { return role == "assistant" }
                return false
            }
            // SEAM: upsertMessages is POSITIONAL — (messages, canLoadEarlier).
            // See TranscriptTemplate.html:743. Passing a single object makes the
            // template's `for...of` iterate a non-iterable and throw.
            plan.statements.append("window.bc.setStreaming(null)")
            plan.statements.append(
                "window.bc.upsertMessages(\(jsonString(settledOnly)),\(jsonString(next.canLoadEarlier)))"
            )
            // Don't emit setThinking — the streaming state ended, and setThinking
            // is unchanged from the previous apply.
            return plan
        }

        // ----- Normal same-topic path --------------------------------------
        // Diff messages by id/content. Any change → upsertMessages.
        if messagesChanged(applied: applied?.messages ?? [], next: next.messages) {
            // SEAM: positional signature — see the note at the atomic-settle site
            // above and TranscriptTemplate.html:743.
            plan.statements.append(
                "window.bc.upsertMessages(\(jsonString(messagesPayload)),\(jsonString(next.canLoadEarlier)))"
            )
        }

        appendStreamingAndThinking(into: &plan, applied: applied, next: next)
        return plan
    }

    // MARK: - Helpers

    private static func appendStreamingAndThinking(
        into plan: inout Plan,
        applied: TranscriptState?,
        next: TranscriptState
    ) {
        // setStreaming: only emit when streamingHTML changed. Same value →
        // no-op (the JS template is idempotent but skipping saves a round-trip).
        if applied?.streamingHTML != next.streamingHTML {
            let streamingJSON: String
            if let html = next.streamingHTML {
                streamingJSON = jsonString(["html": TranscriptPayloadBuilder.sanitizedStreamingHTML(html)])
            } else {
                streamingJSON = "null"
            }
            plan.statements.append("window.bc.setStreaming(\(streamingJSON))")
        }

        // setThinking: same — only emit on change.
        if applied?.thinkingState != next.thinkingState {
            let thinkingRaw: String
            switch next.thinkingState {
            case .idle: thinkingRaw = "idle"
            case .thinking: thinkingRaw = "thinking"
            case .streaming: thinkingRaw = "streaming"
            }
            plan.statements.append("window.bc.setThinking(\(jsonString(thinkingRaw)))")
        }
    }

    private static func messagesChanged(applied: [Message], next: [Message]) -> Bool {
        if applied.count != next.count { return true }
        for (a, b) in zip(applied, next) {
            if a.id != b.id { return true }
            if a.content != b.content { return true }
        }
        return false
    }

    private static func hasNewAssistantMessage(applied: [Message], next: [Message]) -> Bool {
        let appliedIds = Set(applied.map { $0.id })
        for msg in next where msg.role == "assistant" && !appliedIds.contains(msg.id) {
            return true
        }
        return false
    }

    /// JSON encoder for JS-bridge payloads. Same logic as before — hoisted
    /// here so the builder is self-contained and unit-testable.
    static func jsonString(_ value: Any) -> String {
        JSONStringEncoder.encode(value)
    }
}

// MARK: - TranscriptPayloadBuilder (kept below JSBuilder for legacy import)
// Kept for backwards compat with `TranscriptHostPayloadTests` which imports it
// directly. See above for the JS-side concerns.
internal enum TranscriptPayloadBuilder {
    static func messagePayload(_ msg: Message) -> [String: Any] {
        var dict: [String: Any] = [
            "id": msg.id,
            "role": msg.role,
            "html": HTMLSanitizer.sanitize(MarkdownToHTML.convert(msg.content ?? "")),
        ]
        if let senderName = msg.senderName {
            dict["senderName"] = senderName
        }
        if let timeLabel = msg.timeLabel {
            dict["timeLabel"] = timeLabel
        }
        if let badge = msg.badge {
            dict["badge"] = badge
        }
        return dict
    }

    /// Sanitize raw streaming content for the template's `setStreaming`.
    /// Same pipeline as `messagePayload` (streaming content is raw markdown).
    static func sanitizedStreamingHTML(_ raw: String) -> String {
        HTMLSanitizer.sanitize(MarkdownToHTML.convert(raw))
    }
}
