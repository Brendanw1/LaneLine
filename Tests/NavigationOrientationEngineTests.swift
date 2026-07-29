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
