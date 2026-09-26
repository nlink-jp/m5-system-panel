import CryptoKit
import Foundation

/// The AES-256-GCM frame of protocol v1 §4.3.
///
/// `nonce = 0x00000000 ‖ uint64_be(ctr)`; the counter is not carried on the line,
/// each side counts. One sealer and one opener exist per direction per session,
/// and neither can be rewound, so a (key, nonce) pair is never reused.
public enum Frame {
    public static let aad = Array("m5-system-panel/1".utf8)
    public static let tagBytes = 16
    public static let maxPlaintextBytes = 700
    /// The last counter value a frame may carry is `counterLimit - 1`.
    public static let counterLimit: UInt64 = 1 << 32

    static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift)))
        }
        // 12 bytes is always a valid GCM nonce.
        return try! AES.GCM.Nonce(data: bytes)
    }

    /// Plaintexts are printable ASCII: the lines they carry are defined that way.
    static func isPrintableASCII(_ bytes: some Collection<UInt8>) -> Bool {
        bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
    }
}

/// Seals plaintexts into `F …` lines for one direction.
public struct FrameSealer: Sendable {
    private let key: SymmetricKey
    public private(set) var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    public mutating func seal(_ plaintext: String) throws(ProtocolError) -> String {
        let bytes = Array(plaintext.utf8)
        guard bytes.count <= Frame.maxPlaintextBytes else { throw .plaintextTooLong }
        guard Frame.isPrintableASCII(bytes) else { throw .notASCII }
        guard counter < Frame.counterLimit else { throw .counterExhausted }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(bytes, using: key, nonce: Frame.nonce(counter), authenticating: Frame.aad)
        } catch {
            throw .verificationFailed  // not reachable with a 32-byte key and a 12-byte nonce
        }
        counter += 1
        return "F " + StrictBase64.encode(box.ciphertext + box.tag)
    }
}

/// Opens `F …` lines for one direction, in order.
public struct FrameOpener: Sendable {
    private let key: SymmetricKey
    public private(set) var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    /// The plaintext of the next frame. Any failure means: close the connection.
    public mutating func open(_ line: String) throws(ProtocolError) -> String {
        guard counter < Frame.counterLimit else { throw .counterExhausted }
        guard line.hasPrefix("F "), let bytes = StrictBase64.decode(line.dropFirst(2)),
              bytes.count >= Frame.tagBytes else { throw .malformed }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(
                nonce: Frame.nonce(counter),
                ciphertext: bytes.dropLast(Frame.tagBytes),
                tag: bytes.suffix(Frame.tagBytes))
            plaintext = try AES.GCM.open(box, using: key, authenticating: Frame.aad)
        } catch {
            throw .verificationFailed
        }
        counter += 1
        guard plaintext.count <= Frame.maxPlaintextBytes, Frame.isPrintableASCII(plaintext) else {
            throw .malformed
        }
        return String(decoding: plaintext, as: UTF8.self)
    }
}
