import CryptoKit
import XCTest
@testable import PanelCore

/// Checks the implementation against testdata/protocol.json: external known
/// answers (RFC 5869, NIST CAVP) for the primitives, and the protocol vectors
/// produced independently by scripts/gen-protocol-vectors.swift.
final class ProtocolVectorTests: XCTestCase {
    private struct Vectors: Decodable {
        struct HKDFCase: Decodable {
            let `case`: Int
            let IKM, salt, info, PRK, OKM: String
            let L: Int
        }
        struct GCMCase: Decodable {
            let key, iv, pt, aad, ct, tag: String
            let count: Int
        }
        struct GCMSet: Decodable {
            let encrypt: [GCMCase]
            let decrypt_fail: [GCMCase]
        }
        struct FrameVector: Decodable {
            let ctr: UInt64
            let plaintext, line: String
        }
        struct ProtocolSection: Decodable {
            struct Inputs: Decodable { let K, device_id, Np, Nc: String }
            let inputs: Inputs
            let hello_line, auth_line, K_cp, K_pc: String
            let frames_c2p, frames_p2c: [FrameVector]
            let v2: Version2
            let setup: Setup
        }
        /// §10: the same keys and frames; `HELLO 2` and `bri` on the measurements.
        struct Version2: Decodable {
            let hello_line: String
            let frames_c2p: [FrameVector]
        }
        struct Setup: Decodable {
            struct Net: Decodable { let rssi: Int; let auth, ssid_hex, line: String }
            struct Join: Decodable { let ssid_hex: String; let password_hex: String?; let line: String }
            let greeting: String
            let net: [Net]
            let join: [Join]
            let key_line: String
            let reject_join: [String]
        }
        struct Reject: Decodable {
            struct Frame: Decodable { let why, direction, line: String; let expect_ctr: UInt64 }
            let base64: [String]
            let measurement_plaintexts: [String]
            let measurement_plaintexts_v2: [String]
            let measurement_plaintexts_v1_with_bri: [String]
            let frames: [Frame]
            let line_too_long_bytes: Int
        }
        let hkdf_rfc5869: [HKDFCase]
        let aes256gcm_nist: GCMSet
        let `protocol`: ProtocolSection
        let reject: Reject
    }

    private static let vectors: Vectors = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("testdata/protocol.json")
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    private func hex(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            bytes.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return bytes
    }

    private func bytes(_ key: SymmetricKey) -> [UInt8] { key.withUnsafeBytes { Array($0) } }

    private var keys: SessionKeys {
        let input = Self.vectors.protocol.inputs
        return try! SessionKeys(
            key: hex(input.K), deviceID: input.device_id, panelNonce: hex(input.Np), companionNonce: hex(input.Nc))
    }

    // MARK: primitives against external known answers

    func testHKDFMatchesRFC5869() {
        XCTAssertEqual(Self.vectors.hkdf_rfc5869.count, 3)
        for test in Self.vectors.hkdf_rfc5869 {
            let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: hex(test.IKM)), salt: hex(test.salt))
            XCTAssertEqual(Array(prk), hex(test.PRK), "PRK, case \(test.case)")
            // The protocol uses Expand alone with K as the PRK (§4.2).
            let okm = HKDF<SHA256>.expand(pseudoRandomKey: hex(test.PRK), info: hex(test.info), outputByteCount: test.L)
            XCTAssertEqual(bytes(okm), hex(test.OKM), "OKM, case \(test.case)")
        }
    }

    func testAESGCMMatchesNIST() throws {
        XCTAssertEqual(Self.vectors.aes256gcm_nist.encrypt.count, 4)
        for test in Self.vectors.aes256gcm_nist.encrypt {
            let box = try AES.GCM.seal(
                hex(test.pt), using: SymmetricKey(data: hex(test.key)),
                nonce: AES.GCM.Nonce(data: hex(test.iv)), authenticating: hex(test.aad))
            XCTAssertEqual(Array(box.ciphertext), hex(test.ct), "CT, count \(test.count)")
            XCTAssertEqual(Array(box.tag), hex(test.tag), "tag, count \(test.count)")
        }
        for test in Self.vectors.aes256gcm_nist.decrypt_fail {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: hex(test.iv)), ciphertext: hex(test.ct), tag: hex(test.tag))
            XCTAssertThrowsError(
                try AES.GCM.open(box, using: SymmetricKey(data: hex(test.key)), authenticating: hex(test.aad)))
        }
    }

    // MARK: the protocol's own vectors

    func testSessionKeysMatchVectors() {
        XCTAssertEqual(bytes(keys.c2p), hex(Self.vectors.protocol.K_cp))
        XCTAssertEqual(bytes(keys.p2c), hex(Self.vectors.protocol.K_pc))
    }

    func testHelloAndAuthLines() {
        let input = Self.vectors.protocol.inputs
        let hello = Hello(version: 1, deviceID: input.device_id, panelNonce: hex(input.Np))
        XCTAssertEqual(hello.line, Self.vectors.protocol.hello_line)
        XCTAssertEqual(Hello.parse(Self.vectors.protocol.hello_line), hello)
        let hello2 = Hello(version: 2, deviceID: input.device_id, panelNonce: hex(input.Np))
        XCTAssertEqual(hello2.line, Self.vectors.protocol.v2.hello_line)
        XCTAssertEqual(Hello.parse(Self.vectors.protocol.v2.hello_line), hello2)
        let auth = Auth(companionNonce: hex(input.Nc))
        XCTAssertEqual(auth.line, Self.vectors.protocol.auth_line)
        XCTAssertEqual(Auth.parse(Self.vectors.protocol.auth_line), auth)
    }

    func testSealingReproducesFrames() throws {
        for frames in [Self.vectors.protocol.frames_c2p, Self.vectors.protocol.v2.frames_c2p] {
            var c2p = FrameSealer(key: keys.c2p)
            for frame in frames {
                XCTAssertEqual(c2p.counter, frame.ctr)
                XCTAssertEqual(try c2p.seal(frame.plaintext), frame.line)
            }
        }
        var p2c = FrameSealer(key: keys.p2c)
        for frame in Self.vectors.protocol.frames_p2c {
            XCTAssertEqual(try p2c.seal(frame.plaintext), frame.line)
        }
    }

    func testOpeningRecoversPlaintexts() throws {
        for frames in [Self.vectors.protocol.frames_c2p, Self.vectors.protocol.v2.frames_c2p] {
            var c2p = FrameOpener(key: keys.c2p)
            for frame in frames {
                XCTAssertEqual(try c2p.open(frame.line), frame.plaintext)
            }
        }
        var p2c = FrameOpener(key: keys.p2c)
        for frame in Self.vectors.protocol.frames_p2c {
            XCTAssertEqual(try p2c.open(frame.line), frame.plaintext)
        }
    }

    func testMessagesRoundTrip() throws {
        for frame in Self.vectors.protocol.frames_c2p {
            let parsed = try XCTUnwrap(Readings.parse(frame.plaintext, version: 1), frame.plaintext)
            XCTAssertNil(parsed.brightness)
            XCTAssertEqual(try parsed.encoded(version: 1), frame.plaintext)
            XCTAssertNil(Readings.parse(frame.plaintext, version: 2), "version 2 requires bri")
        }
        for frame in Self.vectors.protocol.v2.frames_c2p {
            let parsed = try XCTUnwrap(Readings.parse(frame.plaintext, version: 2), frame.plaintext)
            XCTAssertNotNil(parsed.brightness)
            XCTAssertEqual(try parsed.encoded(version: 2), frame.plaintext)
            XCTAssertNil(Readings.parse(frame.plaintext, version: 1), "version 1 refuses bri")
        }
        // The version 2 measurements are the version 1 ones with bri: dropping it gives them back.
        for (v1, v2) in zip(Self.vectors.protocol.frames_c2p, Self.vectors.protocol.v2.frames_c2p) {
            let parsed = try XCTUnwrap(Readings.parse(v2.plaintext, version: 2))
            XCTAssertEqual(try parsed.encoded(version: 1), v1.plaintext)
        }
        for frame in Self.vectors.protocol.frames_p2c {
            let parsed = try XCTUnwrap(Acknowledgement.parse(frame.plaintext), frame.plaintext)
            XCTAssertEqual(try parsed.encoded(), frame.plaintext)
        }
    }

    func testLongestValidPlaintexts() {
        let longest = Self.vectors.protocol.frames_c2p.map(\.plaintext).max { $0.utf8.count < $1.utf8.count }!
        XCTAssertEqual(longest.utf8.count, 524)
        XCTAssertNotNil(Readings.parse(longest, version: 1))
        let longest2 = Self.vectors.protocol.v2.frames_c2p.map(\.plaintext).max { $0.utf8.count < $1.utf8.count }!
        XCTAssertEqual(longest2.utf8.count, 530)
        XCTAssertNotNil(Readings.parse(longest2, version: 2))
    }

    func testSetupLinesMatchVectors() throws {
        let setup = Self.vectors.protocol.setup
        let input = Self.vectors.protocol.inputs
        XCTAssertEqual(SetupGreeting(deviceID: input.device_id).line, setup.greeting)
        for net in setup.net {
            let parsed = try XCTUnwrap(ScannedNetwork.parse(net.line), net.line)
            XCTAssertEqual(parsed, ScannedNetwork(rssi: net.rssi, security: .init(rawValue: net.auth)!, ssid: hex(net.ssid_hex)))
            XCTAssertEqual(parsed.line, net.line)
        }
        for join in setup.join {
            let request = JoinRequest(ssid: hex(join.ssid_hex), password: join.password_hex.map(hex))
            XCTAssertEqual(request.line, join.line)
            XCTAssertEqual(JoinRequest.parse(join.line), request)
        }
        XCTAssertEqual(KeyDelivery(key: hex(input.K)).line, setup.key_line)
        for line in setup.reject_join {
            XCTAssertNil(JoinRequest.parse(line), line)
        }
    }

    // MARK: what must be refused

    func testRejectsNonCanonicalBase64() {
        XCTAssertFalse(Self.vectors.reject.base64.isEmpty)
        for text in Self.vectors.reject.base64 {
            XCTAssertNil(StrictBase64.decode(text), "accepted \(text.debugDescription)")
        }
        XCTAssertEqual(StrictBase64.decode("AAE="), [0x00, 0x01])  // control: the canonical form passes
    }

    func testRejectsMalformedMeasurements() {
        XCTAssertEqual(Self.vectors.reject.measurement_plaintexts.count, 16)
        for text in Self.vectors.reject.measurement_plaintexts {
            XCTAssertNil(Readings.parse(text, version: 1), "accepted \(text)")
        }
        XCTAssertEqual(Self.vectors.reject.measurement_plaintexts_v2.count, 25)
        // The first 16 are the version 1 rejects with bri appended, so each still fails for its own reason.
        for (v1, v2) in zip(Self.vectors.reject.measurement_plaintexts, Self.vectors.reject.measurement_plaintexts_v2) {
            XCTAssertEqual(v2, v1 + " bri=3")
        }
        for text in Self.vectors.reject.measurement_plaintexts_v2 {
            XCTAssertNil(Readings.parse(text, version: 2), "accepted \(text)")
        }
        XCTAssertFalse(Self.vectors.reject.measurement_plaintexts_v1_with_bri.isEmpty)
        for text in Self.vectors.reject.measurement_plaintexts_v1_with_bri {
            XCTAssertNil(Readings.parse(text, version: 1), "accepted \(text)")
            XCTAssertNotNil(Readings.parse(text, version: 2), "control: \(text)")
        }
    }

    func testRejectsTamperedReplayedAndReflectedFrames() {
        for frame in Self.vectors.reject.frames {
            XCTAssertEqual(frame.direction, "c2p")
            var opener = FrameOpener(key: keys.c2p)
            XCTAssertEqual(opener.counter, frame.expect_ctr)
            XCTAssertThrowsError(try opener.open(frame.line), frame.why) { error in
                XCTAssertEqual(error as? ProtocolError, .verificationFailed, frame.why)
            }
        }
    }

    func testRejectsOverlongLine() {
        var buffer = LineBuffer()
        let limit = Self.vectors.reject.line_too_long_bytes
        XCTAssertThrowsError(try buffer.append(Array(repeating: UInt8(0x41), count: limit))) { error in
            XCTAssertEqual(error as? ProtocolError, .lineTooLong)
        }
        var fits = LineBuffer()
        XCTAssertEqual(try fits.append(Array(repeating: UInt8(0x41), count: limit - 1) + [0x0A]).first?.utf8.count,
                       limit - 1)
    }
}
