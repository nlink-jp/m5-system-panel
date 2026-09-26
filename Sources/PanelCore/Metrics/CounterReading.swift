// Copied from util-series/net-meter bcdefee Sources/NetMeterCore/CounterReading.swift — keep in step with the original.
/// One interface's cumulative counters, as an unprivileged process is handed them.
///
/// The byte counters are 64 bits wide but hold the true value modulo 2^32, floored
/// to 1 KiB (measured on macOS 26 and 27). The packet counters arrive unaltered.
/// `linkSpeed` is what the interface reports, in bits per second; it can be 0, and
/// it is not a ceiling — it is shown to the user and never used to judge a sample.
public struct InterfaceCounters: Equatable, Sendable {
    public var rxBytes: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var txPackets: UInt64
    public var linkSpeed: UInt64

    public init(rxBytes: UInt64, txBytes: UInt64, rxPackets: UInt64, txPackets: UInt64, linkSpeed: UInt64 = 0) {
        self.rxBytes = rxBytes
        self.txBytes = txBytes
        self.rxPackets = rxPackets
        self.txPackets = txPackets
        self.linkSpeed = linkSpeed
    }
}

/// Where the counters come from. The real source reads `sysctl`; tests supply
/// sequences taken from measurements.
public protocol CounterSource: Sendable {
    /// Every interface's counters, keyed by BSD name. Empty when the read failed.
    func read() -> [String: InterfaceCounters]
}
