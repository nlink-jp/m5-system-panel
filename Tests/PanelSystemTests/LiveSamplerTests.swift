import Darwin
import Foundation
import PanelCore
import PanelSystem
import XCTest

/// Live tests: they read this Mac's real counters. No permission, no network
/// traffic and no particular interface beyond loopback are needed.
final class LiveSamplerTests: XCTestCase {
    private func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
    }

    func testRunsUnprivileged() {
        XCTAssertNotEqual(getuid(), 0, "run the tests unprivileged; that is what the app is")
    }

    func testOneTickSnapshotPerLogicalCPU() throws {
        let ticks = try XCTUnwrap(MachCPUSampler().sample())
        XCTAssertEqual(ticks.count, try XCTUnwrap(sysctlInt("hw.logicalcpu")))
        XCTAssertTrue(ticks.allSatisfy { $0.used <= $0.total })
    }

    func testCPUTicksAdvanceAndGiveUsageInRange() throws {
        let sampler = MachCPUSampler()
        let first = try XCTUnwrap(sampler.sample())
        Thread.sleep(forTimeInterval: 0.3)
        let second = try XCTUnwrap(sampler.sample())
        let percents = try XCTUnwrap(CoreUsage.percents(from: first, to: second))
        XCTAssertTrue(percents.allSatisfy { (0...100).contains($0) })
        XCTAssertTrue(zip(first, second).contains { $1.total > $0.total }, "no core's ticks moved in 0.3 s")
    }

    func testMemorySnapshotIsCoherent() throws {
        let snapshot = try XCTUnwrap(MachMemorySampler().sample())
        XCTAssertEqual(snapshot.totalBytes, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(snapshot.pageSize, 0)
        let breakdown = MemoryBreakdown(from: snapshot)
        XCTAssertGreaterThan(breakdown.used, 0)
        XCTAssertLessThanOrEqual(breakdown.used, breakdown.total, "used above installed on a live Mac")
    }

    func testCountersIncludeLoopback() {
        XCTAssertNotNil(SysctlCounterSource().read()["lo0"])
    }

    func testCollectorProducesEncodableReadings() throws {
        let gpu = IOKitGPUSampler()
        let collector = MetricsCollector(gpu: gpu.sample() == nil ? nil : gpu)
        _ = collector.collect(seq: 0, now: 0)
        Thread.sleep(forTimeInterval: 1.0)
        let readings = collector.collect(seq: 1, now: 1.0)
        let text = try readings.encoded(version: 1)
        XCTAssertEqual(Readings.parse(text, version: 1), readings)
        XCTAssertEqual(readings.cores.count, try XCTUnwrap(sysctlInt("hw.logicalcpu")))
        XCTAssertEqual(readings.memoryTotal, ProcessInfo.processInfo.physicalMemory)
    }
}
