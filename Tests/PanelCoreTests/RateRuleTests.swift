// Copied from util-series/net-meter bcdefee Tests/NetMeterCoreTests/RateRuleTests.swift — keep in step with the original.
import XCTest
@testable import PanelCore

/// The rules of net-meter's ADR-0001. Readings marked "measured" are copied from the log
/// recorded on 2026-09-20 (macOS 27.0); the rest are constructed.
final class RateRuleTests: XCTestCase {
    private func counters(_ rx: UInt64, _ tx: UInt64, _ ip: UInt64, _ op: UInt64, _ baud: UInt64 = 0) -> InterfaceCounters {
        InterfaceCounters(rxBytes: rx, txBytes: tx, rxPackets: ip, txPackets: op, linkSpeed: baud)
    }

    // MARK: rule 1–3: baseline and the interval

    func testFirstReadingIsABaseline() {
        XCTAssertEqual(RateRule.evaluate(previous: nil, current: counters(1, 2, 3, 4), elapsed: 1), .baseline)
    }

    func testTooSoonKeepsTheBaseline() {
        let outcome = RateRule.evaluate(previous: counters(0, 0, 0, 0), current: counters(1024, 0, 1, 0), elapsed: 0.49)
        XCTAssertEqual(outcome, .tooSoon)
        XCTAssertFalse(outcome.movesBaseline)
    }

    func testIntervalBoundsAreInclusive() {
        let p = counters(0, 0, 0, 0), c = counters(2048, 0, 2, 0)
        XCTAssertNotEqual(RateRule.evaluate(previous: p, current: c, elapsed: 0.5), .tooSoon)
        XCTAssertNotEqual(RateRule.evaluate(previous: p, current: c, elapsed: 3.0), .discarded(.intervalTooLong))
    }

    func testLongIntervalIsDiscardedWithoutLookingAtTheValues() {
        // A sleep: perfectly plausible values, but the delta modulo 2^32 is no longer unambiguous.
        let outcome = RateRule.evaluate(previous: counters(0, 0, 0, 0), current: counters(4096, 4096, 4, 4), elapsed: 3.01)
        XCTAssertEqual(outcome, .discarded(.intervalTooLong))
        XCTAssertTrue(outcome.movesBaseline)
    }

    // MARK: rule 4 and 7: deltas modulo 2^32

    func testMeasuredSamplesUnderLoad() {
        // Measured: a virtual NIC reporting 100 Mbps while carrying about 2.3 Gbps.
        // A link-speed cap would have thrown this sample away.
        let p = counters(23_274_496, 2_525_460_480, 232_093, 1_132_985, 100_000_000)
        let c = counters(23_880_704, 2_813_686_784, 238_968, 1_152_535, 100_000_000)
        guard case .rate(let rate) = RateRule.evaluate(previous: p, current: c, elapsed: 1.008) else {
            return XCTFail("expected a rate")
        }
        XCTAssertEqual(rate.upBytes, 288_226_304)
        XCTAssertEqual(rate.downBytes, 606_208)
        XCTAssertEqual(rate.upBytesPerSecond, 288_226_304 / 1.008, accuracy: 0.5)
        XCTAssertGreaterThan(rate.upBytesPerSecond * 8, 100_000_000 * 20)  // 20x the reported link speed
    }

    func testMeasuredSampleWithLargeSegments() {
        // Measured: TSO makes one counted packet far larger than the MTU (31,477 bytes each here).
        let p = counters(2_589_643_776, 1_000_406_016, 306_835_713, 152_849_592, 2_500_000_000)
        let c = counters(2_589_657_088, 1_004_623_872, 306_835_876, 152_849_726, 2_500_000_000)
        guard case .rate(let rate) = RateRule.evaluate(previous: p, current: c, elapsed: 1.010) else {
            return XCTFail("expected a rate")
        }
        XCTAssertEqual(rate.upBytes, 4_217_856)
        XCTAssertEqual(rate.upBytes / 134, 31_476)  // 134 packets carried it
    }

    func testWrapIsAnOrdinarySample() {
        // The byte counter holds the true value modulo 2^32, floored to 1 KiB,
        // so it wraps every 4 GiB. Here it crosses the boundary by 50 KiB + 30 KiB.
        let top: UInt64 = 1 << 32
        let p = counters(top - 51_200, 0, 1_000, 0)
        let c = counters(30_720, 0, 1_060, 0)
        guard case .rate(let rate) = RateRule.evaluate(previous: p, current: c, elapsed: 1) else {
            return XCTFail("a wrap must not be discarded")
        }
        XCTAssertEqual(rate.downBytes, 81_920)
    }

    func testUntruncatedCountersGiveTheSameDelta() {
        // Should an OS hand over the full 64-bit value, the rule still holds.
        let p = counters(5_438_231_389, 0, 1_037_593, 0)
        let c = counters(5_438_331_389, 0, 1_037_693, 0)
        guard case .rate(let rate) = RateRule.evaluate(previous: p, current: c, elapsed: 1) else {
            return XCTFail("expected a rate")
        }
        XCTAssertEqual(rate.downBytes, 100_000)
    }

    func testIdleInterfaceIsARateOfZeroNotADiscard() {
        let p = counters(427_042_816, 2_269_488_128, 2_221_738, 1_837_050)  // measured, idle Wi-Fi
        XCTAssertEqual(
            RateRule.evaluate(previous: p, current: p, elapsed: 1),
            .rate(Rate(downBytesPerSecond: 0, upBytesPerSecond: 0, downBytes: 0, upBytes: 0))
        )
    }

    // MARK: rule 5: packets went backwards

    func testCountersRestartingFromZeroAreAReset() {
        let p = counters(2_589_657_088, 1_004_623_872, 306_835_876, 152_849_726)  // measured
        let c = counters(4_096, 2_048, 12, 9)
        XCTAssertEqual(RateRule.evaluate(previous: p, current: c, elapsed: 1), .discarded(.reset))
    }

    func testOneDirectionGoingBackwardsIsEnough() {
        let p = counters(10_240, 10_240, 500, 500)
        let c = counters(20_480, 20_480, 510, 3)
        XCTAssertEqual(RateRule.evaluate(previous: p, current: c, elapsed: 1), .discarded(.reset))
    }

    func testPacketCeilingScalesWithTheInterval() {
        let perSecond = UInt64(RateRule.maximumPacketsPerSecond)
        let bytes = perSecond * 2 * 64
        let p = counters(0, 0, 0, 0)
        let c = counters(bytes, 0, perSecond * 2, 0)
        XCTAssertEqual(RateRule.evaluate(previous: p, current: c, elapsed: 1), .discarded(.reset))
        if case .discarded = RateRule.evaluate(previous: p, current: c, elapsed: 2) {
            XCTFail("twice the interval allows twice the packets")
        }
    }

    // MARK: rule 6: bytes without packets to carry them

    func testBytesJumpingWithoutPacketsIsAReset() {
        // After a reset the byte delta is garbage anywhere in 0..<4 GiB, while the
        // packet counter may happen to look like a small step forwards.
        let p = counters(1_000_448, 0, 4_294_967_000, 0)
        let c = counters(3_000_000_512, 0, 40, 0)  // packets: +336 modulo 2^32
        XCTAssertEqual(RateRule.evaluate(previous: p, current: c, elapsed: 1), .discarded(.reset))
    }

    func testByteCeilingAllowsTheLargestRealSegments() {
        // 64 KiB per packet is physically possible; the ceiling is twice that.
        let p = counters(0, 0, 0, 0)
        let c = counters(65_536 * 1_000, 0, 1_000, 0)
        guard case .rate = RateRule.evaluate(previous: p, current: c, elapsed: 1) else {
            return XCTFail("full-size segments must not be discarded")
        }
    }

    func testFlooringSlackDoesNotDiscardAQuietSample() {
        // The floor can release up to 1 KiB in a sample whose packets were counted a tick earlier.
        let p = counters(10_240, 0, 100, 0)
        let c = counters(11_264, 0, 100, 0)
        guard case .rate(let rate) = RateRule.evaluate(previous: p, current: c, elapsed: 1) else {
            return XCTFail("one floor quantum with no packets is not a reset")
        }
        XCTAssertEqual(rate.downBytes, 1_024)
    }

    // MARK: which outcomes move the baseline

    func testOnlyTooSoonKeepsTheOldBaseline() {
        XCTAssertTrue(SampleOutcome.baseline.movesBaseline)
        XCTAssertTrue(SampleOutcome.discarded(.reset).movesBaseline)
        XCTAssertTrue(SampleOutcome.discarded(.intervalTooLong).movesBaseline)
        XCTAssertTrue(SampleOutcome.rate(Rate(downBytesPerSecond: 0, upBytesPerSecond: 0, downBytes: 0, upBytes: 0)).movesBaseline)
        XCTAssertFalse(SampleOutcome.tooSoon.movesBaseline)
    }
}
