import Foundation

/// Splits a TCP byte stream into protocol lines (protocol v1 §3).
///
/// Lines end with LF; CR is not used. A line may hold only printable ASCII
/// (0x20–0x7E) and at most `maxLineBytes` bytes. The first violation throws, and
/// the caller closes the connection — the buffer is not meant to be used again.
public struct LineBuffer: Sendable {
    public static let maxLineBytes = 1024

    private var pending: [UInt8] = []

    public init() {}

    /// Appends bytes and returns every complete line they finish, in order.
    public mutating func append(_ bytes: some Sequence<UInt8>) throws(ProtocolError) -> [String] {
        var lines: [String] = []
        for byte in bytes {
            if byte == 0x0A {
                lines.append(String(decoding: pending, as: UTF8.self))
                pending.removeAll(keepingCapacity: true)
                continue
            }
            guard byte >= 0x20, byte <= 0x7E else { throw .notASCII }
            guard pending.count < Self.maxLineBytes else { throw .lineTooLong }
            pending.append(byte)
        }
        return lines
    }
}
