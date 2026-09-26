// Copied from util-series/net-meter bcdefee Sources/NetMeterCore/RateRule.swift — keep in step with the original.
/// Turns two counter readings into a rate, or into the reason there is none.
/// The rules, their order and every constant are decided in net-meter's ADR-0001.
public enum RateRule {
    /// Below this, a timer that fired twice after a stall would divide by a tiny interval.
    public static let minimumInterval = 0.5
    /// Above this the delta modulo 2^32 stops being unambiguous, and a sleep looks like this.
    public static let maximumInterval = 3.0
    /// Over four times the 10GbE ceiling at minimum frame size.
    public static let maximumPacketsPerSecond = Double(1 << 26)
    /// Twice the largest IP packet; the largest measured under TSO was 31,477.
    public static let maximumBytesPerPacket: UInt64 = 131_072
    /// The byte and packet counters are not updated together.
    public static let packetSlack: UInt64 = 16
    /// The byte counters are floored to 1 KiB.
    public static let byteSlack: UInt64 = 1_024

    /// Forward distance from `old` to `new`, modulo 2^32. Correct whether the OS
    /// truncated the counter to 32 bits or not, while one sample's increase stays
    /// below 2^32.
    public static func delta32(_ new: UInt64, _ old: UInt64) -> UInt64 {
        (new &- old) & 0xFFFF_FFFF
    }

    /// - Parameters:
    ///   - previous: the baseline, or nil when there is none for this interface.
    ///   - current: this reading.
    ///   - elapsed: seconds between them, on a clock that keeps running during sleep.
    public static func evaluate(
        previous: InterfaceCounters?,
        current: InterfaceCounters,
        elapsed: Double
    ) -> SampleOutcome {
        guard let previous else { return .baseline }
        guard elapsed >= minimumInterval else { return .tooSoon }
        guard elapsed <= maximumInterval else { return .discarded(.intervalTooLong) }

        let rxBytes = delta32(current.rxBytes, previous.rxBytes)
        let txBytes = delta32(current.txBytes, previous.txBytes)
        let rxPackets = delta32(current.rxPackets, previous.rxPackets)
        let txPackets = delta32(current.txPackets, previous.txPackets)

        // A counter that went backwards is, modulo 2^32, a huge step forwards.
        let packetCeiling = maximumPacketsPerSecond * elapsed
        if Double(rxPackets) > packetCeiling || Double(txPackets) > packetCeiling {
            return .discarded(.reset)
        }
        // Bytes cannot arrive without packets to carry them.
        if rxBytes > byteCeiling(forPackets: rxPackets) || txBytes > byteCeiling(forPackets: txPackets) {
            return .discarded(.reset)
        }

        return .rate(Rate(
            downBytesPerSecond: Double(rxBytes) / elapsed,
            upBytesPerSecond: Double(txBytes) / elapsed,
            downBytes: rxBytes,
            upBytes: txBytes
        ))
    }

    static func byteCeiling(forPackets packets: UInt64) -> UInt64 {
        (packets + packetSlack) * maximumBytesPerPacket + byteSlack
    }
}

/// What one reading of one interface amounts to.
public enum SampleOutcome: Equatable, Sendable {
    /// First reading of this interface: remembered, nothing to show yet.
    case baseline
    /// Too close to the previous reading; the baseline stays where it was.
    case tooSoon
    /// Not trustworthy; this reading becomes the new baseline.
    case discarded(DiscardReason)
    case rate(Rate)

    /// Whether this reading replaces the baseline.
    public var movesBaseline: Bool {
        if case .tooSoon = self { return false }
        return true
    }
}

public enum DiscardReason: Equatable, Sendable {
    /// A sleep, or a stalled timer.
    case intervalTooLong
    /// The counters restarted.
    case reset
}

public struct Rate: Equatable, Sendable {
    public var downBytesPerSecond: Double
    public var upBytesPerSecond: Double
    /// The deltas themselves, for the cumulative totals.
    public var downBytes: UInt64
    public var upBytes: UInt64

    public init(downBytesPerSecond: Double, upBytesPerSecond: Double, downBytes: UInt64, upBytes: UInt64) {
        self.downBytesPerSecond = downBytesPerSecond
        self.upBytesPerSecond = upBytesPerSecond
        self.downBytes = downBytes
        self.upBytes = upBytes
    }
}
