import Foundation
import AppKit

/// Unified link policy for all rendering paths in BeeChat.
///
/// Every link click — whether from a WebView (StreamingBubble, MessageWebView),
/// a native SwiftUI AttributedString (ConvertedMessageView), or FileLinkText —
/// goes through this single choke point. No caller should use `NSWorkspace.shared.open`
/// directly.
///
/// ## Policy rules
///
/// - **Allowed web schemes**: `HTMLSanitizer.allowedSchemes` (http, https, mailto).
/// - **File URLs**: Permitted only when the path resolves to a user home directory
///   under `/Users/`. This matches `FilePathParser`'s existing allowlist guard.
/// - **All other schemes**: Blocked (javascript:, data:, vbscript:, etc.).
///
/// ## Flag OFF path
///
/// When `htmlRenderingEnabled` is off, FileLinkText's `OpenURLAction` calls
/// `LinkPolicy.open(_:)` — the same function the WebView path uses. The plain-text
/// rendering path is otherwise unchanged.
enum LinkPolicy {

    #if DEBUG
    /// When true, `open(_:)` validates the URL but does NOT call
    /// `NSWorkspace.shared.open`. Set in unit-test setUp/tearDown to
    /// prevent tests from opening real browser tabs and email compose windows.
    /// Production builds strip this flag entirely (no runtime cost).
    static var suppressOpenInTests = false
    #endif

    /// Schemes allowed for web/mail links. Mirrors `HTMLSanitizer.allowedSchemes`.
    static let allowedWebSchemes: Set<String> = HTMLSanitizer.allowedSchemes

    /// The file scheme, separate because it has its own path validation.
    private static let fileScheme = "file"

    /// All schemes permitted by this policy (web + file).
    static let allAllowedSchemes: Set<String> = allowedWebSchemes.union([fileScheme])

    // MARK: - Open URL

    /// Whether `open(_:)` should actually call `NSWorkspace.shared.open`.
    /// In DEBUG builds, respects `suppressOpenInTests`. In RELEASE builds,
    /// always returns true (the flag doesn't exist).
    private static var shouldOpenForReal: Bool {
        #if DEBUG
        return !suppressOpenInTests
        #else
        return true
        #endif
    }

    /// Open a URL after validating it against the link policy.
    ///
    /// - Returns: `true` if the URL was opened (or would have been — in test mode,
    ///   validation passes but no browser/email window is actually opened).
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            // No scheme at all — could be a bare path. Don't open.
            return false
        }

        // Fast path: web/mail schemes (http, https, mailto)
        if allowedWebSchemes.contains(scheme) {
            #if os(macOS)
            if shouldOpenForReal {
                NSWorkspace.shared.open(url)
            }
            #endif
            return true
        }

        // File URLs: validate path is under /Users/ (FilePathParser's guard)
        if scheme == fileScheme {
            let path = url.path
            let standardised = (path as NSString).standardizingPath

            guard standardised.hasPrefix("/Users/") else {
                return false
            }

            #if os(macOS)
            if shouldOpenForReal {
                NSWorkspace.shared.open(url)
            }
            #endif
            return true
        }

        // Everything else is blocked
        return false
    }

    // MARK: - Validation-only

    /// Check whether a URL would be allowed by the policy, without opening it.
    ///
    /// Useful for WebView `bcLink` handlers that need to decide whether to
    /// forward a URL before calling `open`.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }

        if allowedWebSchemes.contains(scheme) { return true }

        if scheme == fileScheme {
            let path = url.path
            let standardised = (path as NSString).standardizingPath
            return standardised.hasPrefix("/Users/")
        }

        return false
    }
}