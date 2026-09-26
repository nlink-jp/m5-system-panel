import Foundation

/// Per-core and overall CPU usage between two snapshots of per-core ticks.
///
/// Snapshots are in logical CPU order, as `host_processor_info` returns them. No
/// P/E type is attached: which logical CPU is which kind is not documented (RFP
/// amendment A4).
public enum CoreUsage {
    /// Each core's usage in whole percent (0...100), or nil when the core count
    /// changed between the snapshots.
    public static func percents(from previous: [CPUTicks], to current: [CPUTicks]) -> [Int]? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        return zip(previous, current).map { Int((cpuUsage(from: $0, to: $1) * 100).rounded()) }
    }

    /// Overall usage in tenths of a percent (0...1000) over all cores, or nil when
    /// the core count changed.
    public static func overallTenths(from previous: [CPUTicks], to current: [CPUTicks]) -> Int? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        let sum = { (ticks: [CPUTicks]) in
            CPUTicks(used: ticks.reduce(0) { $0 &+ $1.used }, total: ticks.reduce(0) { $0 &+ $1.total })
        }
        return Int((cpuUsage(from: sum(previous), to: sum(current)) * 1000).rounded())
    }
}
