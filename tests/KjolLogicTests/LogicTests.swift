import XCTest
@testable import KjolLogic

final class LogicTests: XCTestCase {

    func testVersionComparison() {
        XCTAssertTrue(VersionComparator.isVersion("1.0.1", newerThan: "1.0.0"))
        XCTAssertTrue(VersionComparator.isVersion("v1.1.0", newerThan: "1.0.9"))
        XCTAssertTrue(VersionComparator.isVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertFalse(VersionComparator.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(VersionComparator.isVersion("1.0.0", newerThan: "1.0.1"))
        XCTAssertFalse(VersionComparator.isVersion("v1.0.0", newerThan: "1.0.0"))
    }

    func testCpuUsageCalculator() {
        let usage = CpuUsageCalculator.computeUsage(totalDelta: 1000, busyDelta: 250)
        XCTAssertEqual(usage, 25.0)

        let zeroUsage = CpuUsageCalculator.computeUsage(totalDelta: 0, busyDelta: 0)
        XCTAssertEqual(zeroUsage, 0.0)

        let maxUsage = CpuUsageCalculator.computeUsage(totalDelta: 500, busyDelta: 500)
        XCTAssertEqual(maxUsage, 100.0)
    }

    func testCalibrationCalculations() {
        // Phase 1 (0 -> 100% maps to 0.0 -> 0.3)
        XCTAssertEqual(CalibrationCalculator.calculatePhase1Progress(currentCap: 0), 0.0)
        XCTAssertEqual(CalibrationCalculator.calculatePhase1Progress(currentCap: 50), 0.15)
        XCTAssertEqual(CalibrationCalculator.calculatePhase1Progress(currentCap: 100), 0.3)

        // Phase 2 (Hold 3600s maps to 0.3 -> 0.5)
        XCTAssertEqual(CalibrationCalculator.calculatePhase2Progress(elapsed: 0), 0.3)
        XCTAssertEqual(CalibrationCalculator.calculatePhase2Progress(elapsed: 1800), 0.4)
        XCTAssertEqual(CalibrationCalculator.calculatePhase2Progress(elapsed: 3600), 0.5)

        // Phase 3 (Discharge 100% -> 15% maps to 0.5 -> 0.8)
        XCTAssertEqual(CalibrationCalculator.calculatePhase3Progress(currentCap: 100), 0.5)
        XCTAssertEqual(CalibrationCalculator.calculatePhase3Progress(currentCap: 15), 0.8)

        // Phase 4 (Recharge 15% -> 80% maps to 0.8 -> 1.0)
        XCTAssertEqual(CalibrationCalculator.calculatePhase4Progress(currentCap: 15, target: 80), 0.8)
        XCTAssertEqual(CalibrationCalculator.calculatePhase4Progress(currentCap: 80, target: 80), 1.0)
    }

    func testMockSMCProvider() throws {
        let mock = MockSMCProvider()
        XCTAssertFalse(mock.hasKey("BCLM"))

        try mock.writeUInt8("BCLM", 80)
        XCTAssertTrue(mock.hasKey("BCLM"))
        XCTAssertEqual(try mock.readUInt8("BCLM"), 80)

        try mock.writeFloat("F0Tg", 2500.0)
        XCTAssertEqual(try mock.readFloat("F0Tg"), 2500.0)
    }
}
