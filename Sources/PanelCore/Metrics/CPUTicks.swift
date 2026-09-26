// Copied from util-series/load-spinner 95f862e Sources/LoadSpinnerCore/Metrics.swift — keep in step with the original.
import Foundation

/// A snapshot of cumulative CPU tick counters.
///
/// `used` aggregates the busy states (user + system + nice) and `total`
/// additionally includes idle. Both are monotonically increasing counters, so a
/// usage ratio is derived from the delta between two snapshots.
public struct CPUTicks: Equatable, Sendable {
    public let used: UInt64
    public let total: UInt64

    public init(used: UInt64, total: UInt64) {
        self.used = used
        self.total = total
    }
}

/// Compute the CPU load (0...1) between two tick snapshots.
///
/// This is a pure function so it can be exhaustively unit-tested without
/// touching the kernel. Counter wrap-around or a non-advancing `total` yields 0
/// rather than a spurious value.
public func cpuUsage(from previous: CPUTicks, to current: CPUTicks) -> Double {
    let usedDelta = current.used >= previous.used ? current.used - previous.used : 0
    let totalDelta = current.total >= previous.total ? current.total - previous.total : 0
    guard totalDelta > 0 else { return 0 }
    let ratio = Double(usedDelta) / Double(totalDelta)
    return min(max(ratio, 0), 1)
}
