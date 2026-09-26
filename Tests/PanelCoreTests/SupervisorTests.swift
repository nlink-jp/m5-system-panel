import XCTest
@testable import PanelCore

/// A panel built from the same primitives, speaking protocol v1 §4.1 honestly
/// (or, with another key, as a fake).
private struct FakePanel {
    let key: [UInt8]
    let deviceID: String
    let np: [UInt8] = Array(repeating: 0x5A, count: 16)
    var opener: FrameOpener?
    var sealer: FrameSealer?

    init(key: [UInt8], deviceID: String = "3F2A") {
        self.key = key
        self.deviceID = deviceID
    }

    var hello: String { Hello(deviceID: deviceID, panelNonce: np).line }

    /// Takes the companion's AUTH and frame 0; true when frame 0 verifies.
    mutating func accept(auth: String, frame: String) -> Bool {
        guard let nc = Auth.parse(auth)?.companionNonce,
              let keys = try? SessionKeys(key: key, deviceID: deviceID, panelNonce: np, companionNonce: nc)
        else { return false }
        var opener = FrameOpener(key: keys.c2p)
        guard (try? opener.open(frame)) != nil else { return false }
        self.opener = opener
        sealer = FrameSealer(key: keys.p2c)
        return true
    }

    mutating func ack(seq: UInt64?) -> String {
        try! sealer!.seal(Acknowledgement(seq: seq, uptimeMilliseconds: 1000).encoded())
    }
}

final class CompanionSessionTests: XCTestCase {
    private let key = [UInt8](0..<32)
    private let readings = Readings(
        seq: 0, cpuTenths: 10, cores: [1], gpuTenths: nil, memoryUsed: 1, memoryTotal: 2, memoryApp: 0,
        memoryWired: 0, memoryCompressed: 0, swapUsed: 0, pressure: 0, interface: "en0",
        rxBytesPerSecond: 0, txBytesPerSecond: 0)

    func testHandshakeAndFirstAckConfirms() {
        var panel = FakePanel(key: key)
        var session = CompanionSession(key: key, deviceID: "3F2A", companionNonce: Array(repeating: 7, count: 16))
        guard case .send(let lines) = session.receive(panel.hello, firstReadings: readings) else {
            return XCTFail("HELLO must be answered")
        }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("AUTH "))
        XCTAssertTrue(panel.accept(auth: lines[0], frame: lines[1]), "the real panel verifies frame 0")
        XCTAssertEqual(session.receive(panel.ack(seq: 0), firstReadings: readings),
                       .acknowledged(Acknowledgement(seq: 0, uptimeMilliseconds: 1000), first: true))
        XCTAssertEqual(session.receive(panel.ack(seq: 0), firstReadings: readings),
                       .acknowledged(Acknowledgement(seq: 0, uptimeMilliseconds: 1000), first: false))
    }

    func testFakePanelWithAnotherKeyIsRefused() {
        var fake = FakePanel(key: [UInt8](repeating: 9, count: 32))
        var session = CompanionSession(key: key, deviceID: "3F2A", companionNonce: Array(repeating: 7, count: 16))
        guard case .send(let lines) = session.receive(fake.hello, firstReadings: readings) else { return XCTFail() }
        XCTAssertFalse(fake.accept(auth: lines[0], frame: lines[1]), "the fake cannot read frame 0")
        // It answers anyway with a frame under its own key.
        _ = FakePanel.acceptAnyway(&fake, auth: lines[0])
        XCTAssertEqual(session.receive(fake.ack(seq: 0), firstReadings: readings), .close(.verificationFailed))
    }

    func testVersionAndDeviceChecks() {
        var session = CompanionSession(key: key, deviceID: "3F2A", companionNonce: Array(repeating: 7, count: 16))
        XCTAssertEqual(session.receive("HELLO 2 3F2A WlpaWlpaWlpaWlpaWlpaWg==", firstReadings: readings),
                       .close(.firmwareMismatch(version: 2)))
        var other = CompanionSession(key: key, deviceID: "3F2A", companionNonce: Array(repeating: 7, count: 16))
        XCTAssertEqual(other.receive(FakePanel(key: key, deviceID: "0001").hello, firstReadings: readings),
                       .close(.wrongPanel))
    }
}

private extension FakePanel {
    /// A fake that derives keys from its own key regardless of frame 0.
    static func acceptAnyway(_ panel: inout FakePanel, auth: String) -> Bool {
        guard let nc = Auth.parse(auth)?.companionNonce,
              let keys = try? SessionKeys(key: panel.key, deviceID: panel.deviceID, panelNonce: panel.np,
                                          companionNonce: nc) else { return false }
        panel.sealer = FrameSealer(key: keys.p2c)
        return true
    }
}

final class ConnectionSupervisorTests: XCTestCase {
    private let key = [UInt8](0..<32)
    private let nonce = [UInt8](repeating: 7, count: 16)
    private let readings = Readings(
        seq: 0, cpuTenths: 10, cores: [1], gpuTenths: nil, memoryUsed: 1, memoryTotal: 2, memoryApp: 0,
        memoryWired: 0, memoryCompressed: 0, swapUsed: 0, pressure: 0, interface: "en0",
        rxBytesPerSecond: 0, txBytesPerSecond: 0)

    private func supervisor(candidates: [(String, String?)] = [("a", "3F2A")]) -> ConnectionSupervisor {
        var s = ConnectionSupervisor(key: key, deviceID: "3F2A")
        s.candidatesChanged(candidates.map { (endpoint: $0.0, deviceID: $0.1) })
        return s
    }

    private func connects(_ actions: [ConnectionSupervisor.Action]) -> [String] {
        actions.compactMap { if case .connect(_, let endpoint) = $0 { return endpoint } else { return nil } }
    }

    /// Drives a full handshake on connection `id` and returns the sends seen.
    private func handshake(_ s: inout ConnectionSupervisor, id: Int, panel: inout FakePanel, now: Double) {
        _ = s.connectionEvent(.ready, connection: id, now: now)
        let sent = s.lineReceived(panel.hello, connection: id, now: now, nonce: nonce, readings: readings)
        let lines = sent.compactMap { if case .send(_, let line) = $0 { return line } else { return nil } }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(panel.accept(auth: lines[0], frame: lines[1]))
        XCTAssertEqual(s.lineReceived(panel.ack(seq: 0), connection: id, now: now, nonce: nonce, readings: readings),
                       [.status(.connected(deviceID: "3F2A"))])
    }

    func testOnlyThisPanelsIDIsACandidate() {
        var s = supervisor(candidates: [("other", "0001"), ("unnamed", nil), ("mine", "3F2A")])
        XCTAssertEqual(connects(s.tick(now: 0, readings: readings)), ["mine"])
    }

    func testConnectedAfterFirstVerifiedAckAndSendsEverySecond() {
        var s = supervisor()
        var panel = FakePanel(key: key)
        XCTAssertEqual(s.tick(now: 0, readings: readings), [.connect(connection: 1, endpoint: "a")])
        handshake(&s, id: 1, panel: &panel, now: 0.2)
        let actions = s.tick(now: 1, readings: readings)
        guard case .send(1, let line)? = actions.first else { return XCTFail("\(actions)") }
        XCTAssertNotNil(try? panel.opener!.open(line), "frame 1 verifies on the panel")
    }

    func testPreparingForTenSecondsIsReplaced() {
        var s = supervisor()
        _ = s.tick(now: 0, readings: readings)
        _ = s.connectionEvent(.preparing, connection: 1, now: 0)
        XCTAssertTrue(connects(s.tick(now: 9.9, readings: readings)).isEmpty)
        let actions = s.tick(now: 10, readings: readings)
        XCTAssertEqual(actions.first, .cancel(connection: 1))
        XCTAssertEqual(connects(actions), ["a"], "retry interval already passed since the attempt at 0")
    }

    func testWaitingIsLeftToTheOSAndPolicyDenialIsShown() {
        var s = supervisor()
        _ = s.tick(now: 0, readings: readings)
        _ = s.connectionEvent(.preparing, connection: 1, now: 0)
        XCTAssertEqual(s.connectionEvent(.waiting(isPolicyDenied: true), connection: 1, now: 1),
                       [.status(.permissionRequired)])
        XCTAssertTrue(s.tick(now: 30, readings: readings).isEmpty, ".waiting is never timed out")
        // Permission restored: the OS resumes the same connection.
        var panel = FakePanel(key: key)
        _ = s.connectionEvent(.preparing, connection: 1, now: 31)
        handshake(&s, id: 1, panel: &panel, now: 31.5)
    }

    func testNoAckForFiveSecondsIsNotRespondingAndReconnects() {
        var s = supervisor()
        var panel = FakePanel(key: key)
        _ = s.tick(now: 0, readings: readings)
        handshake(&s, id: 1, panel: &panel, now: 0)
        XCTAssertFalse(s.tick(now: 4.9, readings: readings).contains(.cancel(connection: 1)))
        let actions = s.tick(now: 5, readings: readings)
        XCTAssertEqual(Array(actions.prefix(2)), [.status(.notResponding), .cancel(connection: 1)])
        XCTAssertEqual(connects(actions), ["a"])
    }

    func testReadyButSilentPeerIsNotResponding() {
        var s = supervisor()
        _ = s.tick(now: 0, readings: readings)
        _ = s.connectionEvent(.ready, connection: 1, now: 0)
        XCTAssertEqual(s.tick(now: 5, readings: readings).prefix(2), [.status(.notResponding), .cancel(connection: 1)])
    }

    func testFailedConnectionRetriesAfterTheInterval() {
        var s = supervisor()
        _ = s.tick(now: 0, readings: readings)
        _ = s.connectionEvent(.failed, connection: 1, now: 1)
        XCTAssertTrue(connects(s.tick(now: 4.9, readings: readings)).isEmpty)
        XCTAssertEqual(connects(s.tick(now: 5, readings: readings)), ["a"])
    }

    func testFakeWithTheSameIDIsAvoidedAndTheRealOneReached() {
        var s = supervisor(candidates: [("fake", "3F2A"), ("real", "3F2A")])
        var fake = FakePanel(key: [UInt8](repeating: 9, count: 32))
        XCTAssertEqual(connects(s.tick(now: 0, readings: readings)), ["fake"])
        _ = s.connectionEvent(.ready, connection: 1, now: 0)
        let sent = s.lineReceived(fake.hello, connection: 1, now: 0, nonce: nonce, readings: readings)
        guard case .send(_, let auth)? = sent.first else { return XCTFail() }
        _ = FakePanel.acceptAnyway(&fake, auth: auth)
        XCTAssertEqual(s.lineReceived(fake.ack(seq: 0), connection: 1, now: 0.5, nonce: nonce, readings: readings),
                       [.cancel(connection: 1)])
        XCTAssertEqual(connects(s.tick(now: 5, readings: readings)), ["real"])
        _ = s.connectionEvent(.failed, connection: 2, now: 6)
        XCTAssertEqual(connects(s.tick(now: 11, readings: readings)), ["real"], "the fake is avoided for 60 s")
        _ = s.connectionEvent(.failed, connection: 3, now: 12)
        XCTAssertEqual(connects(s.tick(now: 60.5, readings: readings)).count, 1)
    }

    func testFirmwareMismatchIsShown() {
        var s = supervisor()
        _ = s.tick(now: 0, readings: readings)
        _ = s.connectionEvent(.ready, connection: 1, now: 0)
        XCTAssertEqual(s.lineReceived("HELLO 2 3F2A WlpaWlpaWlpaWlpaWlpaWg==", connection: 1, now: 0,
                                      nonce: nonce, readings: readings),
                       [.status(.firmwareMismatch), .cancel(connection: 1)])
    }

    func testEventsForAnOldConnectionAreIgnored() {
        var s = supervisor()
        _ = s.tick(now: 0, readings: readings)
        _ = s.connectionEvent(.preparing, connection: 1, now: 0)
        _ = s.tick(now: 10, readings: readings)  // replaces 1 with 2
        XCTAssertEqual(s.connectionEvent(.failed, connection: 1, now: 10.1), [])
        XCTAssertEqual(s.lineReceived("HELLO 1 3F2A WlpaWlpaWlpaWlpaWlpaWg==", connection: 1, now: 10.2,
                                      nonce: nonce, readings: readings), [])
    }
}
