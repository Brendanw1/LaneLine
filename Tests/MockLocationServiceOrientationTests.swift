import XCTest
import CoreLocation
@testable import LaneLine

@MainActor
final class MockLocationServiceOrientationTests: XCTestCase {
    func testSetLocationPopulatesCourseSpeedAndHeadingAccuracy() {
        let service = MockLocationService(coordinate: nil)
        service.setLocation(
            CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42),
            heading: 42, headingAccuracy: 6,
            course: 88, courseAccuracy: 12, speed: 4.5
        )

        XCTAssertEqual(service.currentHeading, 42)
        XCTAssertEqual(service.currentHeadingAccuracy, 6)
        XCTAssertEqual(service.currentLocation?.course, 88)
        XCTAssertEqual(service.currentLocation?.courseAccuracy, 12)
        XCTAssertEqual(service.currentLocation?.speed, 4.5)
    }

    func testSetLocationDefaultsLeaveCourseAndSpeedInvalid() {
        let service = MockLocationService(coordinate: nil)
        service.setLocation(CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42))

        XCTAssertNil(service.currentHeading)
        XCTAssertNil(service.currentHeadingAccuracy)
        XCTAssertEqual(service.currentLocation?.course ?? -1, -1)
        XCTAssertEqual(service.currentLocation?.speed ?? -1, -1)
    }
}
