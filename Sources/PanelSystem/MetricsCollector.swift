import Foundation
import PanelCore

/// Gathers one `Readings` per call from the OS sources.
///
/// Holds the previous CPU snapshot and the network baseline, so the first call
/// reports zero CPU and no network rate. Drive it from one place (the app's
/// one-second timer).
public final class MetricsCollector {
    private let cpu: MachCPUSampler
    private let gpu: GPUSampling?
    private let memory: MachMemorySampler
    private let pressure: MemoryPressureMonitor
    private let counters: CounterSource
    private let paths: PathOrderMonitor
    private var previousCPU: [CPUTicks]?
    private var network = NetworkMeter()

    /// - Parameter gpu: nil when GPU utilization is unavailable on this Mac
    ///   (probe once at launch; `IOKitGPUSampler().sample() == nil`).
    public init(gpu: GPUSampling?) {
        cpu = MachCPUSampler()
        self.gpu = gpu
        memory = MachMemorySampler()
        pressure = MemoryPressureMonitor()
        counters = SysctlCounterSource()
        paths = PathOrderMonitor()
        pressure.start()
        paths.start { _ in }
    }

    deinit {
        pressure.cancel()
        paths.cancel()
    }

    /// - Parameters:
    ///   - seq: the session's readings number.
    ///   - now: seconds on a clock that keeps running during sleep.
    public func collect(seq: UInt64, now: Double) -> Readings {
        let ticks = cpu.sample()
        var cores: [Int] = []
        var overall = 0
        if let ticks {
            if let previous = previousCPU {
                cores = CoreUsage.percents(from: previous, to: ticks) ?? []
                overall = CoreUsage.overallTenths(from: previous, to: ticks) ?? 0
            } else {
                cores = Array(repeating: 0, count: ticks.count)
            }
            previousCPU = ticks
        }
        let snapshot = memory.sample() ?? MemorySnapshot(
            internalPages: 0, purgeablePages: 0, wiredPages: 0, compressedPages: 0,
            pageSize: 0, totalBytes: 0, swapUsedBytes: 0)
        let networkReading = network.sample(counters: counters.read(), pathOrder: paths.current, now: now)
        return ReadingsAssembler.assemble(
            seq: seq, cpuTenths: overall, cores: cores, gpu: gpu?.sample(),
            memory: MemoryBreakdown(from: snapshot), pressure: pressure.current, network: networkReading)
    }
}
