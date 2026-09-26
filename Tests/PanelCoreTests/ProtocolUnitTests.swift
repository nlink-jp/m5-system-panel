import CryptoKit
import XCTest
@testable import PanelCore

/// Rules of protocol v1 that the vectors do not pin down on their own.
final class ProtocolUnitTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testLineBufferSplitsOnLFAndKeepsPartialLines() throws {
        var buffer = LineBuffer()
        XCTAssertEqual(try buffer.append(Array("HELLO 1 3F2A ".utf8)), [])
        XCTAssertEqual(try buffer.append(Array("x\nAUTH y\nF".utf8)), ["HELLO 1 3F2A x", "AUTH y"])
        XCTAssertEqual(try buffer.append(Array("z\n".utf8)), ["Fz"])
    }

    func testLineBufferRefusesCRAndNonASCII() {
        var withCR = LineBuffer()
        XCTAssertThrowsError(try withCR.append(Array("A\r\n".utf8)))
        var withUTF8 = LineBuffer()
        XCTAssertThrowsError(try withUTF8.append(Array("é\n".utf8)))
    }

    func testCounterAdvancesAndCannotBeReused() throws {
        var sealer = FrameSealer(key: key)
        var opener = FrameOpener(key: key)
        let first = try sealer.seal("A seq=- up=1")
        let second = try sealer.seal("A seq=- up=1")
        XCTAssertNotEqual(first, second, "same plaintext, different counter, different line")
        XCTAssertEqual(try opener.open(first), "A seq=- up=1")
        XCTAssertThrowsError(try opener.open(first), "a replayed frame must fail")
    }

    func testSealerRefusesTooLongAndNonASCIIPlaintexts() {
        var sealer = FrameSealer(key: key)
        XCTAssertThrowsError(try sealer.seal(String(repeating: "x", count: 701))) {
            XCTAssertEqual($0 as? ProtocolError, .plaintextTooLong)
        }
        XCTAssertThrowsError(try sealer.seal("naïve")) { XCTAssertEqual($0 as? ProtocolError, .notASCII) }
        XCTAssertEqual(sealer.counter, 0, "a refused plaintext does not consume a counter value")
    }

    func testNonceLayout() {
        // 0x00000000 ‖ uint64_be(ctr)
        let nonce = Frame.nonce(0x0102_0304_0506_0708)
        XCTAssertEqual(Array(nonce), [0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testDirectionsUseDifferentKeys() throws {
        let keys = try SessionKeys(
            key: Array(repeating: 7, count: 32), deviceID: "0A1B",
            panelNonce: Array(repeating: 1, count: 16), companionNonce: Array(repeating: 2, count: 16))
        XCTAssertNotEqual(keys.c2p, keys.p2c)
    }

    func testSessionKeysDependOnEveryInput() throws {
        func derive(id: String = "0A1B", np: UInt8 = 1, nc: UInt8 = 2) throws -> SymmetricKey {
            try SessionKeys(key: Array(repeating: 7, count: 32), deviceID: id,
                            panelNonce: Array(repeating: np, count: 16),
                            companionNonce: Array(repeating: nc, count: 16)).c2p
        }
        let base = try derive()
        XCTAssertNotEqual(base, try derive(id: "0A1C"))
        XCTAssertNotEqual(base, try derive(np: 9))
        XCTAssertNotEqual(base, try derive(nc: 9))
    }

    func testSessionKeysRefuseBadInputs() {
        XCTAssertThrowsError(try SessionKeys(key: Array(repeating: 0, count: 31), deviceID: "0A1B",
                                             panelNonce: Array(repeating: 0, count: 16),
                                             companionNonce: Array(repeating: 0, count: 16)))
        XCTAssertThrowsError(try SessionKeys(key: Array(repeating: 0, count: 32), deviceID: "0a1b",
                                             panelNonce: Array(repeating: 0, count: 16),
                                             companionNonce: Array(repeating: 0, count: 16)))
    }

    func testHelloParsesOtherVersionsSoTheCompanionCanSayWhy() {
        let hello = Hello.parse("HELLO 2 3F2A oKGio6SlpqeoqaqrrK2urw==")
        XCTAssertEqual(hello?.version, 2)
        XCTAssertNil(Hello.parse("HELLO 1 3f2a oKGio6SlpqeoqaqrrK2urw=="), "lower-case device ID")
        XCTAssertNil(Hello.parse("HELLO 1 3F2A oKGio6SlpqeoqaqrrK2u"), "12-byte nonce")
        XCTAssertNil(Hello.parse("HELLO  1 3F2A oKGio6SlpqeoqaqrrK2urw=="), "empty token")
    }

    func testMeasurementEncodingRefusesOutOfRangeValues() {
        let valid = Readings(
            seq: 0, cpuTenths: 0, cores: [CoreUsage(kind: .performance, percent: 0)], gpuTenths: nil,
            memoryUsed: 0, memoryTotal: 0, memoryApp: 0, memoryWired: 0, memoryCompressed: 0, swapUsed: 0,
            pressure: 0, interface: nil, rxBytesPerSecond: 0, txBytesPerSecond: 0)
        XCTAssertNoThrow(try valid.encoded())
        var cases: [Readings] = []
        var m = valid; m.cpuTenths = 1001; cases.append(m)
        m = valid; m.cores = []; cases.append(m)
        m = valid; m.cores = Array(repeating: CoreUsage(kind: .efficiency, percent: 1), count: 65); cases.append(m)
        m = valid; m.cores = [CoreUsage(kind: .performance, percent: 101)]; cases.append(m)
        m = valid; m.pressure = 3; cases.append(m)
        m = valid; m.interface = "en 0"; cases.append(m)
        m = valid; m.rxBytesPerSecond = UInt64(Int64.max) + 1; cases.append(m)
        for measurement in cases {
            XCTAssertThrowsError(try measurement.encoded(), "\(measurement)")
        }
    }

    func testTenthsFormatting() {
        XCTAssertEqual(Wire.tenths(0), "0.0")
        XCTAssertEqual(Wire.tenths(5), "0.5")
        XCTAssertEqual(Wire.tenths(1000), "100.0")
        XCTAssertEqual(Wire.parseTenths("0.5"), 5)
        XCTAssertNil(Wire.parseTenths("07.5"))
        XCTAssertNil(Wire.parseTenths(".5"))
        XCTAssertNil(Wire.parseTenths("5."))
    }
}
