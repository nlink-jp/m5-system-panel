import Foundation

/// Puts one second's samples into a `Readings` message that always encodes.
///
/// Values are clamped into the protocol's ranges here, once, so a measurement
/// quirk (a ratio a hair over 1, a machine with more than 64 logical CPUs) can
/// never make the sender refuse its own frame.
public enum ReadingsAssembler {
    public static func assemble(
        seq: UInt64, cpuTenths: Int, cores: [Int], gpu: Double?,
        memory: MemoryBreakdown, pressure: MemoryPressure, network: NetworkMeter.Reading
    ) -> Readings {
        let clampInteger = { (value: UInt64) in min(value, Wire.maxInteger) }
        let interface = network.interface.flatMap { Wire.isInterfaceName($0) ? $0 : nil }
        return Readings(
            seq: clampInteger(seq),
            cpuTenths: min(max(cpuTenths, 0), 1000),
            cores: cores.isEmpty ? [0] : cores.prefix(Readings.maxCores).map { min(max($0, 0), 100) },
            gpuTenths: gpu.map { min(max(Int(($0 * 1000).rounded()), 0), 1000) },
            memoryUsed: clampInteger(memory.used),
            memoryTotal: clampInteger(memory.total),
            memoryApp: clampInteger(memory.app),
            memoryWired: clampInteger(memory.wired),
            memoryCompressed: clampInteger(memory.compressed),
            swapUsed: clampInteger(memory.swapUsed),
            pressure: pressure.rawValue,
            interface: interface,
            rxBytesPerSecond: clampInteger(network.rxBytesPerSecond ?? 0),
            txBytesPerSecond: clampInteger(network.txBytesPerSecond ?? 0))
    }
}
