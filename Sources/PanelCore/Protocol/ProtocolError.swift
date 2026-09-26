import Foundation

/// Why a line, frame or message was refused (protocol v1 §3, §4, §6).
///
/// Every case means the same thing on the wire: close the connection without
/// replying. The cases exist for tests and for the companion's own log, never to
/// tell the peer what was wrong.
public enum ProtocolError: Error, Equatable, Sendable {
    /// A line over 1024 bytes, a byte outside printable ASCII, or a CR.
    case lineTooLong
    case notASCII
    /// A line or plaintext that does not match the defined form.
    case malformed
    /// A frame that does not decrypt under the expected key and counter.
    case verificationFailed
    /// The direction's counter reached 2^32; the session must end.
    case counterExhausted
    /// A plaintext over 700 bytes (the sender's check).
    case plaintextTooLong
}
