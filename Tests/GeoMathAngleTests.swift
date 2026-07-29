import XCTest
@testable import LaneLine

final class GeoMathAngleTests: XCTestCase {
    func testNormalizedDegreesWrapsPositiveOverflow() {
        XCTAssertEqual(GeoMath.normalizedDegrees(370), 10, accuracy: 0.0001)
    }

    func testNormalizedDegreesWrapsNegativeValues() {
        XCTAssertEqual(GeoMath.normalizedDegrees(-10), 350, accuracy: 0.0001)
    }

    func testNormalizedDegreesHandlesMultiLapMagnitudes() {
        XCTAssertEqual(GeoMath.normalizedDegrees(725), 5, accuracy: 0.0001)
    }

    func testTurnAngleTakesShortestPathAcrossWraparound() {
        // 359 -> 1 should read as +2 (short way through 0), not -358.
        XCTAssertEqual(GeoMath.turnAngleDegrees(fromBearing: 359, toBearing: 1), 2, accuracy: 0.0001)
    }

    func testInterpolatedAngleStepsTheShortWayAcrossWraparound() {
        let result = GeoMath.interpolatedAngle(from: 359, to: 1, fraction: 0.5)
        XCTAssertEqual(result, 0, accuracy: 0.0001)
    }

    func testInterpolatedAngleAtZeroFractionStaysPut() {
        XCTAssertEqual(GeoMath.interpolatedAngle(from: 45, to: 200, fraction: 0), 45, accuracy: 0.0001)
    }

    func testInterpolatedAngleAtFullFractionReachesTarget() {
        let result = GeoMath.interpolatedAngle(from: 45, to: 200, fraction: 1)
        XCTAssertEqual(result, 200, accuracy: 0.0001)
    }
}
