import XCTest
@testable import LaneLine

final class RideAggregatorTests: XCTestCase {
    private let profile = RiderProfile.testProfile(bikeType: .roadBike)

    /// Northward fixes ~5 m apart (0.000045° latitude ≈ 5.0 m).
    private func input(
        t: Double, steps: Double, altitude: Double? = nil, speedMs: Double? = nil
    ) -> RideAggregator.Input {
        RideAggregator.Input(
            timestamp: t, latitude: 37.76 + steps * 0.000045, longitude: -122.42,
            altitudeMeters: altitude, speedMs: speedMs
        )
    }

    func testDistanceAndAverageSpeedFromPositionDeltas() {
        var agg = RideAggregator(profile: profile)
        for t in 0...60 {
            _ = agg.ingest(input(t: Double(t), steps: Double(t)))
        }
        XCTAssertEqual(agg.totals.distanceMeters, 300, accuracy: 15)
        XCTAssertEqual(agg.totals.elapsedSeconds, 60, accuracy: 0.01)
        XCTAssertEqual(agg.totals.movingSeconds, 60, accuracy: 0.01)
        XCTAssertEqual(agg.totals.averageSpeedMs, 5, accuracy: 0.5)
        XCTAssertFalse(agg.totals.isAutoPaused)
    }

    func testReportedSpeedPreferredAndSmoothed() {
        var agg = RideAggregator(profile: profile)
        for t in 0...30 {
            _ = agg.ingest(input(t: Double(t), steps: Double(t), speedMs: 6))
        }
        XCTAssertEqual(agg.totals.speedMs, 6, accuracy: 0.2)
        XCTAssertLessThanOrEqual(agg.totals.maxSpeedMs, 6.01)
        XCTAssertGreaterThan(agg.totals.maxSpeedMs, 5)
    }

    func testAutoPauseStopsMovingClock() {
        var agg = RideAggregator(profile: profile)
        for t in 0...60 {
            _ = agg.ingest(input(t: Double(t), steps: Double(t), speedMs: 5))
        }
        // Standing still for 30 s at the same position.
        for t in 61...90 {
            _ = agg.ingest(input(t: Double(t), steps: 60, speedMs: 0))
        }
        XCTAssertTrue(agg.totals.isAutoPaused)
        XCTAssertEqual(agg.totals.elapsedSeconds, 90, accuracy: 0.01)
        // Smoothing delays the trigger; at least the last ~20 s must not count.
        XCTAssertLessThan(agg.totals.movingSeconds, 72)
        // Riding again resumes the clock.
        for t in 91...100 {
            _ = agg.ingest(input(t: Double(t), steps: 60 + Double(t - 90), speedMs: 5))
        }
        XCTAssertFalse(agg.totals.isAutoPaused)
    }

    func testAscentHysteresisIgnoresNoise() {
        var agg = RideAggregator(profile: profile)
        // ±1 m oscillation around 100 m: inside the 2 m hysteresis band.
        for t in 0...40 {
            let noise = t.isMultiple(of: 2) ? 1.0 : -1.0
            _ = agg.ingest(input(t: Double(t), steps: Double(t), altitude: 100 + noise, speedMs: 5))
        }
        XCTAssertEqual(agg.totals.ascentMeters, 0, accuracy: 0.01)
        XCTAssertEqual(agg.totals.descentMeters, 0, accuracy: 0.01)
    }

    func testRealClimbAccumulatesAscent() {
        var agg = RideAggregator(profile: profile)
        // 100 m → 110 m over 40 ticks.
        for t in 0...40 {
            _ = agg.ingest(input(t: Double(t), steps: Double(t), altitude: 100 + Double(t) * 0.25, speedMs: 5))
        }
        XCTAssertEqual(agg.totals.ascentMeters, 10, accuracy: 2.1)
        XCTAssertEqual(agg.totals.descentMeters, 0, accuracy: 0.01)
    }

    func testGradeOverTrailingWindow() throws {
        var agg = RideAggregator(profile: profile)
        // 5 m per tick, +0.4 m altitude per tick → 8 % grade.
        for t in 0...30 {
            _ = agg.ingest(input(t: Double(t), steps: Double(t), altitude: 50 + Double(t) * 0.4, speedMs: 5))
        }
        let grade = try XCTUnwrap(agg.totals.gradeDecimal)
        XCTAssertEqual(grade, 0.08, accuracy: 0.02)
    }

    func testTeleportJumpAccruesNoDistance() {
        var agg = RideAggregator(profile: profile)
        for t in 0...10 {
            _ = agg.ingest(input(t: Double(t), steps: Double(t), speedMs: 5))
        }
        let before = agg.totals.distanceMeters
        // 500 m teleport (GPS glitch / tunnel exit).
        _ = agg.ingest(RideAggregator.Input(
            timestamp: 11, latitude: 37.7645, longitude: -122.42, altitudeMeters: nil, speedMs: 5
        ))
        XCTAssertEqual(agg.totals.distanceMeters, before, accuracy: 0.01)
        XCTAssertEqual(agg.totals.elapsedSeconds, 11, accuracy: 0.01)
    }

    func testCaloriesPlausibleForHalfHourCruise() {
        var agg = RideAggregator(profile: profile)
        // 30 min at 20 km/h on the flat.
        for t in 0...1800 {
            _ = agg.ingest(input(t: Double(t), steps: Double(t), altitude: 10, speedMs: 20 / 3.6))
        }
        XCTAssertGreaterThan(agg.totals.kilocalories, 60)
        XCTAssertLessThan(agg.totals.kilocalories, 160)
    }

    func testSampleCarriesCumulativeState() {
        var agg = RideAggregator(profile: profile)
        _ = agg.ingest(input(t: 0, steps: 0, altitude: 20, speedMs: 5))
        let sample = agg.ingest(input(t: 1, steps: 1, altitude: 20, speedMs: 5))
        XCTAssertEqual(sample.t, 1)
        XCTAssertEqual(sample.distanceMeters, agg.totals.distanceMeters)
        XCTAssertEqual(sample.altitudeMeters, 20)
        XCTAssertGreaterThan(sample.speedKmh, 0)
    }
}
