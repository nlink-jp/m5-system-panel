// Copied from util-series/load-spinner 95f862e Tests/LoadSpinnerCoreTests/MetricsTests.swift — keep in step with the original.
import XCTest
@testable import PanelCore

final class MetricsTests: XCTestCase {
    func testUsageIsBusyFractionOfDelta() {
        let previous = CPUTicks(used: 100, total: 200)
        let current = CPUTicks(used: 150, total: 300)
        // used delta = 50, total delta = 100 -> 0.5
        XCTAssertEqual(cpuUsage(from: previous, to: current), 0.5, accuracy: 1e-9)
    }

    func testFullyBusy() {
        let previous = CPUTicks(used: 100, total: 200)
        let current = CPUTicks(used: 200, total: 300)
        XCTAssertEqual(cpuUsage(from: previous, to: current), 1.0, accuracy: 1e-9)
    }

    func testFullyIdle() {
        let previous = CPUTicks(used: 100, total: 200)
        let current = CPUTicks(used: 100, total: 300)
        XCTAssertEqual(cpuUsage(from: previous, to: current), 0.0, accuracy: 1e-9)
    }

    func testNoTotalDeltaReturnsZero() {
        let ticks = CPUTicks(used: 100, total: 200)
        XCTAssertEqual(cpuUsage(from: ticks, to: ticks), 0.0)
    }

    func testCounterRegressionReturnsZeroNotNegative() {
        let previous = CPUTicks(used: 500, total: 900)
        let current = CPUTicks(used: 100, total: 200)
        XCTAssertEqual(cpuUsage(from: previous, to: current), 0.0)
    }

    func testResultIsClampedToUnitInterval() {
        let previous = CPUTicks(used: 0, total: 0)
        let current = CPUTicks(used: 300, total: 100)
        let usage = cpuUsage(from: previous, to: current)
        XCTAssertGreaterThanOrEqual(usage, 0)
        XCTAssertLessThanOrEqual(usage, 1)
    }
}
