import Foundation
import CoreLocation
import Observation

/// Records an active ride: samples position/speed/altitude at ~1 Hz through
/// `RideAggregator`, republishes live totals for the ride screen, and
/// checkpoints to the ride store for crash safety. Navigation stays in
/// `ActiveRideModel`; this type only measures.
@MainActor
@Observable
final class RideRecorder {
    struct FallbackSample {
        var coordinate: CLLocationCoordinate2D
        var speedKmh: Double
        var altitudeMeters: Double?
    }

    // MARK: Live metrics

    private(set) var distanceMeters: Double = 0
    private(set) var elapsedSeconds: Double = 0
    private(set) var movingSeconds: Double = 0
    private(set) var currentSpeedKmh: Double = 0
    private(set) var averageSpeedKmh: Double = 0
    private(set) var maxSpeedKmh: Double = 0
    private(set) var ascentMeters: Double = 0
    private(set) var descentMeters: Double = 0
    private(set) var calories: Double = 0
    private(set) var currentGradeDecimal: Double?
    private(set) var altitudeMeters: Double?
    private(set) var isAutoPaused = false
    private(set) var isPaused = false
    private(set) var isRecording = false

    // MARK: Internals

    private var aggregator: RideAggregator
    private var samples: [RideSample] = []
    private var startDate = Date.now
    /// Time excluded by manual pauses; ride-clock t = wall time − this.
    private var pausedOffsetSeconds: Double = 0
    private var pauseBeganAt: Date?
    private var gpsAltitudeAnchor: Double?
    private var ticksSinceCheckpoint = 0
    private var tickTask: Task<Void, Never>?

    private let summaryID = UUID()
    private let routeName: String
    private let startElevationMeters: Double?
    private let locationService: any LocationServicing
    private let altimeter: any AltitudeProviding
    private let store: (any RideStoring)?
    private let fallbackSample: () -> FallbackSample?
    private let tickInterval: Double

    /// A fix older than this is stale: fall back or record a gap. Staleness
    /// is a wall-clock property of the fix, so it is measured against
    /// `Date.now`, not the (test-injectable) tick clock.
    private let fixFreshnessSeconds: Double = 5
    /// Checkpoint the in-progress ride this often (ticks ≈ seconds).
    private let checkpointEveryTicks = 60

    init(
        profile: RiderProfile,
        routeName: String,
        startElevationMeters: Double?,
        locationService: any LocationServicing,
        altimeter: any AltitudeProviding,
        store: (any RideStoring)?,
        fallbackSample: @escaping () -> FallbackSample? = { nil },
        tickInterval: Double = 1.0
    ) {
        self.aggregator = RideAggregator(profile: profile)
        self.routeName = routeName
        self.startElevationMeters = startElevationMeters
        self.locationService = locationService
        self.altimeter = altimeter
        self.store = store
        self.fallbackSample = fallbackSample
        self.tickInterval = tickInterval
    }

    // MARK: Lifecycle

    func start() {
        guard !isRecording else { return }
        isRecording = true
        startDate = .now
        altimeter.start()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.tickInterval ?? 1))
                guard let self, self.isRecording else { break }
                self.processTick(now: .now)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        if paused {
            pauseBeganAt = .now
        } else if let began = pauseBeganAt {
            pausedOffsetSeconds += Date.now.timeIntervalSince(began)
            pauseBeganAt = nil
        }
    }

    /// Stops recording and returns the finished record. Idempotent.
    func finish() -> RideRecord {
        if isRecording {
            isRecording = false
            tickTask?.cancel()
            altimeter.stop()
        }
        return record(complete: true)
    }

    // MARK: Measurement

    /// One measurement step. The tick loop calls this every second; tests
    /// call it directly with a controlled clock.
    func processTick(now: Date) {
        guard isRecording, !isPaused else { return }
        let rideClock = now.timeIntervalSince(startDate) - pausedOffsetSeconds

        let input: RideAggregator.Input?
        if let location = locationService.currentLocation,
           Date.now.timeIntervalSince(location.timestamp) < fixFreshnessSeconds {
            input = RideAggregator.Input(
                timestamp: rideClock,
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                altitudeMeters: resolvedAltitude(gps: location),
                speedMs: location.speed >= 0 ? location.speed : nil
            )
        } else if let fallback = fallbackSample() {
            input = RideAggregator.Input(
                timestamp: rideClock,
                latitude: fallback.coordinate.latitude,
                longitude: fallback.coordinate.longitude,
                altitudeMeters: fallback.altitudeMeters ?? resolvedAltitude(gps: nil),
                speedMs: fallback.speedKmh / 3.6
            )
        } else {
            input = nil   // no position at all — a gap, not a sample
        }
        guard let input else { return }

        samples.append(aggregator.ingest(input))
        publishTotals()
        checkpointIfDue()
    }

    // MARK: Internals

    /// Barometer first (anchored to the route's start elevation), GPS
    /// altitude as fallback.
    private func resolvedAltitude(gps: CLLocation?) -> Double? {
        if let relative = altimeter.relativeAltitudeMeters {
            let anchor = startElevationMeters ?? gpsAltitudeAnchor ?? 0
            return anchor + relative
        }
        guard let gps, gps.verticalAccuracy >= 0 else { return nil }
        if gpsAltitudeAnchor == nil { gpsAltitudeAnchor = gps.altitude }
        return gps.altitude
    }

    private func publishTotals() {
        let totals = aggregator.totals
        distanceMeters = totals.distanceMeters
        elapsedSeconds = totals.elapsedSeconds
        movingSeconds = totals.movingSeconds
        currentSpeedKmh = totals.speedMs * 3.6
        averageSpeedKmh = totals.averageSpeedMs * 3.6
        maxSpeedKmh = totals.maxSpeedMs * 3.6
        ascentMeters = totals.ascentMeters
        descentMeters = totals.descentMeters
        calories = totals.kilocalories
        currentGradeDecimal = totals.gradeDecimal
        altitudeMeters = totals.altitudeMeters
        isAutoPaused = totals.isAutoPaused
    }

    private func checkpointIfDue() {
        ticksSinceCheckpoint += 1
        guard ticksSinceCheckpoint >= checkpointEveryTicks, let store else { return }
        ticksSinceCheckpoint = 0
        let snapshot = record(complete: false)
        Task { await store.checkpoint(snapshot) }
    }

    private func record(complete: Bool) -> RideRecord {
        let summary = RideSummary(
            id: summaryID,
            startedAt: startDate,
            routeName: routeName,
            durationSeconds: elapsedSeconds,
            movingSeconds: movingSeconds,
            distanceMeters: distanceMeters,
            averageSpeedKmh: averageSpeedKmh,
            maxSpeedKmh: maxSpeedKmh,
            ascentMeters: ascentMeters,
            descentMeters: descentMeters,
            calories: calories,
            isComplete: complete
        )
        return RideRecord(summary: summary, samples: samples)
    }
}
