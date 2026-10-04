import XCTest
@testable import PanelCore

final class CoreUsageTests: XCTestCase {
    func testPerCorePercents() {
        let before = [CPUTicks(used: 0, total: 0), CPUTicks(used: 100, total: 200)]
        let after = [CPUTicks(used: 50, total: 100), CPUTicks(used: 100, total: 300)]
        XCTAssertEqual(CoreUsage.percents(from: before, to: after), [50, 0])
    }

    func testOverallIsOverAllCoresInTenths() {
        let before = [CPUTicks(used: 0, total: 0), CPUTicks(used: 0, total: 0)]
        let after = [CPUTicks(used: 30, total: 100), CPUTicks(used: 0, total: 100)]
        XCTAssertEqual(CoreUsage.overallTenths(from: before, to: after), 150)  // 30 of 200 = 15.0 %
    }

    func testChangedCoreCountGivesNothing() {
        let one = [CPUTicks(used: 0, total: 0)]
        let two = one + one
        XCTAssertNil(CoreUsage.percents(from: one, to: two))
        XCTAssertNil(CoreUsage.overallTenths(from: one, to: two))
        XCTAssertNil(CoreUsage.percents(from: [], to: []))
    }
}

final class MemoryTests: XCTestCase {
    private func snapshot(anonymous: UInt64 = 0, purgeable: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0,
                          page: UInt64 = 16_384, total: UInt64 = 1 << 35, swap: UInt64 = 0) -> MemorySnapshot {
        MemorySnapshot(internalPages: anonymous, purgeablePages: purgeable, wiredPages: wired,
                       compressedPages: compressed, pageSize: page, totalBytes: total, swapUsedBytes: swap)
    }

    func testBreakdown() {
        let breakdown = MemoryBreakdown(from: snapshot(anonymous: 110, purgeable: 10, wired: 20, compressed: 5, swap: 7))
        XCTAssertEqual(breakdown.app, 100 * 16_384)
        XCTAssertEqual(breakdown.wired, 20 * 16_384)
        XCTAssertEqual(breakdown.compressed, 5 * 16_384)
        XCTAssertEqual(breakdown.used, 125 * 16_384)
        XCTAssertEqual(breakdown.total, 1 << 35)
        XCTAssertEqual(breakdown.swapUsed, 7)
    }

    func testPurgeableAboveInternalDoesNotUnderflow() {
        XCTAssertEqual(MemoryBreakdown(from: snapshot(anonymous: 5, purgeable: 9)).app, 0)
    }

    func testOverflowSaturates() {
        let breakdown = MemoryBreakdown(from: snapshot(anonymous: .max, page: 2))
        XCTAssertEqual(breakdown.app, .max)
        XCTAssertEqual(breakdown.used, .max)
    }
}

final class NetworkMeterTests: XCTestCase {
    private let wired = [PathInterface(name: "en0", kind: .wiredEthernet), PathInterface(name: "en1", kind: .wifi)]

    private func counters(_ rx: UInt64, _ tx: UInt64, packets: UInt64) -> InterfaceCounters {
        InterfaceCounters(rxBytes: rx, txBytes: tx, rxPackets: packets, txPackets: packets)
    }

    func testFirstSampleIsABaselineThenARate() {
        var meter = NetworkMeter()
        let first = meter.sample(counters: ["en0": counters(0, 0, packets: 0)], pathOrder: wired, now: 10)
        XCTAssertEqual(first, .init(interface: "en0", rxBytesPerSecond: nil, txBytesPerSecond: nil))
        let second = meter.sample(counters: ["en0": counters(2048, 1024, packets: 4)], pathOrder: wired, now: 11)
        XCTAssertEqual(second, .init(interface: "en0", rxBytesPerSecond: 2048, txBytesPerSecond: 1024))
    }

    func testTunnelIsSkippedForThePhysicalLink() {
        var meter = NetworkMeter()
        let order = [PathInterface(name: "utun4", kind: .other)] + wired
        let reading = meter.sample(counters: ["utun4": counters(0, 0, packets: 0), "en0": counters(0, 0, packets: 0)],
                                   pathOrder: order, now: 0)
        XCTAssertEqual(reading.interface, "en0")
    }

    func testSwitchingInterfaceStartsOver() {
        var meter = NetworkMeter()
        _ = meter.sample(counters: ["en0": counters(0, 0, packets: 0), "en1": counters(0, 0, packets: 0)],
                         pathOrder: wired, now: 0)
        let wifiFirst = Array(wired.reversed())
        let reading = meter.sample(counters: ["en0": counters(9999, 0, packets: 9), "en1": counters(4096, 0, packets: 4)],
                                   pathOrder: wifiFirst, now: 1)
        XCTAssertEqual(reading, .init(interface: "en1", rxBytesPerSecond: nil, txBytesPerSecond: nil),
                       "en1 has no baseline yet; en0's baseline must not be used for it")
    }

    func testNoPhysicalInterface() {
        var meter = NetworkMeter()
        XCTAssertEqual(meter.sample(counters: ["lo0": counters(0, 0, packets: 0)],
                                    pathOrder: [PathInterface(name: "lo0", kind: .loopback)], now: 0),
                       .init(interface: nil, rxBytesPerSecond: nil, txBytesPerSecond: nil))
    }
}

final class ReadingsAssemblerTests: XCTestCase {
    private let memory = MemoryBreakdown(from: MemorySnapshot(
        internalPages: 1, purgeablePages: 0, wiredPages: 1, compressedPages: 1,
        pageSize: 16_384, totalBytes: 1 << 34, swapUsedBytes: 0))

    func testAssembledReadingsAlwaysEncode() throws {
        let readings = ReadingsAssembler.assemble(
            seq: .max, cpuTenths: 1003, cores: Array(repeating: 101, count: 80), gpu: 1.0004,
            memory: memory, pressure: .critical,
            network: .init(interface: "not a name", rxBytesPerSecond: .max, txBytesPerSecond: nil))
        let text = try readings.encoded(version: 1)
        XCTAssertEqual(Readings.parse(text, version: 1), readings)
        XCTAssertEqual(readings.cores.count, 64)
        XCTAssertEqual(readings.cpuTenths, 1000)
        XCTAssertEqual(readings.gpuTenths, 1000)
        XCTAssertNil(readings.interface)
        XCTAssertEqual(readings.rxBytesPerSecond, UInt64(Int64.max))
        XCTAssertEqual(readings.txBytesPerSecond, 0)
    }

    func testGPUAbsentStaysAbsent() throws {
        let readings = ReadingsAssembler.assemble(
            seq: 0, cpuTenths: 0, cores: [], gpu: nil, memory: memory, pressure: .normal,
            network: .init(interface: "en0", rxBytesPerSecond: 1, txBytesPerSecond: 2))
        XCTAssertNil(readings.gpuTenths)
        XCTAssertEqual(readings.cores, [0], "the protocol needs at least one core")
        XCTAssertTrue(try readings.encoded(version: 1).contains(" gpu=- "))
    }
}
