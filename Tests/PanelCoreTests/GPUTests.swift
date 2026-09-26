// Copied from util-series/load-spinner 95f862e Tests/LoadSpinnerCoreTests/GPUTests.swift — keep in step with the original.
import XCTest
@testable import PanelCore

final class GPUTests: XCTestCase {
    func testReadsPrimaryKey() throws {
        let stats: [String: Any] = ["Device Utilization %": 42]
        let utilization = try XCTUnwrap(gpuUtilization(fromPerformanceStatistics: stats))
        XCTAssertEqual(utilization, 0.42, accuracy: 1e-9)
    }

    func testReadsNSNumberValue() throws {
        let stats: [String: Any] = ["Device Utilization %": NSNumber(value: 75)]
        let utilization = try XCTUnwrap(gpuUtilization(fromPerformanceStatistics: stats))
        XCTAssertEqual(utilization, 0.75, accuracy: 1e-9)
    }

    func testFallsBackToAlternateKey() throws {
        let stats: [String: Any] = ["GPU Activity(%)": 30]
        let utilization = try XCTUnwrap(gpuUtilization(fromPerformanceStatistics: stats))
        XCTAssertEqual(utilization, 0.30, accuracy: 1e-9)
    }

    func testMissingKeyReturnsNil() {
        let stats: [String: Any] = ["Something Else": 50]
        XCTAssertNil(gpuUtilization(fromPerformanceStatistics: stats))
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(gpuUtilization(fromPerformanceStatistics: [:]))
    }

    func testValueIsClampedToUnitInterval() {
        let stats: [String: Any] = ["Device Utilization %": 250]
        XCTAssertEqual(gpuUtilization(fromPerformanceStatistics: stats), 1.0)
    }
}
