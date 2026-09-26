import Darwin
import Foundation
import PanelCore

/// Per-core CPU ticks from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`, in
/// logical CPU order. Public Mach API; no entitlement, no root.
public struct MachCPUSampler: Sendable {
    public init() {}

    public func sample() -> [CPUTicks]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(bitPattern: info),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(processorCount) * states else { return nil }
        // The tick counters are 32-bit and wrap; cpuUsage treats a backwards step as 0.
        let tick = { (index: Int) in UInt64(UInt32(bitPattern: info[index])) }
        return (0..<Int(processorCount)).map { core in
            let base = core * states
            let used = tick(base + Int(CPU_STATE_USER)) + tick(base + Int(CPU_STATE_SYSTEM))
                + tick(base + Int(CPU_STATE_NICE))
            return CPUTicks(used: used, total: used + tick(base + Int(CPU_STATE_IDLE)))
        }
    }
}

/// Memory counters from `host_statistics64(HOST_VM_INFO64)`, `hw.memsize`
/// (`ProcessInfo.physicalMemory`) and `vm.swapusage`. Public interfaces only.
public struct MachMemorySampler: Sendable {
    public init() {}

    public func sample() -> MemorySnapshot? {
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var vm = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemorySnapshot(
            internalPages: UInt64(vm.internal_page_count),
            purgeablePages: UInt64(vm.purgeable_count),
            wiredPages: UInt64(vm.wire_count),
            compressedPages: UInt64(vm.compressor_page_count),
            pageSize: UInt64(pageSize),
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            swapUsedBytes: Self.swapUsed() ?? 0)
    }

    static func swapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }
}

/// The latest memory pressure, from `DispatchSource.makeMemoryPressureSource`.
///
/// The source reports changes; before the first event the level is taken to be
/// normal (inferred — the documentation does not say an event is delivered for
/// the state at registration).
public final class MemoryPressureMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jp.nlink.m5-system-panel.pressure")
    private let lock = NSLock()
    private var level: MemoryPressure = .normal
    private var source: DispatchSourceMemoryPressure?

    public init() {}

    public var current: MemoryPressure {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    public func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let event = source?.data else { return }
            let next: MemoryPressure = event.contains(.critical) ? .critical
                : event.contains(.warning) ? .warning : .normal
            self.lock.lock()
            self.level = next
            self.lock.unlock()
        }
        source.activate()
        self.source = source
    }

    public func cancel() {
        source?.cancel()
    }
}
