import Foundation

/// Rates of the primary physical interface, one reading at a time.
///
/// The rules are net-meter's (`RateRule`, `resolveInterface` in automatic mode):
/// the first physical interface in the OS order, tunnels skipped; a sample that
/// is a baseline, too soon or discarded yields no rate. Not thread-safe; drive it
/// from one place.
public struct NetworkMeter: Sendable {
    public struct Reading: Equatable, Sendable {
        /// nil when there is no physical interface.
        public var interface: String?
        /// nil when this sample produced no trustworthy rate (baseline, discard).
        public var rxBytesPerSecond: UInt64?
        public var txBytesPerSecond: UInt64?
    }

    private var baseline: (name: String, counters: InterfaceCounters, time: Double)?

    public init() {}

    /// - Parameters:
    ///   - counters: every interface's counters (`CounterSource.read()`).
    ///   - pathOrder: the OS interface order.
    ///   - now: seconds on a clock that keeps running during sleep.
    public mutating func sample(
        counters: [String: InterfaceCounters], pathOrder: [PathInterface], now: Double
    ) -> Reading {
        guard case .present(let name) = resolveInterface(
            selection: .automatic, pathOrder: pathOrder, available: Set(counters.keys)),
            let current = counters[name]
        else {
            baseline = nil
            return Reading(interface: nil, rxBytesPerSecond: nil, txBytesPerSecond: nil)
        }
        // A different interface starts over: its counters are unrelated.
        let previous = baseline?.name == name ? baseline : nil
        let outcome = RateRule.evaluate(
            previous: previous?.counters, current: current, elapsed: now - (previous?.time ?? now))
        if outcome.movesBaseline { baseline = (name, current, now) }
        guard case .rate(let rate) = outcome else {
            return Reading(interface: name, rxBytesPerSecond: nil, txBytesPerSecond: nil)
        }
        return Reading(
            interface: name,
            rxBytesPerSecond: UInt64(rate.downBytesPerSecond.rounded()),
            txBytesPerSecond: UInt64(rate.upBytesPerSecond.rounded()))
    }
}
