// Copied from util-series/load-spinner 95f862e Sources/LoadSpinnerCore/GPUSampler.swift
// (the IOKit reader; the pure part is PanelCore/Metrics/GPU.swift) — keep in step with the original.
import Foundation
import IOKit
import PanelCore

/// Something that can read the current GPU utilization (0...1), or nil when the
/// metric is unavailable on this system.
public protocol GPUSampling {
    func sample() -> Double?
}

/// Reads GPU utilization from the IOKit registry (`IOAccelerator` services'
/// `PerformanceStatistics`). No entitlement or root required.
public struct IOKitGPUSampler: GPUSampling {
    public init() {}

    public func sample() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = properties?.takeRetainedValue() as? [String: Any],
               let performance = dictionary["PerformanceStatistics"] as? [String: Any],
               let utilization = gpuUtilization(fromPerformanceStatistics: performance) {
                best = max(best ?? 0, utilization)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return best
    }
}
