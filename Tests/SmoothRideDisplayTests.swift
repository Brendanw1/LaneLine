import XCTest
import CoreLocation
import HealthKit
@testable import LaneLine

/// The smooth-puck contract: the displayed position glides at the rider's
/// measured speed, never teleports between logic ticks, and never leads the
/// confirmed GPS position by more than a fix interval. The math lives in
/// `DisplayPuck` (pure) so these tests run without a render loop.
final class SmoothRideDisplayTests: XCTestCase {
    private let dt: Double = 1.0 / 30.0
    private let leadSeconds: Double = 1.2
    private let routeEnd: Double = 10_000

    @MainActor
    func testSimulationModeKeepsPuckPinnedToTruth() async throws {
        // Fix-less mock: the simulation owns forward motion; in synchronous
        // (test) driving, tick advances truth and the puck must not diverge.
        let model = try await makeModel(fixless: true)
        for _ in 0..<10 {
            model.tick(deltaSeconds: 1)
            XCTAssertEqual(model.displayProgressMeters, model.progressMeters, accuracy: 0.001)
        }
        XCTAssertGreaterThan(model.progressMeters, 0, "Simulation should advance")
    }

    @MainActor
    private func makeModel(fixless: Bool) async throws -> ActiveRideModel {
        let o = TestGraphs.coordinate(37.7600, -122.4200, 10)
        let n = TestGraphs.coordinate(37.7700, -122.4200, 10)
        let graph = try await TestGraphs.build([
            TestGraphs.rawEdge(from: o, to: n, street: "Smooth St"),
        ])
        let routing = RoutingService(geospatialService: StubGeospatialService(graph: graph))
        let routes = try await routing.generateRoutes(
            from: o.clCoordinate, to: n.clCoordinate,
            profile: .testProfile(bikeType: .roadBike), strategies: [.balanced]
        )
        let candidate = try XCTUnwrap(routes.first)
        return ActiveRideModel(
            route: candidate,
            profile: .testProfile(bikeType: .roadBike),
            locationService: MockLocationService(coordinate: fixless ? nil : o.clCoordinate),
            routingService: routing
        )
    }

    // MARK: DisplayPuck (real-fix path)

    func testPuckGlidesWithoutJumps() {
        var display = 0.0
        let speed: Double = 6.0   // ~22 km/h
        var truth = 0.0
        var previous = display
        // 10 s of riding: truth confirms once per second (1 Hz fixes) while
        // the puck moves every frame. Between confirmations the puck glides
        // at the measured speed; each frame's step must stay within one
        // frame of travel.
        for frame in 0..<300 {
            if frame % 30 == 0, frame > 0 { truth += speed }   // 1 Hz fix
            display = DisplayPuck.advanced(
                display: display, truth: truth, speedMs: speed, deltaSeconds: dt,
                leadSeconds: leadSeconds, routeEndMeters: routeEnd
            )
            let step = display - previous
            XCTAssertLessThanOrEqual(step, speed * dt + 0.001, "Puck moved faster than the rider")
            XCTAssertGreaterThanOrEqual(step, 0, "Puck moved backwards without a correction")
            // Never lead the last confirmed fix by more than a fix interval.
            XCTAssertLessThanOrEqual(display - truth, speed * leadSeconds + 0.001)
            previous = display
        }
        // Steady state: the puck rides between one fix ahead and the lead
        // bound — dead reckoning anticipates the next confirmation, which
        // is the whole point.
        XCTAssertGreaterThanOrEqual(display, truth)
        XCTAssertLessThanOrEqual(display - truth, speed * 1.5)
    }

    func testPuckCatchesUpWhenFixJumpsAhead() {
        var display = 100.0
        // Rider got a fix 50 m ahead of the puck (GPS burst / cell snap).
        let truth = 150.0
        for _ in 0..<60 {
            display = DisplayPuck.advanced(
                display: display, truth: truth, speedMs: 0, deltaSeconds: dt,
                leadSeconds: leadSeconds, routeEndMeters: routeEnd
            )
        }
        XCTAssertEqual(display, truth, accuracy: 0.5, "Puck should ease onto the confirmed position")
    }

    func testPuckEasesBackWhenLeadingAndRiderStops() {
        // Puck led by a fix interval; the rider then stopped (speed 0).
        var display = 50.0
        let truth = 44.0   // ~6 m of lead
        for _ in 0..<30 {
            display = DisplayPuck.advanced(
                display: display, truth: truth, speedMs: 0, deltaSeconds: dt,
                leadSeconds: leadSeconds, routeEndMeters: routeEnd
            )
        }
        XCTAssertEqual(display, truth, accuracy: 0.5, "Stopped rider's puck must settle on the fix")
    }

    func testPuckNeverPassesRouteEnd() {
        var display = routeEnd - 1
        for _ in 0..<60 {
            display = DisplayPuck.advanced(
                display: display, truth: routeEnd - 1, speedMs: 8, deltaSeconds: dt,
                leadSeconds: leadSeconds, routeEndMeters: routeEnd
            )
        }
        XCTAssertLessThanOrEqual(display, routeEnd + 0.001)
    }

    func testPuckCatchesUpFasterThanItGlides() {
        // A big fix jump closes in well under a second of wall time — the
        // correction must not take a full tick's worth of travel distance.
        var display = 0.0
        let truth = 40.0
        for _ in 0..<15 {
            display = DisplayPuck.advanced(
                display: display, truth: truth, speedMs: 0, deltaSeconds: dt,
                leadSeconds: leadSeconds, routeEndMeters: routeEnd
            )
        }
        XCTAssertGreaterThan(display, 30, "Catch-up should close most of the gap in ~0.5 s")
    }

    // MARK: Formatter

    func testSignedGradeNeverRendersNegativeZero() {
        XCTAssertEqual(RideFormat.signedGrade(0), "0%")
        XCTAssertEqual(RideFormat.signedGrade(-0.001), "0%", "-0.1% rounds to a sign-less zero")
        XCTAssertEqual(RideFormat.signedGrade(-0.004), "0%")
        XCTAssertEqual(RideFormat.signedGrade(-0.006), "-1%")
        XCTAssertEqual(RideFormat.signedGrade(0.004), "0%")
        XCTAssertEqual(RideFormat.signedGrade(0.081), "+8%")
        XCTAssertEqual(RideFormat.signedGrade(-0.032), "-3%")
    }
}

// MARK: - Heart Rate Recording

/// A ride with a Watch stream must carry per-sample BPM and roll the
/// summary totals up from exactly those samples; a ride without one must
/// keep both nil so the summary hides them.
@MainActor
final class HeartRateRecordingTests: XCTestCase {
    /// Minimal protocol stand-in with directly settable readings.
    private final class StubHeartRate: HeartRateMonitoring {
        var currentBPM: Double?
        var isAuthorized = true
        var hasReceivedSamples = false
        func start() async {}
        func stop() {}
    }

    private func makeRecorder(heartRate: StubHeartRate?) -> RideRecorder {
        RideRecorder(
            profile: .testProfile(bikeType: .roadBike),
            routeName: "HR test",
            startElevationMeters: nil,
            locationService: MockLocationService(coordinate: nil),
            altimeter: AltimeterService(),
            store: nil,
            fallbackSample: {
                // Simulated-source input so every tick produces a sample
                // (a fix-less mock with no fallback records gaps only).
                RideRecorder.FallbackSample(
                    coordinate: CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42),
                    speedKmh: 18,
                    altitudeMeters: 10
                )
            },
            tickInterval: 1,
            heartRate: heartRate
        )
    }

    private func sample(at second: Int, from start: Date) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.76 + Double(second) * 0.0001, longitude: -122.42),
            altitude: 10, horizontalAccuracy: 5, verticalAccuracy: 5,
            course: -1, speed: 5, timestamp: start.addingTimeInterval(TimeInterval(second))
        )
    }

    func testSamplesCarryBPMAndSummaryRollsUp() {
        let hr = StubHeartRate()
        let recorder = makeRecorder(heartRate: hr)
        recorder.start()
        let start = Date.now
        let readings: [Double?] = [140, nil, 150, 160, nil]
        for (index, bpm) in readings.enumerated() {
            hr.currentBPM = bpm
            recorder.processTick(now: start.addingTimeInterval(TimeInterval(index)))
        }
        let record = recorder.finish()
        let recordedBPMs = record.samples.compactMap(\.heartRateBPM)
        XCTAssertEqual(recordedBPMs, [140, 150, 160], "Nil readings stay nil, real ones land per sample")
        XCTAssertEqual(record.summary.averageHeartRateBPM ?? 0, 150, accuracy: 0.01)
        XCTAssertEqual(record.summary.maxHeartRateBPM ?? 0, 160, accuracy: 0.01)
    }

    func testRideWithoutStreamKeepsHRNil() {
        let recorder = makeRecorder(heartRate: nil)
        recorder.start()
        let start = Date.now
        for second in 0..<5 {
            recorder.processTick(now: start.addingTimeInterval(TimeInterval(second)))
        }
        let record = recorder.finish()
        XCTAssertTrue(record.samples.allSatisfy { $0.heartRateBPM == nil })
        XCTAssertNil(record.summary.averageHeartRateBPM)
        XCTAssertNil(record.summary.maxHeartRateBPM)
    }

    func testLegacyRecordWithoutHRKeysDecodes() throws {
        // A record written before HR integration existed.
        let legacy = """
        {"summary":{"id":"\(UUID().uuidString)","startedAt":700000000.0,
          "routeName":"Old","durationSeconds":600,"movingSeconds":550,
          "distanceMeters":3000,"averageSpeedKmh":19.6,"maxSpeedKmh":32.1,
          "ascentMeters":45,"descentMeters":40,"calories":120,
          "isComplete":true},
         "samples":[{"t":0,"latitude":37.76,"longitude":-122.42,
           "speedKmh":18,"distanceMeters":0}]}
        """.data(using: .utf8)!
        let record = try JSONDecoder().decode(RideRecord.self, from: legacy)
        XCTAssertNil(record.summary.averageHeartRateBPM)
        XCTAssertNil(record.samples[0].heartRateBPM)
    }

    func testFreshnessWindowGatesStaleReadings() {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        func make(_ ageSeconds: Double) -> HKQuantitySample {
            HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: HKUnit.count().unitDivided(by: .minute()),
                                     doubleValue: 150),
                start: Date.now.addingTimeInterval(-ageSeconds - 1),
                end: Date.now.addingTimeInterval(-ageSeconds)
            )
        }
        XCTAssertTrue(HeartRateFreshness.isFresh(make(10)))
        XCTAssertTrue(HeartRateFreshness.isFresh(make(59)))
        XCTAssertFalse(HeartRateFreshness.isFresh(make(61)))
        XCTAssertEqual(HeartRateFreshness.beatsPerMinute(make(1)), 150, accuracy: 0.01)
    }
}

// MARK: - Customization Migration

final class CameraOrientationCodableTests: XCTestCase {
    func testLegacyBlobGainsHeartRateChipAndCameraDefault() throws {
        // Byte-equal to the pre-HR default set: the rider never customized,
        // so they get the new chip.
        let legacy = """
        {"layoutMode":"standard","largerControlsEnabled":false,
         "highContrastEnabled":false,"metricsPriority":"time",
         "musicTrayDefaultExpanded":false,
         "visibleSecondaryMetrics":["currentGrade","climbRemaining"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideScreenCustomization.self, from: legacy)
        XCTAssertTrue(decoded.visibleSecondaryMetrics.contains(.heartRate))
        XCTAssertEqual(decoded.cameraOrientation, .headingUp)
    }

    func testCuratedMetricSetIsRespected() throws {
        let legacy = """
        {"layoutMode":"standard","largerControlsEnabled":false,
         "highContrastEnabled":false,"metricsPriority":"time",
         "musicTrayDefaultExpanded":false,
         "visibleSecondaryMetrics":["currentGrade"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideScreenCustomization.self, from: legacy)
        XCTAssertFalse(decoded.visibleSecondaryMetrics.contains(.heartRate),
                       "A rider who curated their set keeps exactly what they chose")
    }

    func testOrientationRoundTrip() throws {
        var customization = RideScreenCustomization.default
        customization.cameraOrientation = .northUp
        let data = try JSONEncoder().encode(customization)
        let decoded = try JSONDecoder().decode(RideScreenCustomization.self, from: data)
        XCTAssertEqual(decoded.cameraOrientation, .northUp)
    }
}
