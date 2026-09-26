import CryptoKit
import Foundation

/// Per-session, per-direction keys (protocol v1 §4.2).
///
/// K is 32 uniform random bytes, so it is used directly as the HKDF PRK and only
/// Expand runs (RFC 5869 §3.3). The device ID and both sides' random values go
/// into `info`; nothing the peer chooses is used as a salt.
public struct SessionKeys: Sendable {
    /// Companion → panel.
    public let c2p: SymmetricKey
    /// Panel → companion.
    public let p2c: SymmetricKey

    public static let keyBytes = 32
    public static let nonceBytes = 16

    public init(key: [UInt8], deviceID: String, panelNonce np: [UInt8], companionNonce nc: [UInt8])
        throws(ProtocolError)
    {
        guard key.count == Self.keyBytes, np.count == Self.nonceBytes, nc.count == Self.nonceBytes,
              DeviceID.isValid(deviceID) else { throw .malformed }
        let context = Array(deviceID.utf8) + np + nc
        c2p = HKDF<SHA256>.expand(
            pseudoRandomKey: key, info: Array("m5-system-panel/1 c2p".utf8) + context,
            outputByteCount: Self.keyBytes)
        p2c = HKDF<SHA256>.expand(
            pseudoRandomKey: key, info: Array("m5-system-panel/1 p2c".utf8) + context,
            outputByteCount: Self.keyBytes)
    }
}

/// The device ID: 4 upper-case hex ASCII characters (protocol v1 §1).
public enum DeviceID {
    public static func isValid(_ id: some StringProtocol) -> Bool {
        id.utf8.count == 4 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) }
    }
}
