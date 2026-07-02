import SwiftUI
import WebKit

/// Renders one message's **pre-sanitized** HTML at intrinsic height inside a bubble.
///
/// Designed for the streaming bubble: one live WebView receives HTML via
/// `setContent()` at ~5fps. Not intended for the per-bubble-everywhere pattern
/// (that path uses the native converter for ~95% of messages).
///
/// Height flows: ResizeObserver (JS) → bcHeight message → async binding write → .frame.
/// Theming: ThemeManager's palette pushed as CSS custom properties, fontScale likewise.
///
/// ## Safety
///
/// - Input MUST be sanitized via `HTMLSanitizer.sanitize()` before passing to this view.
/// - Navigation is denied except the initial template load (WKNavigationDelegate).
/// - Context menus are suppressed (bubble menus stay native).
/// - Height binding writes hop to main async to avoid AttributeGraph cycles.
///
/// ## Memory
///
/// One live WebView per streaming message. LazyVStack's retention is bounded because
/// only 0–1 streaming bubbles exist at a time. Completed messages switch to the native
/// converter path, releasing their WebView.
#if os(macOS)
struct MessageWebView: NSViewRepresentable {
    /// Pre-sanitized HTML content (run through HTMLSanitizer before passing here).
    let html: String
    /// Flat CSS token map from the active theme, e.g. ["--bc-text": "#E0E0E0", ...].
    let themeTokens: [String: String]
    /// ThemeManager.fontScale — no Dynamic Type on macOS; comes from the app setting.
    let fontScale: CGFloat
    /// Height binding: ResizeObserver in JS reports content height, written async to main.
    @Binding var height: CGFloat
    /// Callback for link taps — routes through FileLinkText's open logic, never NSWorkspace raw.
    var onLink: (URL) -> Void = { _ in }

    // Static template loaded once from bundle. Fallback is a minimal valid HTML doc.
    private static let template: String = {
        guard let url = Bundle.main.url(forResource: "MessageTemplate", withExtension: "html"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("MessageTemplate.html missing from bundle — check Resources group")
            return "<html><body><div id=\"content\"></div></body></html>"
        }
        return s
    }()

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BubbleWebView {
        let controller = WKUserContentController()
        // Weak proxy breaks the WKUserContentController → handler retain cycle.
        // Without this, every WebView retains its coordinator + view hierarchy permanently.
        let proxy = WeakScriptMessageHandler(context.coordinator)
        for name in ["bcHeight", "bcLink", "bcImage", "bcReady"] {
            controller.add(proxy, name: name)
        }

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let webView = BubbleWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparency: macOS WKWebView uses drawsBackground via KVO (undocumented but
        // long-tolerated) + underPageBackgroundColor for the overscroll/paint flash.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.loadHTMLString(Self.template, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: BubbleWebView, context: Context) {
        context.coordinator.parent = self
        // Match native controls to theme brightness. The system appearance is
        // irrelevant when custom themes are active.
        let isDarkTheme = themeTokens["--bc-appearance"] == "dark"
        webView.appearance = NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)
        context.coordinator.apply(html: html, tokens: themeTokens, fontScale: fontScale, to: webView)
    }

    static func dismantleNSView(_ webView: BubbleWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        for name in ["bcHeight", "bcLink", "bcImage", "bcReady"] {
            controller.removeScriptMessageHandler(forName: name)
        }
        // Nil out coordinator state to close teardown race (Q recommendation from review).
        coordinator.appliedHTML = nil
        coordinator.appliedTokens = nil
        coordinator.appliedScale = nil
        coordinator.templateReady = false
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MessageWebView
        var templateReady = false
        var appliedHTML: String?
        var appliedTokens: [String: String]?
        var appliedScale: CGFloat?

        init(_ parent: MessageWebView) { self.parent = parent }

        func apply(html: String, tokens: [String: String], fontScale: CGFloat,
                   to webView: WKWebView) {
            guard templateReady else { return } // bcReady will re-invoke

            // Theme/scale before content — a fresh document should never paint unthemed.
            if tokens != appliedTokens, let json = Self.json(tokens) {
                appliedTokens = tokens
                webView.evaluateJavaScript("window.beechat.setTheme(\(json))")
            }
            if fontScale != appliedScale {
                appliedScale = fontScale
                webView.evaluateJavaScript("window.beechat.setFontScale(\(Double(fontScale)))")
            }
            if html != appliedHTML, let json = Self.json(html) {
                appliedHTML = html
                webView.evaluateJavaScript("window.beechat.setContent(\(json))")
            }
        }

        private static func json(_ value: some Encodable) -> String? {
            guard let data = try? JSONEncoder().encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            switch message.name {
            case "bcReady":
                templateReady = true
                if let webView = message.webView {
                    apply(html: parent.html, tokens: parent.themeTokens,
                          fontScale: parent.fontScale, to: webView)
                }
            case "bcHeight":
                guard let h = message.body as? Double else { return }
                // Async hop: synchronous binding write inside a WKScriptMessage callback
                // can land inside a SwiftUI update pass ("Modifying state during view update"
                // / AttributeGraph cycle).
                Task { @MainActor [parent] in parent.height = CGFloat(h) }
            case "bcLink":
                guard let raw = message.body as? String,
                      let url = URL(string: raw),
                      HTMLSanitizer.allowedSchemes.contains(url.scheme?.lowercased() ?? "")
                else { return }
                Task { @MainActor [parent] in parent.onLink(url) }
            case "bcImage":
                break // TODO: native full-screen image viewer
            default:
                break
            }
        }

        // Deny all navigation except the initial template load.
        // Links arrive via bcLink, never through WebKit navigation.
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }

        // WebContent process died (crash/memory pressure): bubble goes blank.
        // Reload template and re-inject content on next update cycle.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            templateReady = false
            appliedHTML = nil; appliedTokens = nil; appliedScale = nil
            webView.loadHTMLString(MessageWebView.template, baseURL: nil)
        }
    }
}

/// macOS WKWebView swallows vertical scroll wheel events, stalling the transcript.
/// Forward *vertical* scroll to the enclosing ScrollView; keep *horizontal*
/// in-document so wide code blocks and tables still pan.
/// Also strips WebKit's own context menu (Reload/Inspect Element) — bubble menus are native.
final class BubbleWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems() // bubble context menus are SwiftUI's job
    }
}

/// Breaks the WKUserContentController → handler strong retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
#endif