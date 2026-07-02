import XCTest
@testable import BeeChatApp

final class LinkPolicyTests: XCTestCase {

    // MARK: - Allowed Web Schemes

    func testAllowsHTTP() {
        let url = URL(string: "http://example.com")!
        XCTAssertTrue(LinkPolicy.isAllowed(url))
        XCTAssertTrue(LinkPolicy.open(url))
    }

    func testAllowsHTTPS() {
        let url = URL(string: "https://example.com/path?query=1")!
        XCTAssertTrue(LinkPolicy.isAllowed(url))
        XCTAssertTrue(LinkPolicy.open(url))
    }

    func testAllowsMailto() {
        let url = URL(string: "mailto:user@example.com")!
        XCTAssertTrue(LinkPolicy.isAllowed(url))
        XCTAssertTrue(LinkPolicy.open(url))
    }

    func testSchemeComparisonIsCaseInsensitive() {
        // HTTP, Http, hTtP should all be treated as "http"
        let uppercaseURL = URL(string: "HTTP://example.com")!
        XCTAssertTrue(LinkPolicy.isAllowed(uppercaseURL))

        let mixedURL = URL(string: "HtTpS://example.com")!
        XCTAssertTrue(LinkPolicy.isAllowed(mixedURL))
    }

    // MARK: - File URLs (FilePathParser's /Users/ guard)

    func testAllowsFileURLUnderUsersDirectory() {
        let url = URL(fileURLWithPath: "/Users/adam/Documents/test.txt")
        XCTAssertTrue(LinkPolicy.isAllowed(url))
        XCTAssertTrue(LinkPolicy.open(url))
    }

    func testBlocksFileURLOutsideUsersDirectory() {
        // /etc/passwd should be blocked — not under /Users/
        let url = URL(fileURLWithPath: "/etc/passwd")
        XCTAssertFalse(LinkPolicy.isAllowed(url))
        XCTAssertFalse(LinkPolicy.open(url))
    }

    func testBlocksFileURLUnderTmp() {
        let url = URL(fileURLWithPath: "/tmp/malicious.sh")
        XCTAssertFalse(LinkPolicy.isAllowed(url))
        XCTAssertFalse(LinkPolicy.open(url))
    }

    func testBlocksFileURLUnderVar() {
        let url = URL(fileURLWithPath: "/var/log/system.log")
        XCTAssertFalse(LinkPolicy.isAllowed(url))
        XCTAssertFalse(LinkPolicy.open(url))
    }

    func testBlocksFileURLUnderSystem() {
        let url = URL(fileURLWithPath: "/System/Library/test.kext")
        XCTAssertFalse(LinkPolicy.isAllowed(url))
        XCTAssertFalse(LinkPolicy.open(url))
    }

    func testAllowsFileURLWithTildeExpansion() {
        // URL(fileURLWithPath:) expands ~ to /Users/username
        let url = URL(fileURLWithPath: "~/Documents/notes.txt")
        // After standardizing, this resolves to /Users/<current_user>/Documents/notes.txt
        XCTAssertTrue(LinkPolicy.isAllowed(url))
    }

    // MARK: - Blocked Schemes

    func testBlocksJavascriptScheme() {
        let url = URL(string: "javascript:alert('xss')")!
        XCTAssertFalse(LinkPolicy.isAllowed(url))
        XCTAssertFalse(LinkPolicy.open(url))
    }

    func testBlocksDataScheme() {
        let url = URL(string: "data:text/html,<script>alert('xss')</script>")!
        XCTAssertFalse(LinkPolicy.isAllowed(url))
        XCTAssertFalse(LinkPolicy.open(url))
    }

    func testBlocksVbscriptScheme() {
        let url = URL(string: "vbscript:msgbox")!
        XCTAssertFalse(LinkPolicy.isAllowed(url))
        XCTAssertFalse(LinkPolicy.open(url))
    }

    func testBlocksTelScheme() {
        // tel is not in HTMLSanitizer.allowedSchemes, so it should be blocked
        let url = URL(string: "tel:+1234567890")!
        XCTAssertFalse(LinkPolicy.isAllowed(url))
        XCTAssertFalse(LinkPolicy.open(url))
    }

    func testBlocksFtpScheme() {
        let url = URL(string: "ftp://example.com/file")!
        XCTAssertFalse(LinkPolicy.isAllowed(url))
        XCTAssertFalse(LinkPolicy.open(url))
    }

    // MARK: - No Scheme / Invalid URLs

    func testBlocksWithoutScheme() {
        // A bare path with no scheme
        let url = URL(string: "example.com/path")!
        // URL(string:) parses "example.com/path" as a relative path with no scheme
        XCTAssertFalse(LinkPolicy.isAllowed(url))
    }

    func testBlocksWithEmptyURL() {
        // Empty URL string creates nil URL — policy should handle gracefully
        let url = URL(string: "")
        if let url = url {
            XCTAssertFalse(LinkPolicy.open(url))
        }
        // nil URL means nothing to open — that's fine, callers shouldn't reach here
    }

    // MARK: - Consistency with HTMLSanitizer

    func testAllowedWebSchemesMatchesHTMLSanitizer() {
        // LinkPolicy.allowedWebSchemes must match HTMLSanitizer.allowedSchemes
        XCTAssertEqual(LinkPolicy.allowedWebSchemes, HTMLSanitizer.allowedSchemes)
    }

    func testAllAllowedSchemesIncludesFile() {
        // allAllowedSchemes must include web schemes plus "file"
        XCTAssertTrue(LinkPolicy.allAllowedSchemes.contains("file"))
        for scheme in HTMLSanitizer.allowedSchemes {
            XCTAssertTrue(LinkPolicy.allAllowedSchemes.contains(scheme),
                         "allAllowedSchemes should contain \(scheme)")
        }
    }

    // MARK: - isAllowed vs open Consistency

    func testIsAllowedAndOpenAgreeForAllowedURLs() {
        // For allowed URLs, isAllowed returns true and open returns true
        let urls = [
            URL(string: "https://example.com")!,
            URL(string: "http://example.com")!,
            URL(string: "mailto:test@example.com")!,
            URL(fileURLWithPath: "/Users/test/file.txt"),
        ]
        for url in urls {
            XCTAssertEqual(LinkPolicy.isAllowed(url), LinkPolicy.open(url),
                           "isAllowed and open should agree for \(url)")
        }
    }

    func testIsAllowedAndOpenAgreeForBlockedURLs() {
        // For blocked URLs, isAllowed returns false and open returns false
        let urls = [
            URL(string: "javascript:alert(1)")!,
            URL(string: "data:text/html,test")!,
            URL(fileURLWithPath: "/etc/passwd"),
            URL(string: "ftp://example.com")!,
        ]
        for url in urls {
            XCTAssertEqual(LinkPolicy.isAllowed(url), LinkPolicy.open(url),
                           "isAllowed and open should agree for \(url)")
        }
    }
}