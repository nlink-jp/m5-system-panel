import XCTest
@testable import PanelCore

final class SetupMessageTests: XCTestCase {
    func testGreeting() {
        XCTAssertEqual(SetupGreeting.parse("SETUP 1 3F2A"), SetupGreeting(deviceID: "3F2A"))
        XCTAssertEqual(SetupGreeting(deviceID: "3F2A").line, "SETUP 1 3F2A")
        XCTAssertEqual(SetupGreeting.parse("SETUP 2 3F2A")?.version, 2)
        XCTAssertNil(SetupGreeting.parse("SETUP 1 3f2a"))
        XCTAssertNil(SetupGreeting.parse("SETUP 01 3F2A"))
    }

    func testScannedNetwork() {
        let net = ScannedNetwork(rssi: -61, security: .wpa2wpa3, ssid: Array("home".utf8))
        XCTAssertEqual(net.line, "NET -61 wpa2wpa3 aG9tZQ==")
        XCTAssertEqual(ScannedNetwork.parse(net.line), net)
        // Any bytes, not only UTF-8.
        let raw = ScannedNetwork(rssi: 0, security: .other, ssid: [0xff, 0x00, 0x80])
        XCTAssertEqual(ScannedNetwork.parse(raw.line), raw)
    }

    func testScannedNetworkRejects() {
        for line in [
            "NET -061 wpa2 aG9tZQ==", "NET -0 wpa2 aG9tZQ==", "NET -1000 wpa2 aG9tZQ==", "NET +5 wpa2 aG9tZQ==",
            "NET -61 wep aG9tZQ==", "NET -61 wpa2 aG9tZQ", "NET -61 wpa2",
            "NET -61 wpa2 " + StrictBase64.encode([UInt8](repeating: 0x41, count: 33)),
        ] {
            XCTAssertNil(ScannedNetwork.parse(line), line)
        }
    }

    func testJoin() {
        let join = JoinRequest(ssid: Array("home".utf8), password: Array("secret123".utf8))
        XCTAssertEqual(join.line, "JOIN aG9tZQ== c2VjcmV0MTIz")
        XCTAssertEqual(JoinRequest.parse(join.line!), join)
        let open = JoinRequest(ssid: Array("cafe".utf8), password: nil)
        XCTAssertEqual(open.line, "JOIN Y2FmZQ== -")
        XCTAssertEqual(JoinRequest.parse("JOIN Y2FmZQ== -"), open)
        XCTAssertNil(JoinRequest(ssid: [], password: nil).line, "empty SSID")
        XCTAssertNil(JoinRequest(ssid: [0x41], password: []).line, "empty password is written as -, not as nothing")
        XCTAssertNil(JoinRequest(ssid: [0x41], password: [UInt8](repeating: 0x41, count: 64)).line)
    }

    func testKey() {
        let key = [UInt8](0..<32)
        XCTAssertEqual(KeyDelivery.parse(KeyDelivery(key: key).line), KeyDelivery(key: key))
        XCTAssertNil(KeyDelivery.parse("KEY " + StrictBase64.encode([UInt8](0..<31))))
    }
}

final class SetupExchangeTests: XCTestCase {
    private let key = [UInt8](0..<32)

    private func greeted() -> SetupExchange {
        var exchange = SetupExchange()
        XCTAssertEqual(exchange.receive("SETUP 1 3F2A"), [])
        XCTAssertEqual(exchange.phase, .ready(deviceID: "3F2A"))
        return exchange
    }

    func testFullExchangeWithList() {
        var exchange = greeted()
        XCTAssertEqual(exchange.requestList(), [.send("LIST")])
        let net = ScannedNetwork(rssi: -50, security: .wpa2, ssid: Array("home".utf8))
        XCTAssertEqual(exchange.receive(net.line), [])
        XCTAssertEqual(exchange.receive("END"), [])
        XCTAssertEqual(exchange.phase, .listed(deviceID: "3F2A", networks: [net]))
        XCTAssertEqual(exchange.join(ssid: net.ssid, password: Array("pw123456".utf8)),
                       [.send("JOIN aG9tZQ== cHcxMjM0NTY=")])
        XCTAssertEqual(exchange.receive(KeyDelivery(key: key).line),
                       [.storeProvisionalKey(deviceID: "3F2A", key: key), .send("STORED")])
        XCTAssertEqual(exchange.receive("DONE"), [.commitProvisionalKey(deviceID: "3F2A"), .close])
        XCTAssertEqual(exchange.phase, .finished(deviceID: "3F2A"))
        XCTAssertEqual(exchange.connectionClosed(), [], "the panel restarts after DONE; that is not a failure")
    }

    func testJoinWithoutListing() {
        var exchange = greeted()
        XCTAssertEqual(exchange.join(ssid: Array("typed".utf8), password: nil), [.send("JOIN dHlwZWQ= -")])
        XCTAssertEqual(exchange.phase, .awaitingKey(deviceID: "3F2A"))
    }

    func testDropBeforeDoneDiscardsTheProvisionalKey() {
        var exchange = greeted()
        _ = exchange.join(ssid: Array("home".utf8), password: nil)
        _ = exchange.receive(KeyDelivery(key: key).line)
        XCTAssertEqual(exchange.connectionClosed(), [.discardProvisionalKey])
        XCTAssertEqual(exchange.phase, .failed(.incomplete))
    }

    func testDropBeforeKeyHasNothingToDiscard() {
        var exchange = greeted()
        _ = exchange.join(ssid: Array("home".utf8), password: nil)
        XCTAssertEqual(exchange.connectionClosed(), [])
        XCTAssertEqual(exchange.phase, .failed(.incomplete))
    }

    func testWrongVersion() {
        var exchange = SetupExchange()
        XCTAssertEqual(exchange.receive("SETUP 2 3F2A"), [.close])
        XCTAssertEqual(exchange.phase, .failed(.firmwareMismatch(version: 2)))
    }

    func testUnsolicitedLinesAreViolations() {
        var exchange = greeted()
        XCTAssertEqual(exchange.receive("END"), [.close], "END before LIST")
        var afterKey = greeted()
        _ = afterKey.join(ssid: Array("home".utf8), password: nil)
        _ = afterKey.receive(KeyDelivery(key: key).line)
        XCTAssertEqual(afterKey.receive("END"), [.discardProvisionalKey, .close])
    }

    func testMoreThanTwentyNetworksIsAViolation() {
        var exchange = greeted()
        _ = exchange.requestList()
        let line = ScannedNetwork(rssi: -50, security: .open, ssid: [0x41]).line
        for _ in 0..<20 { XCTAssertEqual(exchange.receive(line), []) }
        XCTAssertEqual(exchange.receive(line), [.close])
    }

    func testIdleTimeoutOnlyWhileWaitingForThePanel() {
        var idle = greeted()
        XCTAssertEqual(idle.idleTimeout(), [], "waiting for the user is not the panel's silence")
        var waiting = greeted()
        _ = waiting.join(ssid: Array("home".utf8), password: nil)
        _ = waiting.receive(KeyDelivery(key: key).line)
        XCTAssertEqual(waiting.idleTimeout(), [.discardProvisionalKey, .close])
        XCTAssertEqual(waiting.phase, .failed(.timedOut))
    }
}
