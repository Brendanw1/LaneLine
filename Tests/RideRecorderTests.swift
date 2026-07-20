import XCTest
import CoreLocation
@testable import LaneLine

@MainActor
final class RideRecorderTests: XCTestCase {
    private func makeRecorder(
        location: MockLocationService,
        altimeter: MockAltimeter? = nil,
        startElevation: Double? = 10
    ) -> RideRecorder {
        RideRecorder(
            profile: .testProfile(bikeType: .roadBike),
            routeName: "Test route",
            startElevationMeters: startElevation,
            locationService: location,
            altimeter: altimeter ?? MockAltimeter(),
            store: nil
        )
    }

    func testTicksAccumulateDistanceFromLocationFixes() {
        let location = MockLocationService()
        let recorder = makeRecorder(location: location)
        recorder.start()
        let start = Date()
        for t in 0...30 {
            location.setLocation(CLLocationCoordinate2D(
                latitude: 37.76 + Double(t) * 0.000045, longitude: -122.42
            ))
            recorder.processTick(now: start.addingTimeInterval(Double(t)))
        }
        XCTAssertEqual(recorder.distanceMeters, 150, accuracy: 10)
        XCTAssertGreaterThan(recorder.currentSpeedKmh, 10)
        let record = recorder.finish()
        XCTAssertEqual(record.samples.count, 31)
        XCTAssertTrue(record.summary.isComplete)
        XCTAssertEqual(record.summary.routeName, "Test route")
        XCTAssertEqual(record.summary.distanceMeters, recorder.distanceMeters)
    }

    func testBarometricAltitudeAnchorsToStartElevation() {
        let location = MockLocationService()
        let altimeter = MockAltimeter()
        let recorder = makeRecorder(location: location, altimeter: altimeter, startElevation: 50)
        recorder.start()
        let start = Date()
        for t in 0...20 {
            location.setLocation(CLLocationCoordinate2D(
                latitude: 37.76 + Double(t) * 0.000045, longitude: -122.42
            ))
            altimeter.relativeAltitudeMeters = Double(t) * 0.5   // +10 m over the run
            recorder.processTick(now: start.addingTimeInterval(Double(t)))
        }
        XCTAssertEqual(recorder.altitudeMeters ?? 0, 60, accuracy: 0.6)
        XCTAssertEqual(recorder.ascentMeters, 10, accuracy: 2.1)
    }

    func testFallbackSampleDrivesStatsWithoutFix() {
        // Fix-less mock, like the demo ride.
        let location = MockLocationService(coordinate: nil)
        var simulated = CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42)
        let recorder = RideRecorder(
            profile: .testProfile(bikeType: .roadBike),
            routeName: "Demo",
            startElevationMeters: 10,
            locationService: location,
            altimeter: MockAltimeter(),
            store: nil,
            fallbackSample: { .init(coordinate: simulated, speedKmh: 18, altitudeMeters: 10) }
        )
        recorder.start()
        let start = Date()
        for t in 0...30 {
            simulated.latitude += 0.000045
            recorder.processTick(now: start.addingTimeInterval(Double(t)))
        }
        XCTAssertEqual(recorder.currentSpeedKmh, 18, accuracy: 1.5)
        XCTAssertGreaterThan(recorder.distanceMeters, 100)
    }

    func testManualPauseFreezesEverything() {
        let location = MockLocationService()
        let recorder = makeRecorder(location: location)
        recorder.start()
        let start = Date()
        for t in 0...10 {
            location.setLocation(CLLocationCoordinate2D(
                latitude: 37.76 + Double(t) * 0.000045, longitude: -122.42
            ))
            recorder.processTick(now: start.addingTimeInterval(Double(t)))
        }
        let frozenElapsed = recorder.elapsedSeconds
        recorder.setPaused(true)
        for t in 11...20 {
            recorder.processTick(now: start.addingTimeInterval(Double(t)))
        }
        XCTAssertEqual(recorder.elapsedSeconds, frozenElapsed, accuracy: 0.01)
        XCTAssertTrue(recorder.isPaused)
    }

    func testFinishIsIdempotent() {
        let location = MockLocationService()
        let recorder = makeRecorder(location: location)
        recorder.start()
        recorder.processTick(now: Date())
        let first = recorder.finish()
        let second = recorder.finish()
        XCTAssertEqual(first.id, second.id)
        XCTAssertFalse(recorder.isRecording)
    }
}
