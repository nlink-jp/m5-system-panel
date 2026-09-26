import XCTest
@testable import PanelCore

final class ServiceNameTests: XCTestCase {
    func testOurServiceNameIsValid() {
        // 15 characters exactly — the RFC 6335 maximum. A rename that adds one
        // character breaks discovery, so it must fail here first.
        XCTAssertEqual(PanelService.name.count, 15)
        XCTAssertTrue(isValidServiceName(PanelService.name))
    }

    func testServiceTypeForm() {
        XCTAssertEqual(PanelService.type, "_m5-system-panel._tcp")
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PanelCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    func testInfoPlistDeclaresTheServiceType() throws {
        // NSBonjourServices must list the type or browsing is refused (TN3179).
        let plist = repositoryRoot.appendingPathComponent("Info.plist")
        let text = try String(contentsOf: plist, encoding: .utf8)
        XCTAssertTrue(text.contains("<string>\(PanelService.type)</string>"))
    }

    func testFirmwareAdvertisesTheSameName() throws {
        // The firmware advertises what its header says; a mismatch makes the
        // companion browse for a service nobody offers.
        let header = repositoryRoot
            .appendingPathComponent("firmware/m5-system-panel/src/panel_service.h")
        let text = try String(contentsOf: header, encoding: .utf8)
        XCTAssertTrue(
            text.contains("#define PANEL_SERVICE_NAME \"\(PanelService.name)\""),
            "panel_service.h must define PANEL_SERVICE_NAME as \"\(PanelService.name)\""
        )
    }

    // RFC 6335 §5.1, one rule per case.

    func testLengthLimits() {
        XCTAssertFalse(isValidServiceName(""))
        XCTAssertTrue(isValidServiceName("a"))
        XCTAssertTrue(isValidServiceName(String(repeating: "a", count: 15)))
        XCTAssertFalse(isValidServiceName(String(repeating: "a", count: 16)))
    }

    func testOnlyLettersDigitsAndHyphens() {
        XCTAssertFalse(isValidServiceName("m5_panel"))
        XCTAssertFalse(isValidServiceName("m5.panel"))
        XCTAssertFalse(isValidServiceName("m5 panel"))
        XCTAssertFalse(isValidServiceName("ｍ5-panel"))   // full-width letter
    }

    func testAtLeastOneLetter() {
        XCTAssertFalse(isValidServiceName("23"))
        XCTAssertFalse(isValidServiceName("6000-6063"))
        XCTAssertTrue(isValidServiceName("x23"))
    }

    func testNoLeadingOrTrailingHyphen() {
        XCTAssertFalse(isValidServiceName("-panel"))
        XCTAssertFalse(isValidServiceName("panel-"))
    }

    func testNoAdjacentHyphens() {
        XCTAssertFalse(isValidServiceName("m5--panel"))
        XCTAssertTrue(isValidServiceName("m5-sys-panel"))
    }

    func testCaseIsAllowed() {
        XCTAssertTrue(isValidServiceName("HTTP"))
    }
}
