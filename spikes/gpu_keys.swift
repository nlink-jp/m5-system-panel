// Phase 0 item 6: which PerformanceStatistics keys this Mac's IOAccelerator
// services expose, and whether "Device Utilization %" moves. Read-only.
// Run: swift spikes/gpu_keys.swift [seconds]
import Foundation
import IOKit

func snapshot() -> [(String, [String: Any])] {
    var out: [(String, [String: Any])] = []
    guard let matching = IOServiceMatching("IOAccelerator") else { return out }
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return out }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        var name = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(service, &name)
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = props?.takeRetainedValue() as? [String: Any],
           let perf = dict["PerformanceStatistics"] as? [String: Any] {
            out.append((String(cString: name), perf))
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return out
}

let seconds = Int(CommandLine.arguments.dropFirst().first ?? "5") ?? 5
let first = snapshot()
print("IOAccelerator services with PerformanceStatistics: \(first.count)")
for (name, perf) in first {
    print("service \(name): keys =", perf.keys.sorted().joined(separator: " | "))
}
for i in 0..<seconds {
    let values = snapshot().map { ($0.0, $0.1["Device Utilization %"] ?? "absent") }
    print("t=\(i)s", values.map { "\($0.0)=\($0.1)" }.joined(separator: " "))
    Thread.sleep(forTimeInterval: 1)
}
