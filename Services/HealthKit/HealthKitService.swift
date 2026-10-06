import Foundation
import HealthKit
import CoreLocation
import Observation

// MARK: - HealthKit Service Protocol

/// Write-side Apple Health integration: logs completed rides as workouts so
/// they count toward Activity rings and show up in the Fitness app. Reading
/// (live heart rate from the Watch's stream) lives in HeartRateService.
@MainActor
protocol HealthKitServicing: AnyObject, Observable {
    var authorizationState: HealthKitAuthorizationState { get }
    var lastErrorMessage: String? { get }

    func requestAuthorization() async
    /// Re-check share authorization without prompting.
    func refreshAuthorizationState()
    func saveWorkout(_ record: RideRecord) async
}

// MARK: - Live HealthKit Implementation

@MainActor
@Observable
final class HealthKitService: HealthKitServicing {
    private(set) var authorizationState: HealthKitAuthorizationState = .notDetermined
    private(set) var lastErrorMessage: String?

    private let store = HKHealthStore()
    private let workoutType = HKObjectType.workoutType()
    private let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceCycling)!
    private let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let routeType = HKSeriesType.workoutRoute()
    private let cadenceType = HealthKitRideStreams.cyclingCadence

    /// The core workout types; authorization state reflects only these, so
    /// a rider who connected Health before cadence existed keeps logging
    /// rides while the cadence permission is still undecided.
    private var shareTypes: Set<HKSampleType> {
        [workoutType, distanceType, energyType, routeType]
    }

    /// Core types plus sensor streams written alongside the workout.
    private var requestedShareTypes: Set<HKSampleType> {
        shareTypes.union([cadenceType])
    }

    init() {
        refreshAuthorizationState()
    }

    func refreshAuthorizationState() {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .denied
            return
        }
        let statuses = shareTypes.map { store.authorizationStatus(for: $0) }
        if statuses.allSatisfy({ $0 == .sharingAuthorized }) {
            authorizationState = .authorized
        } else if statuses.contains(where: { $0 == .notDetermined }) {
            authorizationState = .notDetermined
        } else {
            authorizationState = .denied
        }
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastErrorMessage = "Health data isn't available on this device."
            authorizationState = .denied
            return
        }
        do {
            try await store.requestAuthorization(toShare: requestedShareTypes, read: [])
            refreshAuthorizationState()
        } catch {
            lastErrorMessage = "Couldn't request Health access."
        }
    }

    func saveWorkout(_ record: RideRecord) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        refreshAuthorizationState()
        if authorizationState == .denied {
            lastErrorMessage = "Log rides to Health is on, but access was denied — rides aren't being logged."
            return
        }
        guard authorizationState == .authorized else { return }

        let summary = record.summary
        let start = summary.startedAt
        let end = start.addingTimeInterval(summary.durationSeconds)

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .cycling
        configuration.locationType = .outdoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: nil)

        do {
            try await builder.beginCollection(at: start)
            try await builder.addMetadata([HKMetadataKeyIndoorWorkout: false])
            // Totals are explicit samples on the builder — the deprecated
            // HKWorkout.init folded distance/energy into the workout itself.
            if summary.distanceMeters > 0 {
                try await builder.addSamples([HKQuantitySample(
                    type: distanceType,
                    quantity: HKQuantity(unit: .meter(), doubleValue: summary.distanceMeters),
                    start: start,
                    end: end
                )])
            }
            // Best-effort: a cadence write problem must not cost the workout.
            try? await addCadenceSamples(for: record, to: builder)
            if summary.calories > 0 {
                try await builder.addSamples([HKQuantitySample(
                    type: energyType,
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: summary.calories),
                    start: start,
                    end: end
                )])
            }
            try await builder.endCollection(at: end)
            guard let workout = try await builder.finishWorkout() else {
                lastErrorMessage = "Couldn't save the ride to Health."
                return
            }
            lastErrorMessage = nil
            do {
                try await saveRoute(for: record, workout: workout)
            } catch {
                lastErrorMessage = "Ride saved to Health, but its route map didn't attach."
            }
        } catch {
            lastErrorMessage = "Couldn't save the ride to Health."
        }
    }

    /// Sensor cadence as `cyclingCadence` samples on the workout, so the
    /// Fitness app shows the cadence trace next to the Watch's heart rate.
    /// Riders who granted Health before cadence existed see a one-time
    /// prompt for just this type the first time a cadence ride is saved;
    /// declining it still saves the workout.
    private func addCadenceSamples(for record: RideRecord, to builder: HKWorkoutBuilder) async throws {
        let windows = HealthCadenceSamples.windows(for: record)
        guard !windows.isEmpty else { return }
        if store.authorizationStatus(for: cadenceType) == .notDetermined {
            try? await store.requestAuthorization(toShare: [cadenceType], read: [])
        }
        guard store.authorizationStatus(for: cadenceType) == .sharingAuthorized else { return }
        let samples = windows.map { window in
            HKQuantitySample(
                type: cadenceType,
                quantity: HKQuantity(unit: HealthKitRideStreams.perMinute, doubleValue: window.rpm),
                start: window.start,
                end: window.end
            )
        }
        try await builder.addSamples(samples)
    }

    /// Route data is a separate write from the workout itself — best-effort;
    /// the workout (distance/calories/duration) is already saved by the time
    /// this runs, so a route failure shouldn't be reported as the whole save
    /// having failed.
    private func saveRoute(for record: RideRecord, workout: HKWorkout) async throws {
        guard record.samples.count >= 2 else { return }
        let start = record.summary.startedAt
        let locations = record.samples.map { sample in
            CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: sample.latitude, longitude: sample.longitude),
                altitude: sample.altitudeMeters ?? 0,
                horizontalAccuracy: 10,
                verticalAccuracy: sample.altitudeMeters == nil ? -1 : 10,
                course: -1,
                speed: sample.speedKmh / 3.6,
                timestamp: start.addingTimeInterval(sample.t)
            )
        }

        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            routeBuilder.insertRouteData(locations) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if !success { continuation.resume(throwing: HealthKitError.routeInsertFailed) }
                else { continuation.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            routeBuilder.finishRoute(with: workout, metadata: nil) { route, error in
                if let error { continuation.resume(throwing: error) }
                else if route == nil { continuation.resume(throwing: HealthKitError.routeFinishFailed) }
                else { continuation.resume() }
            }
        }
    }

    private enum HealthKitError: Error { case routeInsertFailed, routeFinishFailed }
}

// MARK: - Cadence Windows

/// Folds a ride's ~1 Hz cadence samples into fixed windows for Health —
/// a 2-hour ride becomes ~1,400 samples instead of 7,200, the same
/// resolution the Watch itself writes. Windows with no cadence (no source,
/// or a GPS gap) are skipped; coasting zeros are kept so the trace shows
/// where the rider freewheeled.
enum HealthCadenceSamples {
    struct Window: Equatable {
        let start: Date
        let end: Date
        let rpm: Double
    }

    static func windows(for record: RideRecord, windowSeconds: Double = 5) -> [Window] {
        guard windowSeconds > 0 else { return [] }
        let origin = record.summary.startedAt
        // Samples must sit inside the workout interval the builder saves.
        let rideEnd = origin.addingTimeInterval(record.summary.durationSeconds)
        var buckets: [Int: (sum: Double, count: Int)] = [:]
        for sample in record.samples {
            guard let rpm = sample.cadenceRPM, rpm >= 0, sample.t >= 0 else { continue }
            let key = Int(sample.t / windowSeconds)
            let bucket = buckets[key] ?? (0, 0)
            buckets[key] = (bucket.sum + rpm, bucket.count + 1)
        }
        return buckets.keys.sorted().compactMap { key in
            guard let bucket = buckets[key], bucket.count > 0 else { return nil }
            let start = origin.addingTimeInterval(Double(key) * windowSeconds)
            let end = min(start.addingTimeInterval(windowSeconds), rideEnd)
            guard end > start else { return nil }
            return Window(start: start, end: end, rpm: bucket.sum / Double(bucket.count))
        }
    }
}

// MARK: - Preview / Simulator Mock

/// Deterministic stand-in for previews and tests — never touches the real
/// Health store.
@MainActor
@Observable
final class MockHealthKitService: HealthKitServicing {
    private(set) var authorizationState: HealthKitAuthorizationState
    private(set) var lastErrorMessage: String?

    init(authorizationState: HealthKitAuthorizationState = .notDetermined) {
        self.authorizationState = authorizationState
    }

    func requestAuthorization() async {
        authorizationState = .authorized
    }

    func refreshAuthorizationState() {}

    func saveWorkout(_ record: RideRecord) async {}
}
