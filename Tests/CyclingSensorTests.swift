import XCTest
import CoreLocation
@testable import LaneLine

// MARK: - CSC Parsing

/// Byte-level decoding of the Bluetooth CSC Measurement characteristic
/// (0x2A5B) as the Magene S3+ sends it in each mode.
final class CSCMeasurementTests: XCTestCase {
    func testCadenceModePayload() throws {
        // flags=0x02 (crank only), revs=0x0102, time=0x0400 (1 s)
        let m = try XCTUnwrap(CSCMeasurement(data: Data([0x02, 0x02, 0x01, 0x00, 0x04])))
        XCTAssertFalse(m.hasWheelData)
        XCTAssertEqual(m.cumulativeCrankRevolutions, 0x0102)
        XCTAssertEqual(m.lastCrankEventTime, 0x0400)
    }

    func testSpeedModePayload() throws {
        // flags=0x01 (wheel only), revs=0x00010203 LE, time=0x0800
        let m = try XCTUnwrap(CSCMeasurement(data: Data([0x01, 0x03, 0x02, 0x01, 0x00, 0x00, 0x08])))
        XCTAssertFalse(m.hasCrankData)
        XCTAssertEqual(m.cumulativeWheelRevolutions, 0x0001_0203)
        XCTAssertEqual(m.lastWheelEventTime, 0x0800)
    }

    func testCombinedPayloadReadsWheelThenCrank() throws {
        let bytes: [UInt8] = [0x03, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x01, 0x05, 0x00, 0x00, 0x02]
        let m = try XCTUnwrap(CSCMeasurement(data: Data(bytes)))
        XCTAssertEqual(m.cumulativeWheelRevolutions, 10)
        XCTAssertEqual(m.lastWheelEventTime, 0x0100)
        XCTAssertEqual(m.cumulativeCrankRevolutions, 5)
        XCTAssertEqual(m.lastCrankEventTime, 0x0200)
    }

    func testTruncatedPayloadsAreRejected() {
        XCTAssertNil(CSCMeasurement(data: Data()))
        XCTAssertNil(CSCMeasurement(data: Data([0x02, 0x01, 0x00, 0x00])),
                     "Crank flag promises 4 bytes; 3 must not parse as zeroed counters")
        XCTAssertNil(CSCMeasurement(data: Data([0x03, 0, 0, 0, 0, 0, 0, 0, 0])))
    }
}

// MARK: - Rate Math

final class CSCRateCalculatorTests: XCTestCase {
    private func crank(_ revs: UInt16, _ time: UInt16) -> CSCMeasurement {
        CSCMeasurement(cumulativeCrankRevolutions: revs, lastCrankEventTime: time)
    }

    private func wheel(_ revs: UInt32, _ time: UInt16) -> CSCMeasurement {
        CSCMeasurement(cumulativeWheelRevolutions: revs, lastWheelEventTime: time)
    }

    func testCadenceFromConsecutiveCrankEvents() {
        var calc = CSCRateCalculator()
        calc.ingest(crank(100, 1000), at: 0)
        XCTAssertNil(calc.cadenceRPM, "First notification is a baseline only")
        // 3 revolutions in 2048 ticks (2 s) = 90 RPM.
        calc.ingest(crank(103, 3048), at: 2)
        XCTAssertEqual(calc.cadenceRPM ?? 0, 90, accuracy: 0.01)
        XCTAssertEqual(calc.crankRevolutions, 3)
    }

    func testCounterAndClockRolloverAreJustDeltas() {
        var calc = CSCRateCalculator()
        calc.ingest(crank(65535, 65000), at: 0)
        // revs wrap 65535 → 1 (+2), time wraps 65000 → 829 (+1365 ticks).
        calc.ingest(crank(1, 829), at: 1.3)
        XCTAssertEqual(calc.cadenceRPM ?? 0, 2.0 * 60 * 1024 / 1365, accuracy: 0.01)
    }

    func testRepeatedEventTimeGoesStaleToZero() {
        var calc = CSCRateCalculator()
        calc.ingest(crank(10, 1000), at: 0)
        calc.ingest(crank(11, 1683), at: 0.7)
        XCTAssertNotNil(calc.cadenceRPM)
        // The sensor keeps notifying the same event: rider stopped pedaling.
        calc.ingest(crank(11, 1683), at: 2)
        XCTAssertGreaterThan(calc.cadenceRPM ?? 0, 0, "Inside the stale window the last rate holds")
        calc.ingest(crank(11, 1683), at: 4)
        XCTAssertEqual(calc.cadenceRPM, 0)
    }

    func testSilentSensorExpiresWithoutNotifications() {
        var calc = CSCRateCalculator()
        calc.ingest(crank(10, 1000), at: 0)
        calc.ingest(crank(11, 1683), at: 0.7)
        calc.expire(now: 10)
        XCTAssertEqual(calc.cadenceRPM, 0, "A sleeping Magene stops notifying entirely")
    }

    func testSensorResetDoesNotSpike() {
        var calc = CSCRateCalculator()
        calc.ingest(crank(10, 1000), at: 0)
        calc.ingest(crank(11, 1683), at: 0.7)
        let before = calc.cadenceRPM
        calc.ingest(crank(900, 2000), at: 1)
        XCTAssertEqual(calc.cadenceRPM, before, "A huge revolution jump re-baselines")
        calc.ingest(crank(901, 2683), at: 1.7)
        XCTAssertEqual(calc.cadenceRPM ?? 0, 60.0 * 1024 / 683, accuracy: 0.01)
    }

    func testWheelSpeedAndDistanceUseCircumference() {
        var calc = CSCRateCalculator(config: .init(wheelCircumferenceMeters: 2.105))
        calc.ingest(wheel(500, 0), at: 0)
        // 4 revolutions in 1 s.
        calc.ingest(wheel(504, 1024), at: 1)
        XCTAssertEqual(calc.wheelSpeedMs ?? 0, 4 * 2.105, accuracy: 0.001)
        XCTAssertEqual(calc.wheelDistanceMeters, 4 * 2.105, accuracy: 0.001)
        calc.expire(now: 5)
        XCTAssertEqual(calc.wheelSpeedMs, 0)
    }

    func testResetBaselinesClearsRatesButKeepsTotals() {
        var calc = CSCRateCalculator()
        calc.ingest(crank(10, 0), at: 0)
        calc.ingest(crank(12, 1365), at: 1.3)
        calc.resetBaselines()
        XCTAssertNil(calc.cadenceRPM)
        XCTAssertEqual(calc.crankRevolutions, 2)
    }

    func testWheelPresetLookup() {
        XCTAssertEqual(WheelSize.matching(mm: 2105), .road700x25)
        XCTAssertNil(WheelSize.matching(mm: 2110))
    }
}

// MARK: - Recording

@MainActor
final class CadenceRecordingTests: XCTestCase {
    private final class StubSensors: CyclingSensorMonitoring {
        var currentCadenceRPM: Double?
        var currentSpeedKmh: Double?
        var cadenceSource: CadenceSource?
        var sensors: [CyclingSensor] = []
        var radioState: SensorRadioState = .ready
        var isScanning = false
        func start(includingAppleWatch: Bool) {}
        func stop() {}
        func startScan() {}
        func stopScan() {}
        func pair(_ id: UUID) {}
        func forget(_ id: UUID) {}
        func setWheelCircumference(meters: Double) {}
    }

    private func makeRecorder(
        sensors: StubSensors?, location: MockLocationService = MockLocationService(coordinate: nil)
    ) -> RideRecorder {
        RideRecorder(
            profile: .testProfile(bikeType: .roadBike),
            routeName: "Cadence test",
            startElevationMeters: nil,
            locationService: location,
            altimeter: MockAltimeter(),
            store: nil,
            fallbackSample: {
                RideRecorder.FallbackSample(
                    coordinate: CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42),
                    speedKmh: 18,
                    altitudeMeters: 10
                )
            },
            cyclingSensors: sensors
        )
    }

    func testSamplesCarryCadenceAndSummaryRollsUp() {
        let sensors = StubSensors()
        let recorder = makeRecorder(sensors: sensors)
        recorder.start()
        let start = Date.now
        let readings: [Double?] = [80, 90, 0, nil, 100]
        for (index, rpm) in readings.enumerated() {
            sensors.currentCadenceRPM = rpm
            recorder.processTick(now: start.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertEqual(recorder.currentCadenceRPM, 100)
        let record = recorder.finish()
        XCTAssertEqual(record.samples.map(\.cadenceRPM), readings)
        XCTAssertEqual(record.summary.averageCadenceRPM ?? 0, 90, accuracy: 0.01,
                       "Pedaling-only: the coasting zero is excluded")
        XCTAssertEqual(record.summary.maxCadenceRPM, 100)
        XCTAssertNotNil(record.summary.totalCrankRevolutions)
    }

    func testRideWithoutCadenceKeepsTotalsNil() {
        let recorder = makeRecorder(sensors: nil)
        recorder.start()
        let start = Date.now
        for second in 0..<4 {
            recorder.processTick(now: start.addingTimeInterval(TimeInterval(second)))
        }
        let record = recorder.finish()
        XCTAssertTrue(record.samples.allSatisfy { $0.cadenceRPM == nil })
        XCTAssertNil(record.summary.averageCadenceRPM)
        XCTAssertNil(record.summary.maxCadenceRPM)
        XCTAssertNil(record.summary.totalCrankRevolutions)
    }

    func testWheelSensorSpeedBeatsGPS() {
        let location = MockLocationService()
        let sensors = StubSensors()
        sensors.currentSpeedKmh = 36
        let recorder = makeRecorder(sensors: sensors, location: location)
        recorder.start()
        let start = Date.now
        for t in 0...30 {
            location.setLocation(
                CLLocationCoordinate2D(latitude: 37.76 + Double(t) * 0.00009, longitude: -122.42),
                speed: 2
            )
            recorder.processTick(now: start.addingTimeInterval(Double(t)))
        }
        XCTAssertEqual(recorder.currentSpeedKmh, 36, accuracy: 1,
                       "GPS says 7 km/h; the wheel sensor's 36 km/h wins")
    }

    func testCadenceTotalsIntegrateRevolutions() {
        var totals = CadenceTotals()
        for t in 0...60 {
            totals.add(RideSample(t: Double(t), latitude: 0, longitude: 0, speedKmh: 20,
                                  distanceMeters: 0, cadenceRPM: 90))
        }
        XCTAssertEqual(totals.revolutions, 90, accuracy: 0.01, "90 RPM for one minute")
        XCTAssertEqual(totals.averageRPM ?? 0, 90, accuracy: 0.01)
    }

    func testCadenceTotalsSkipGapsAndImplausibleValues() {
        var totals = CadenceTotals()
        totals.add(RideSample(t: 0, latitude: 0, longitude: 0, speedKmh: 20, distanceMeters: 0, cadenceRPM: 90))
        totals.add(RideSample(t: 60, latitude: 0, longitude: 0, speedKmh: 20, distanceMeters: 0, cadenceRPM: 90))
        XCTAssertEqual(totals.revolutions, 0, "A 60 s hole isn't integrated")
        totals.add(RideSample(t: 61, latitude: 0, longitude: 0, speedKmh: 20, distanceMeters: 0, cadenceRPM: 400))
        XCTAssertEqual(totals.maxRPM, 90)
    }

    func testLegacyRecordWithoutCadenceKeysDecodes() throws {
        let legacy = """
        {"summary":{"id":"\(UUID().uuidString)","startedAt":700000000.0,
          "routeName":"Old","durationSeconds":600,"movingSeconds":550,
          "distanceMeters":3000,"averageSpeedKmh":19.6,"maxSpeedKmh":32.1,
          "ascentMeters":45,"descentMeters":40,"calories":120,
          "isComplete":true,"averageHeartRateBPM":140,"maxHeartRateBPM":170},
         "samples":[{"t":0,"latitude":37.76,"longitude":-122.42,
           "speedKmh":18,"distanceMeters":0,"heartRateBPM":140}]}
        """.data(using: .utf8)!
        let record = try JSONDecoder().decode(RideRecord.self, from: legacy)
        XCTAssertNil(record.summary.averageCadenceRPM)
        XCTAssertNil(record.samples[0].cadenceRPM)
        XCTAssertEqual(record.summary.averageHeartRateBPM, 140)
    }
}

// MARK: - Health Export

final class HealthCadenceSamplesTests: XCTestCase {
    func testSamplesFoldIntoWindowsClampedToTheRide() {
        let start = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let samples = (0..<12).map { t in
            RideSample(t: Double(t), latitude: 0, longitude: 0, speedKmh: 20, distanceMeters: 0,
                       cadenceRPM: t < 5 ? 80 : (t == 7 ? nil : 90))
        }
        let record = RideRecord(
            summary: RideSummary(
                id: UUID(), startedAt: start, routeName: "W", durationSeconds: 11,
                movingSeconds: 11, distanceMeters: 0, averageSpeedKmh: 0, maxSpeedKmh: 0,
                ascentMeters: 0, descentMeters: 0, calories: 0, isComplete: true
            ),
            samples: samples
        )
        let windows = HealthCadenceSamples.windows(for: record)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].rpm, 80, accuracy: 0.01)
        XCTAssertEqual(windows[1].rpm, 90, accuracy: 0.01, "The nil sample is skipped, not averaged as 0")
        XCTAssertEqual(windows[2].start, start.addingTimeInterval(10))
        XCTAssertEqual(windows[2].end, start.addingTimeInterval(11), "Clamped to the workout's end")
    }

    func testRideWithoutCadenceWritesNothing() {
        let record = RideRecord(
            summary: RideSummary(
                id: UUID(), startedAt: .now, routeName: "W", durationSeconds: 10,
                movingSeconds: 10, distanceMeters: 0, averageSpeedKmh: 0, maxSpeedKmh: 0,
                ascentMeters: 0, descentMeters: 0, calories: 0, isComplete: true
            ),
            samples: [RideSample(t: 0, latitude: 0, longitude: 0, speedKmh: 0, distanceMeters: 0)]
        )
        XCTAssertTrue(HealthCadenceSamples.windows(for: record).isEmpty)
    }
}

// MARK: - Settings Migration & Mock

@MainActor
final class CadenceSettingsTests: XCTestCase {
    func testPreviousDefaultGainsCadenceChip() throws {
        let legacy = """
        {"layoutMode":"standard","largerControlsEnabled":false,
         "highContrastEnabled":false,"metricsPriority":"time",
         "musicTrayDefaultExpanded":false,
         "visibleSecondaryMetrics":["currentGrade","climbRemaining","heartRate"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideScreenCustomization.self, from: legacy)
        XCTAssertTrue(decoded.visibleSecondaryMetrics.contains(.cadence))
    }

    func testCuratedSetDoesNotGainCadence() throws {
        let legacy = """
        {"layoutMode":"standard","largerControlsEnabled":false,
         "highContrastEnabled":false,"metricsPriority":"time",
         "musicTrayDefaultExpanded":false,
         "visibleSecondaryMetrics":["heartRate"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideScreenCustomization.self, from: legacy)
        XCTAssertFalse(decoded.visibleSecondaryMetrics.contains(.cadence))
    }

    func testProfileWithoutWheelSizeDecodesToDefault() throws {
        let data = try JSONEncoder().encode(RiderProfile.testProfile(bikeType: .roadBike))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "wheelCircumferenceMm")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(RiderProfile.self, from: legacy)
        XCTAssertEqual(decoded.wheelCircumferenceMm, 2105)
    }

    func testMockSensorStreamsCadenceUntilForgotten() throws {
        let mock = MockCyclingSensorService(cadenceProvider: { _ in 88 })
        XCTAssertNil(mock.currentCadenceRPM)
        mock.start(includingAppleWatch: true)
        XCTAssertEqual(mock.currentCadenceRPM, 88)
        XCTAssertEqual(mock.cadenceSource, .sensor(name: "Magene S3+"))
        let id = try XCTUnwrap(mock.sensors.first?.id)
        mock.forget(id)
        XCTAssertNil(mock.currentCadenceRPM)
        mock.stop()
    }
}
