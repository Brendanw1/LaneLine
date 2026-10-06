import Foundation
import HealthKit

// MARK: - Health Read Set

/// Everything LaneLine reads from Health during a ride, requested as one
/// set so the rider sees a single permission sheet no matter which stream
/// starts first (HealthKit coalesces identical requests).
enum HealthKitRideStreams {
    static let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    static let cyclingCadence = HKQuantityType.quantityType(forIdentifier: .cyclingCadence)!
    static let perMinute = HKUnit.count().unitDivided(by: .minute())

    static var readTypes: Set<HKObjectType> { [heartRate, cyclingCadence] }
}

// MARK: - Apple Watch Cadence

/// Cadence from the Apple Watch's HealthKit stream. watchOS pairs Bluetooth
/// cycling sensors itself (Settings → Bluetooth on the Watch) and, during a
/// Watch cycling workout, writes `cyclingCadence` samples to Health. BLE
/// speed/cadence pods generally accept one connection at a time, so when
/// the Watch holds the sensor the phone can't — this reader is how that
/// cadence still reaches the ride screen. The direct BLE link wins whenever
/// it has data; see `BluetoothCyclingSensorService`.
@MainActor
final class WatchCadenceReader {
    /// A Watch cadence sample older than this is no reading.
    static let maxSampleAgeSeconds: Double = 30

    private(set) var currentRPM: Double?
    private(set) var lastSampleAt: Date?
    var onUpdate: (@MainActor () -> Void)?

    private let store = HKHealthStore()
    private var observerQuery: HKObserverQuery?
    private var isRunning = false

    func start() async {
        guard !isRunning, HKHealthStore.isHealthDataAvailable() else { return }
        isRunning = true
        do {
            try await store.requestAuthorization(toShare: [], read: HealthKitRideStreams.readTypes)
        } catch {
            isRunning = false
            return
        }
        guard isRunning else { return }   // stopped while the sheet was up
        let query = HKObserverQuery(
            sampleType: HealthKitRideStreams.cyclingCadence, predicate: nil
        ) { [weak self] _, completion, _ in
            Task { @MainActor in
                self?.fetchLatest()
                completion()
            }
        }
        store.execute(query)
        observerQuery = query
        fetchLatest()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let observerQuery { store.stop(observerQuery) }
        observerQuery = nil
        currentRPM = nil
        lastSampleAt = nil
    }

    /// Clears a reading that has aged out (called from the sensor tick).
    func expire(now: Date = .now) {
        if let lastSampleAt, now.timeIntervalSince(lastSampleAt) > Self.maxSampleAgeSeconds {
            currentRPM = nil
            self.lastSampleAt = nil
        }
    }

    private func fetchLatest() {
        guard isRunning else { return }
        let predicate = HKQuery.predicateForSamples(
            withStart: Date.now.addingTimeInterval(-Self.maxSampleAgeSeconds), end: nil
        )
        let query = HKSampleQuery(
            sampleType: HealthKitRideStreams.cyclingCadence,
            predicate: predicate,
            limit: 1,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        ) { [weak self] _, samples, _ in
            Task { @MainActor in
                guard let self, self.isRunning,
                      let sample = samples?.first as? HKQuantitySample else { return }
                self.currentRPM = sample.quantity.doubleValue(for: HealthKitRideStreams.perMinute)
                self.lastSampleAt = sample.endDate
                self.onUpdate?()
            }
        }
        store.execute(query)
    }
}
