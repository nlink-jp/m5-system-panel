import XCTest
@testable import PanelCore

final class RegistrationTests: XCTestCase {
    private let key = [UInt8](0..<32)

    func testRoundTrip() throws {
        let registration = try XCTUnwrap(Registration(deviceID: "3F2A", key: key))
        XCTAssertEqual(registration.data.count, 36)
        XCTAssertEqual(Registration(data: registration.data), registration)
    }

    func testRefusesBadInputs() {
        XCTAssertNil(Registration(deviceID: "3f2a", key: key))
        XCTAssertNil(Registration(deviceID: "3F2A", key: Array(key.prefix(31))))
        XCTAssertNil(Registration(data: Data(repeating: 0, count: 35)))
        XCTAssertNil(Registration(data: Data(Array("zzzz".utf8) + key)))
    }

    func testPendingIsCommittedOnlyExplicitly() throws {
        let old = try XCTUnwrap(Registration(deviceID: "0001", key: key))
        let new = try XCTUnwrap(Registration(deviceID: "3F2A", key: Array(key.reversed())))
        let store = MemoryRegistrationStore(active: old)
        try store.savePending(new)
        XCTAssertEqual(try store.active(), old, "pending does not replace the active registration")
        try store.discardPending()
        XCTAssertEqual(try store.active(), old)
        XCTAssertThrowsError(try store.commitPending())
        try store.savePending(new)
        try store.commitPending()
        XCTAssertEqual(try store.active(), new)
        XCTAssertNil(store.pending)
        try store.removeAll()
        XCTAssertNil(try store.active())
    }
}

final class MenuTextTests: XCTestCase {
    func testEveryStatusHasWords() throws {
        let registration = try XCTUnwrap(Registration(deviceID: "3F2A", key: [UInt8](0..<32)))
        XCTAssertEqual(MenuText.status(registered: nil, supervisor: .searching), "未設定")
        let statuses: [ConnectionSupervisor.Status] = [
            .searching, .connected(deviceID: "3F2A"), .notResponding, .permissionRequired, .firmwareMismatch,
        ]
        let texts = statuses.map { MenuText.status(registered: registration, supervisor: $0) }
        XCTAssertEqual(Set(texts).count, statuses.count, "each status reads differently")
        XCTAssertTrue(texts[1].contains("3F2A"))
        XCTAssertNotNil(MenuText.hint(supervisor: .permissionRequired))
        XCTAssertNil(MenuText.hint(supervisor: .connected(deviceID: "3F2A")))
    }

    func testPolicyDenialMapping() {
        XCTAssertTrue(ConnectionEventMapping.isPolicyDenied(dnsErrorCode: -65570, unsatisfiedIsLocalNetworkDenied: false),
                      "what macOS 27 reported (ADR-0001 3b)")
        XCTAssertTrue(ConnectionEventMapping.isPolicyDenied(dnsErrorCode: nil, unsatisfiedIsLocalNetworkDenied: true),
                      "what TN3179 documents")
        XCTAssertFalse(ConnectionEventMapping.isPolicyDenied(dnsErrorCode: -65563, unsatisfiedIsLocalNetworkDenied: false))
        XCTAssertFalse(ConnectionEventMapping.isPolicyDenied(dnsErrorCode: nil, unsatisfiedIsLocalNetworkDenied: false))
    }
}
