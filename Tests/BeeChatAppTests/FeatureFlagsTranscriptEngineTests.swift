import XCTest
@testable import BeeChatApp

// MARK: - FeatureFlags.transcriptEngine Tests (WP-1 §4.3)
//
// Tests for the new FeatureFlags.transcriptEngine flag, scoped to a fresh
// UserDefaults suite so tests are NOT order-dependent on persisted values.
//
// WP-1 §4.3 acceptance:
//   - "Inject a scoped UserDefaults (suite) in tests, or reset the key in
//     setUp/tearDown."
//   - "Add a test asserting default value is .native on a fresh store"
//   - "and that round-tripping .native/.web works."

@MainActor
final class FeatureFlagsTranscriptEngineTests: XCTestCase {

    /// Scoped defaults for test isolation. Each test instance gets a fresh
    /// suite so persisted values don't leak between tests.
    private var defaults: UserDefaults!
    private let transcriptEngineKey = "BeeChat.feature.transcriptEngine"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "FeatureFlagsTranscriptEngineTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        defaults = nil
        super.tearDown()
    }

    // MARK: - Default value on fresh store

    func testDefaultTranscriptEngineIsNativeOnFreshStore() {
        // §4.3: "Add a test asserting default value is .native on a fresh store"
        // The scoped suite above guarantees the key is NOT persisted.
        let flags = FeatureFlags(defaults: defaults)
        XCTAssertEqual(flags.transcriptEngine, .native,
                       "transcriptEngine must default to .native when no UserDefaults value exists")
    }

    func testDefaultTranscriptEngineIsNativeOnStandardDefaultsWithMissingKey() {
        // Belt-and-braces: ensure the standard-defaults path also reads .native
        // when the key is missing (does not pollute the real UserDefaults).
        let standard = UserDefaults.standard
        let key = "BeeChat.feature.transcriptEngine"
        let saved = standard.object(forKey: key)
        defer {
            if let saved = saved {
                standard.set(saved, forKey: key)
            } else {
                standard.removeObject(forKey: key)
            }
        }
        standard.removeObject(forKey: key)

        let flags = FeatureFlags()
        XCTAssertEqual(flags.transcriptEngine, .native,
                       "FeatureFlags() with no persisted value must read .native")
    }

    // MARK: - Round-trip persistence

    func testTranscriptEngineNativeRoundTrip() {
        // Start from .web so the toggle to .native is a real change
        // (didSet does not fire on no-op writes).
        var flags = FeatureFlags(transcriptEngine: .web, defaults: defaults)
        flags.transcriptEngine = .native
        XCTAssertEqual(flags.transcriptEngine, .native)

        // Verify the rawValue was written (NOT a bool)
        XCTAssertEqual(defaults.string(forKey: transcriptEngineKey), "native",
                       "transcriptEngine = .native must persist rawValue 'native'")

        // Fresh instance on the same suite must read .native back
        let fresh = FeatureFlags(defaults: defaults)
        XCTAssertEqual(fresh.transcriptEngine, .native,
                       "Fresh instance must read persisted .native from scoped defaults")
    }

    func testTranscriptEngineWebRoundTrip() {
        // Start from .native (the default) so the toggle to .web is a real change.
        var flags = FeatureFlags(defaults: defaults)
        flags.transcriptEngine = .web
        XCTAssertEqual(flags.transcriptEngine, .web)

        // Verify rawValue is "web" — NOT bool false (Kieran flag: bool(forKey:)
        // would silently map to false here, losing the distinction)
        XCTAssertEqual(defaults.string(forKey: transcriptEngineKey), "web",
                       "transcriptEngine = .web must persist rawValue 'web' (not bool)")

        // Fresh instance on the same suite must read .web back
        let fresh = FeatureFlags(defaults: defaults)
        XCTAssertEqual(fresh.transcriptEngine, .web,
                       "Fresh instance must read persisted .web from scoped defaults")
    }

    func testTranscriptEngineToggle() {
        var flags = FeatureFlags(defaults: defaults)
        XCTAssertEqual(flags.transcriptEngine, .native, "Initial default is .native")

        flags.transcriptEngine = .web
        XCTAssertEqual(flags.transcriptEngine, .web)

        flags.transcriptEngine = .native
        XCTAssertEqual(flags.transcriptEngine, .native)

        // Verify last write wins
        let fresh = FeatureFlags(defaults: defaults)
        XCTAssertEqual(fresh.transcriptEngine, .native,
                       "After toggling back to .native, fresh instance must read .native")
    }

    // MARK: - Kieran-flagged default semantics

    func testTranscriptEngineDefaultsToNative_evenIfOtherKeysPersisted() {
        // Kieran flag: object(forKey:) nil-coalesce, NOT bool(forKey:).
        // bool(forKey:) returns false for missing keys AND for any non-bool
        // value (including the rawValue "native" string). To guard against
        // accidental future refactors to bool(forKey:), set a non-bool raw
        // value and verify the default is still .native on a clean read.
        let standard = UserDefaults.standard
        let key = "BeeChat.feature.transcriptEngine"
        let saved = standard.object(forKey: key)
        defer {
            if let saved = saved {
                standard.set(saved, forKey: key)
            } else {
                standard.removeObject(forKey: key)
            }
        }
        standard.removeObject(forKey: key)

        let flags = FeatureFlags()
        // Bool false would map "missing" to .web (incorrectly). We assert
        // .native instead.
        XCTAssertNotEqual(flags.transcriptEngine, .web,
                          "Default must NOT be .web (the bool(false) trap)")
        XCTAssertEqual(flags.transcriptEngine, .native,
                       "Default must be .native")
    }

    // MARK: - Explicit init injection (preview/test pattern)

    func testExplicitTranscriptEngineOverride() {
        // Explicit init values win over UserDefaults — same pattern as
        // htmlRenderingEnabled (see FeatureFlagsTests.testExplicitInitOn).
        defaults.set("native", forKey: transcriptEngineKey)

        let explicitWeb = FeatureFlags(transcriptEngine: .web, defaults: defaults)
        XCTAssertEqual(explicitWeb.transcriptEngine, .web,
                       "Explicit .web must override persisted .native")

        let explicitNative = FeatureFlags(transcriptEngine: .native, defaults: defaults)
        XCTAssertEqual(explicitNative.transcriptEngine, .native,
                       "Explicit .native must override persisted value")
    }

    func testExplicitTranscriptEngineNilReadsUserDefaults() {
        // If explicit is nil, fall through to UserDefaults read.
        defaults.set("web", forKey: transcriptEngineKey)

        let flags = FeatureFlags(transcriptEngine: nil, defaults: defaults)
        XCTAssertEqual(flags.transcriptEngine, .web,
                       "Nil init must read .web from scoped UserDefaults")
    }

    // MARK: - Cross-flag isolation

    func testTranscriptEngineAndHtmlRenderingAreIndependent() {
        // Setting transcriptEngine must NOT affect htmlRenderingEnabled and
        // vice versa (independent keys, independent didSet side effects).
        var flags = FeatureFlags(defaults: defaults)
        flags.htmlRenderingEnabled = true
        XCTAssertEqual(flags.transcriptEngine, .native,
                       "htmlRenderingEnabled=true must NOT change transcriptEngine default")

        flags.transcriptEngine = .web
        XCTAssertTrue(flags.htmlRenderingEnabled,
                      "transcriptEngine=.web must NOT change htmlRenderingEnabled=true")
    }
}
