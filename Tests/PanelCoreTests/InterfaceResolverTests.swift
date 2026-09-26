// Copied from util-series/net-meter bcdefee Tests/NetMeterCoreTests/InterfaceResolverTests.swift — keep in step with the original.
import XCTest
@testable import PanelCore

final class InterfaceResolverTests: XCTestCase {
    /// Measured three times on macOS 27.0: wired first, listed twice, then Wi-Fi.
    private let measuredPath = [
        PathInterface(name: "en0", kind: .wiredEthernet),
        PathInterface(name: "en0", kind: .wiredEthernet),
        PathInterface(name: "en1", kind: .wifi),
    ]

    func testAutomaticTakesTheFirstPhysicalInterface() {
        XCTAssertEqual(
            resolveInterface(selection: .automatic, pathOrder: measuredPath, available: ["en0", "en1", "lo0"]),
            .present("en0")
        )
    }

    func testAutomaticKeepsThePhysicalLinkWhileASplitTunnelVPNIsUp() {
        // Measured once (macOS 27.0, split tunnel): the tunnel is listed LAST, with kind `other`,
        // and the physical interfaces keep their places.
        let vpn = measuredPath + [PathInterface(name: "utun6", kind: .other)]
        XCTAssertEqual(
            resolveInterface(selection: .automatic, pathOrder: vpn, available: ["utun6", "en0", "en1"]),
            .present("en0")
        )
    }

    func testAutomaticSkipsATunnelAheadOfThePhysicalLink() {
        // Not measured: a full-tunnel VPN may list its tunnel first. The rule does not depend on
        // where the tunnel sits, only on its kind.
        let vpn = [PathInterface(name: "utun7", kind: .other)] + measuredPath
        XCTAssertEqual(
            resolveInterface(selection: .automatic, pathOrder: vpn, available: ["utun7", "en0", "en1"]),
            .present("en0")
        )
    }

    func testAutomaticFallsToTheNextPhysicalInterfaceWhenTheFirstHasNoCounters() {
        XCTAssertEqual(
            resolveInterface(selection: .automatic, pathOrder: measuredPath, available: ["en1"]),
            .present("en1")
        )
    }

    func testAutomaticWithNoPhysicalInterfaceIsAbsent() {
        let onlyTunnel = [PathInterface(name: "utun7", kind: .other), PathInterface(name: "lo0", kind: .loopback)]
        XCTAssertEqual(resolveInterface(selection: .automatic, pathOrder: onlyTunnel, available: ["utun7", "lo0"]), .absent)
        XCTAssertEqual(resolveInterface(selection: .automatic, pathOrder: [], available: ["en0"]), .absent)
    }

    func testManualSelectionMayBeAnyInterfaceWithCounters() {
        XCTAssertEqual(
            resolveInterface(selection: .manual("utun7"), pathOrder: measuredPath, available: ["utun7", "en0"]),
            .present("utun7")
        )
    }

    func testManualSelectionThatIsGoneIsAbsentAndNeverReplaced() {
        // An unplugged adapter must not silently turn into another interface's numbers.
        XCTAssertEqual(
            resolveInterface(selection: .manual("en5"), pathOrder: measuredPath, available: ["en0", "en1"]),
            .absent
        )
    }

    func testSelectionRoundTripsThroughItsStoredValue() {
        XCTAssertEqual(InterfaceSelection(storedValue: nil), .automatic)
        XCTAssertEqual(InterfaceSelection(storedValue: ""), .automatic)
        XCTAssertEqual(InterfaceSelection(storedValue: "en1"), .manual("en1"))
        for selection in [InterfaceSelection.automatic, .manual("en1")] {
            XCTAssertEqual(InterfaceSelection(storedValue: selection.storedValue), selection)
        }
    }
}
