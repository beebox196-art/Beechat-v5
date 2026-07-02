// Reference scaffold for BeeChat-v5 (macOS 14+) — add to Sources/App to use.
// Pairs with MessageTemplate.html (bundle resource "MessageTemplate").
#if os(macOS)

import SwiftUI
import WebKit

/// Renders one message's **pre-sanitized** HTML at intrinsic height inside a bubble:
///
///     MessageWebView(html: message.sanitizedHTML,
///                    themeTokens: themeManager.cssTokens,
///                    fontScale: themeManager.fontScale,
///                    height: $height)
///         .frame(height: height)
///
/// Height flows: ResizeObserver (JS) → bcHeight message → async binding write → .frame.
/// Theming: ThemeManager's palette is pushed as CSS custom properties (eight custom
/// themes — prefers-color-scheme can't represent them), fontScale likewise.
struct MessageWebView: NSViewRepresentable {
    /// Sanitized upstream with a tag/attribute allowlist — never raw network input.
    let html: String
    /// Flat CSS token map from the active theme, e.g. ["--bc-text": "#E0E0E0", ...].
    let themeTokens: [String: String]
    /// ThemeManager.fontScale — the template has no Dynamic Type to fall back on.
    let fontScale: CGFloat
    @Binding var height: CGFloat
    /// Receives web links AND the app's file-path links — route through the same
    /// open logic FileLinkText uses; never NSWorkspace.open raw message content.
    var onLink: (URL) -> Void

    // Note: WKProcessPool is a deprecated no-op since macOS 12 — WebKit decides
    // WebContent process allocation itself; the app cannot cap process count.

    // Template loaded via MessageTemplate.html constant — never crashes on missing file.
    // See MessageTemplate.swift for the resolution chain (resource bundle → flat bundle → embedded).
    private static let template: String = MessageTemplate.html

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> BubbleWebView {
        let controller = WKUserContentController()
        // Weak proxy: the controller retains handlers strongly; adding the coordinator
        // directly leaks a coordinator + web view per message — fatal combined with
        // LazyVStack's already-unbounded retention.
        let proxy = WeakScriptMessageHandler(context.coordinator)
        ["bcHeight", "bcLink", "bcImage", "bcReady"].forEach { controller.add(proxy, name: $0) }

        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let webView = BubbleWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparency: no isOpaque/backgroundColor on macOS. drawsBackground via KVC is
        // the long-tolerated route; underPageBackgroundColor covers overscroll/pre-paint.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.loadHTMLString(Self.template, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: BubbleWebView, context: Context) {
        context.coordinator.parent = self

        // Match native controls (code-block scrollbars, selection) to the theme's
        // brightness — the system appearance is irrelevant under custom themes.
        let isDarkTheme = themeTokens["--bc-appearance"] == "dark"
        webView.appearance = NSAppearance(named: isDarkTheme ? .darkAqua : .aqua)

        context.coordinator.apply(html: html, tokens: themeTokens, fontScale: fontScale, to: webView)
    }

    static func dismantleNSView(_ webView: BubbleWebView, coordinator: Coordinator) {
        let controller = webView.configuration.userContentController
        ["bcHeight", "bcLink", "bcImage", "bcReady"].forEach {
            controller.removeScriptMessageHandler(forName: $0)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: MessageWebView
        private var templateReady = false
        private var appliedHTML: String?
        private var appliedTokens: [String: String]?
        private var appliedScale: CGFloat?

        init(_ parent: MessageWebView) { self.parent = parent }

        func apply(html: String, tokens: [String: String], fontScale: CGFloat,
                   to webView: WKWebView) {
            guard templateReady else { return } // bcReady will re-invoke

            // Theme/scale before content so a fresh document never paints unthemed.
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
                // Async hop: a synchronous binding write here can land inside a SwiftUI
                // update pass ("Modifying state during view update" / AttributeGraph cycle).
                Task { @MainActor [parent] in parent.height = CGFloat(h) }
            case "bcLink":
                guard let raw = message.body as? String, let url = URL(string: raw),
                      ["http", "https", "mailto", "tel", "file"].contains(url.scheme?.lowercased() ?? "")
                else { return }
                // file: URLs must go through the app's file-open policy, not straight
                // to NSWorkspace — onLink is expected to enforce that.
                Task { @MainActor [parent] in parent.onLink(url) }
            case "bcImage":
                break // hook up native image viewer / QuickLook
            default:
                break
            }
        }

        // Deny everything except the initial template load; links arrive via bcLink.
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }

        // WebContent process died (crash/memory pressure): the bubble is blank.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            templateReady = false
            appliedHTML = nil; appliedTokens = nil; appliedScale = nil
            webView.loadHTMLString(MessageWebView.template, baseURL: nil)
        }
    }
}

/// macOS WKWebView has no `scrollView` to disable, so it swallows wheel events and
/// stalls the transcript. Forward *vertical* scrolling to the enclosing ScrollView;
/// keep *horizontal* in-document so wide code blocks and tables still pan.
/// Also strips WebKit's own context menu (Reload/Inspect Element).
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
