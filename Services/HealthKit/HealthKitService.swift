import Foundation
import HealthKit
import CoreLocation
import Observation

// MARK: - HealthKit Service Protocol

/// Write-only Apple Health integration: logs completed rides as workouts so
/// they count toward Activity rings and show up in the Fitness app. LaneLine
/// never requests read access — there's nothing here it needs from Health.
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

    private var shareTypes: Set<HKSampleType> {
        [workoutType, distanceType, energyType, routeType]
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
            try await store.requestAuthorization(toShare: shareTypes, read: [])
            refreshAuthorizationState()
        } catch {
            lastErrorMessage = "Couldn't request Health access."
        }
    }

    func saveWorkout(_ record: RideRecord) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        refreshAuthorizationState()
        guard authorizationState == .authorized else { return }

        let summary = record.summary
        let start = summary.startedAt
        let end = start.addingTimeInterval(summary.durationSeconds)

        let workout = HKWorkout(
            activityType: .cycling,
            start: start,
            end: end,
            duration: summary.movingSeconds,
            totalEnergyBurned: HKQuantity(unit: .kilocalorie(), doubleValue: summary.calories),
            totalDistance: HKQuantity(unit: .meter(), doubleValue: summary.distanceMeters),
            metadata: [HKMetadataKeyIndoorWorkout: false]
        )

        do {
            try await store.save(workout)
            try await saveRoute(for: record, workout: workout)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Couldn't save the ride to Health."
        }
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
            routeBuilder.finishRoute(with: workout, metadata: nil) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private enum HealthKitError: Error { case routeInsertFailed }
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
