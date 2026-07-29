import XCTest
@testable import LaneLine

final class NavigationOrientationFilterTests: XCTestCase {
    private let config = NavigationOrientationConfig.default

    func testCourseIsTrustworthyWhenMovingWithValidCourse() {
        XCTAssertTrue(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: 5, course: 90, config: config
        ))
    }

    func testCourseIsNotTrustworthyBelowSpeedThreshold() {
        XCTAssertFalse(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: 0.5, course: 90, config: config
        ))
    }

    func testCourseIsNotTrustworthyWhenInvalid() {
        XCTAssertFalse(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: 5, course: -1, config: config
        ))
    }

    func testCourseIsNotTrustworthyWhenEitherValueIsMissing() {
        XCTAssertFalse(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: nil, course: 90, config: config
        ))
        XCTAssertFalse(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: 5, course: nil, config: config
        ))
    }

    func testHeadingIsTrustworthyWithGoodAccuracy() {
        XCTAssertTrue(NavigationOrientationFilters.isHeadingTrustworthy(
            heading: 200, accuracy: 10, config: config
        ))
    }

    func testHeadingIsNotTrustworthyWithPoorAccuracy() {
        XCTAssertFalse(NavigationOrientationFilters.isHeadingTrustworthy(
            heading: 200, accuracy: 60, config: config
        ))
    }

    func testHeadingIsNotTrustworthyWhenAccuracyIsInvalid() {
        XCTAssertFalse(NavigationOrientationFilters.isHeadingTrustworthy(
            heading: 200, accuracy: -1, config: config
        ))
    }

    func testHeadingIsNotTrustworthyWhenMissing() {
        XCTAssertFalse(NavigationOrientationFilters.isHeadingTrustworthy(
            heading: nil, accuracy: 10, config: config
        ))
    }
}

final class NavigationOrientationEngineTests: XCTestCase {
    private func makeEngine(initialBearing: Double = 0) -> NavigationOrientationEngine {
        NavigationOrientationEngine(initialBearing: initialBearing)
    }

    func testPrefersCourseWhenMovingWithGoodCourse() {
        let engine = makeEngine()
        let result = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: 10, headingAccuracy: 5,
            routeBearing: 0, deltaSeconds: 1
        )
        XCTAssertEqual(engine.activeSource, .course)
        XCTAssertGreaterThan(result, 0, "Should have started moving toward the course, away from the seed bearing")
    }

    func testFreezesLastGoodCourseThroughTheGraceWindow() {
        let engine = makeEngine(initialBearing: 90)
        _ = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: nil, headingAccuracy: nil,
            routeBearing: 90, deltaSeconds: 1
        )
        for _ in 0..<3 {
            _ = engine.update(
                speedMetersPerSecond: 0.2, course: 90, heading: 200, headingAccuracy: 5,
                routeBearing: 90, deltaSeconds: 1
            )
        }
        XCTAssertEqual(engine.activeSource, .course, "Still within the grace window")
    }

    func testFallsBackToHeadingAfterTheGraceWindowExpires() {
        let engine = makeEngine(initialBearing: 90)
        _ = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: nil, headingAccuracy: nil,
            routeBearing: 90, deltaSeconds: 1
        )
        for _ in 0..<4 {
            _ = engine.update(
                speedMetersPerSecond: 0.2, course: 90, heading: 200, headingAccuracy: 5,
                routeBearing: 90, deltaSeconds: 1
            )
        }
        XCTAssertEqual(engine.activeSource, .heading)
    }

    func testFallsBackToRouteBearingWhenNeitherCourseNorHeadingAreTrustworthy() {
        let engine = makeEngine(initialBearing: 45)
        for _ in 0..<4 {
            _ = engine.update(
                speedMetersPerSecond: 0.2, course: -1, heading: nil, headingAccuracy: nil,
                routeBearing: 200, deltaSeconds: 1
            )
        }
        XCTAssertEqual(engine.activeSource, .routeBearing)
    }

    func testResumesCourseImmediatelyOnceTrustworthyAgainWithNoExtraGrace() {
        let engine = makeEngine(initialBearing: 90)
        _ = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: nil, headingAccuracy: nil,
            routeBearing: 90, deltaSeconds: 1
        )
        for _ in 0..<4 {
            _ = engine.update(
                speedMetersPerSecond: 0.2, course: 90, heading: 200, headingAccuracy: 5,
                routeBearing: 90, deltaSeconds: 1
            )
        }
        XCTAssertEqual(engine.activeSource, .heading, "Sanity check: should have fallen back first")

        _ = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: 200, headingAccuracy: 5,
            routeBearing: 90, deltaSeconds: 1
        )
        XCTAssertEqual(engine.activeSource, .course, "Should resume course the instant it's trustworthy again")
    }

    func testSuppressesJitterBelowTheMinimumAngleDelta() {
        let engine = makeEngine(initialBearing: 90)
        let result = engine.update(
            speedMetersPerSecond: 5, course: 90.5, heading: nil, headingAccuracy: nil,
            routeBearing: 90, deltaSeconds: 1
        )
        XCTAssertEqual(result, 90, accuracy: 0.0001, "A sub-threshold nudge should not move the display bearing at all")
    }

    func testStillRotatesPromptlyThroughARealSharpTurn() {
        let engine = makeEngine(initialBearing: 0)
        var bearing = 0.0
        for _ in 0..<3 {
            bearing = engine.update(
                speedMetersPerSecond: 5, course: 90, heading: nil, headingAccuracy: nil,
                routeBearing: 0, deltaSeconds: 1
            )
        }
        XCTAssertGreaterThan(bearing, 45, "Three ticks of smoothing through a real 90 degree turn should have visibly rotated, not lagged")
    }

    func testHandlesWraparoundWithoutSpinningTheLongWayAround() {
        let engine = makeEngine(initialBearing: 359)
        let result = engine.update(
            speedMetersPerSecond: 5, course: 1, heading: nil, headingAccuracy: nil,
            routeBearing: 0, deltaSeconds: 1
        )
        XCTAssertTrue(result < 5 || result > 355, "Expected a short step across the wraparound, got \(result)")
    }
}
