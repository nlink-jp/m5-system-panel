import XCTest
@testable import PanelCore

final class AppVersionTests: XCTestCase {
    func testOutsideABundleReadsAsDev() {
        XCTAssertEqual(displayVersion(bundleShortVersion: nil), "dev")
    }

    func testEmptyValueReadsAsDev() {
        XCTAssertEqual(displayVersion(bundleShortVersion: ""), "dev")
    }

    func testReleaseVersionIsShownVerbatim() {
        XCTAssertEqual(displayVersion(bundleShortVersion: "v0.1.0"), "v0.1.0")
    }

    func testDevelopmentSuffixesAreKept() {
        // A bug report has to be able to name the exact build.
        XCTAssertEqual(
            displayVersion(bundleShortVersion: "v0.1.0-3-gabc1234-dirty"),
            "v0.1.0-3-gabc1234-dirty"
        )
    }
}
