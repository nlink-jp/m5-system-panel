// Copied from util-series/load-spinner 95f862e Sources/LoadSpinnerCore/GPUSampler.swift
// (the pure part; the IOKit reader is in PanelSystem) — keep in step with the original.
import Foundation

/// The undocumented IOKit `PerformanceStatistics` keys that expose GPU
/// utilization. They differ across GPU drivers / macOS versions, so we try each
/// in turn and gracefully report nil when none is present.
public let gpuUtilizationKeys: [String] = [
    "Device Utilization %",
    "GPU Activity(%)",
    "Renderer Utilization %",
]

/// Extract a GPU utilization (0...1) from a `PerformanceStatistics` dictionary.
///
/// Pure and IOKit-free so it can be unit-tested with a hand-built dictionary.
/// Returns nil when no known key is present.
public func gpuUtilization(fromPerformanceStatistics stats: [String: Any]) -> Double? {
    for key in gpuUtilizationKeys {
        guard let raw = stats[key] else { continue }
        let percent: Double?
        switch raw {
        case let number as NSNumber: percent = number.doubleValue
        case let integer as Int: percent = Double(integer)
        case let double as Double: percent = double
        default: percent = nil
        }
        if let percent {
            return min(max(percent / 100.0, 0), 1)
        }
    }
    return nil
}
