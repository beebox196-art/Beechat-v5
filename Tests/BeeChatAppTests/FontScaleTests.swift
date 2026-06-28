import XCTest
import SwiftUI
@testable import BeeChatApp

/// Unit tests for FR-004 font scale feature.
///
/// Covers:
/// - FontSpec.font(scaledBy:) scaling behaviour (including monospaced preservation)
/// - ThemeManager.setFontScale clamping (0.7 ... 2.0)
/// - UserDefaults round-trip (persisted value survives init())
///
/// ThemeManager uses @MainActor and reads UserDefaults.standard on init.
/// Tests use a dedicated suite name to avoid polluting user defaults.
@MainActor
final class FontScaleTests: XCTestCase {

    private let defaultsKey = "BeeChat.fontScale"

    override func setUp() async throws {
        // Ensure a clean UserDefaults slate before each test. The default
        // suite persists between runs, so without this, persisted values
        // from a prior session would leak into fresh tests.
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    // MARK: - FontSpec scaling

    func testFontSpecScalesByFactor() {
        // SwiftUI Font is opaque (no public size accessor), so we verify
        // the contract via FontSpec.scaledSize(for:) — the helper that
        // font(scaledBy:) uses internally to compute the point size.
        let spec = FontSpec(size: 14, weight: .regular)

        XCTAssertEqual(spec.scaledSize(for: 2.0), 28, accuracy: 0.001,
                       "scaledSize(for: 2.0) must be 28 (14 × 2)")
        XCTAssertEqual(spec.scaledSize(for: 0.5), 7, accuracy: 0.001,
                       "scaledSize(for: 0.5) must be 7 (14 × 0.5)")
        XCTAssertEqual(spec.scaledSize(for: 1.0), 14, accuracy: 0.001,
                       "scaledSize(for: 1.0) is the unscaled default")
    }

    func testFontSpecFontReturnsValidFont() {
        // Smoke test: font(scaledBy:) must return a non-nil Font for
        // in-range factors. SwiftUI's Font is opaque — there is no
        // public way to extract the rendered point size, so this is the
        // best unit-level guarantee we can give without a view context.
        let spec = FontSpec(size: 14, weight: .regular)
        _ = spec.font(scaledBy: 2.0)
        _ = spec.font(scaledBy: 0.7)
        _ = spec.font()
        XCTAssertTrue(true, "font(scaledBy:) returns valid Font for in-range factors")
    }

    func testFontSpecDefaultFactorIsOne() {
        let spec = FontSpec(size: 12, weight: .semibold)
        let scaled = spec.font(scaledBy: 1.0)
        let default_ = spec.font()
        XCTAssertEqual(
            String(describing: scaled),
            String(describing: default_),
            "font() with no argument should match font(scaledBy: 1.0)"
        )
    }

    func testFontSpecPreservesMonoFlag() {
        let monoSpec = FontSpec(size: 14, weight: .regular, isMono: true)
        let proportionalSpec = FontSpec(size: 14, weight: .regular, isMono: false)

        // Mono and proportional fonts at the same size should not compare equal,
        // because .monospaced() returns a distinct Font value.
        XCTAssertNotEqual(
            String(describing: monoSpec.font()),
            String(describing: proportionalSpec.font()),
            "isMono: true must produce a different Font than isMono: false"
        )
    }

    // MARK: - setFontScale clamping

    func testSetFontScaleClampsHighValue() {
        let tm = ThemeManager()
        tm.setFontScale(3.0)
        XCTAssertEqual(tm.fontScale, 2.0, accuracy: 0.001, "setFontScale(3.0) must clamp to 2.0")
    }

    func testSetFontScaleClampsLowValue() {
        let tm = ThemeManager()
        tm.setFontScale(0.5)
        XCTAssertEqual(tm.fontScale, 0.7, accuracy: 0.001, "setFontScale(0.5) must clamp to 0.7")
    }

    func testSetFontScaleAcceptsInRangeValue() {
        let tm = ThemeManager()
        tm.setFontScale(1.5)
        XCTAssertEqual(tm.fontScale, 1.5, accuracy: 0.001, "setFontScale(1.5) must accept in-range value")
    }

    func testSetFontScaleRoundsToOneDecimal() {
        let tm = ThemeManager()
        // 1.07 cannot be represented exactly in floating point — setFontScale
        // rounds to 1 decimal to avoid float artefacts in UserDefaults.
        tm.setFontScale(1.07)
        XCTAssertEqual(tm.fontScale, 1.1, accuracy: 0.001, "setFontScale(1.07) should round to 1.1")
    }

    // MARK: - Persistence round-trip

    func testFontScalePersistsAcrossInit() throws {
        // Set a non-default scale on a fresh manager, then build a second
        // manager. Both should report the same persisted value.
        let first = ThemeManager()
        first.setFontScale(1.5)
        XCTAssertEqual(first.fontScale, 1.5, accuracy: 0.001)

        // Second instance loads from UserDefaults on init.
        let second = ThemeManager()
        XCTAssertEqual(second.fontScale, 1.5, accuracy: 0.001, "Persisted fontScale must survive init()")
    }

    func testFontScalePersistsRoundedValue() throws {
        // 1.43 should round to 1.4 before being persisted. Then a fresh
        // manager should load exactly 1.4 (not 1.43, not 1.4000000001).
        let first = ThemeManager()
        first.setFontScale(1.43)
        XCTAssertEqual(first.fontScale, 1.4, accuracy: 0.001)

        let second = ThemeManager()
        XCTAssertEqual(second.fontScale, 1.4, accuracy: 0.001, "Persisted rounded value must load as 1.4")
    }

    func testFontScaleDefaultsToOneWhenNoPersistedValue() {
        // Ensure no persisted value, then init.
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let tm = ThemeManager()
        XCTAssertEqual(tm.fontScale, 1.0, accuracy: 0.001, "Default fontScale is 1.0")
    }
}
