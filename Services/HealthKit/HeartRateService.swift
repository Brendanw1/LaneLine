import Foundation
import HealthKit
import Observation

// MARK: - Heart Rate Monitoring Protocol

/// Live heart rate during a ride. On a real device this reads the Apple
/// Watch's stream: while the Watch is recording a workout (or the rider
/// wears it with a workout active) beats land in HealthKit every few
/// seconds, and an observer query surfaces them here. No watchOS app of
/// our own is required — this deliberately rides on the HealthKit pipe.
/// `currentBPM` is nil until a fresh sample exists, so the UI can hide the
/// metric entirely instead of showing a dead zero.
@MainActor
protocol HeartRateMonitoring: AnyObject, Observable {
    /// Latest fresh beats-per-minute reading, or nil.
    var currentBPM: Double? { get }
    /// True once Health read access for heart rate is granted.
    var isAuthorized: Bool { get }
    /// A stream was seen at some point this ride (used to keep the summary
    /// honest when the Watch disconnects mid-ride).
    var hasReceivedSamples: Bool { get }

    func start() async
    func stop()
}

// MARK: - Sample Freshness

enum HeartRateFreshness {
    /// A reading older than this is treated as no reading: a stale BPM on a
    /// moving ride screen is worse than none.
    static let maxSampleAgeSeconds: Double = 60

    static func isFresh(_ sample: HKQuantitySample, now: Date = .now) -> Bool {
        now.timeIntervalSince(sample.endDate) <= maxSampleAgeSeconds
    }

    static func beatsPerMinute(_ sample: HKQuantitySample) -> Double {
        sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
    }
}

// MARK: - Live HealthKit Implementation

@MainActor
@Observable
final class HealthKitHeartRateService: HeartRateMonitoring {
    private(set) var currentBPM: Double?
    private(set) var isAuthorized = false
    private(set) var hasReceivedSamples = false

    private let store = HKHealthStore()
    private var observerQuery: HKObserverQuery?
    private var isMonitoring = false

    private var heartRateType: HKQuantityType {
        HKQuantityType.quantityType(forIdentifier: .heartRate)!
    }

    func start() async {
        guard !isMonitoring else { return }
        guard HKHealthStore.isHealthDataAvailable() else { return }
        isMonitoring = true

        do {
            try await store.requestAuthorization(toShare: [], read: [heartRateType])
        } catch {
            return
        }
        isAuthorized = store.authorizationStatus(for: heartRateType) == .sharingAuthorized

        let query = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] _, completion, _ in
            Task { @MainActor in
                self?.fetchLatest()
                completion()
            }
        }
        store.execute(query)
        observerQuery = query
        // The observer only fires on *new* samples; pick up anything already
        // sitting in the store so a ride started after the Watch began
        // recording shows a reading immediately.
        fetchLatest()
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        if let observerQuery {
            store.stop(observerQuery)
        }
        observerQuery = nil
    }

    /// Newest heart-rate sample within the freshness window. Runs on each
    /// observer delivery (MainActor via the observer's Task hop); HealthKit
    /// serializes deliveries, so no query overlap to guard against.
    private func fetchLatest() {
        guard isMonitoring else { return }
        let predicate = HKQuery.predicateForSamples(
            withStart: Date.now.addingTimeInterval(-HeartRateFreshness.maxSampleAgeSeconds),
            end: nil
        )
        let query = HKSampleQuery(
            sampleType: heartRateType,
            predicate: predicate,
            limit: 1,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
        ) { [weak self] _, samples, _ in
            Task { @MainActor in
                guard let sample = samples?.first as? HKQuantitySample else { return }
                self?.hasReceivedSamples = true
                self?.currentBPM = HeartRateFreshness.beatsPerMinute(sample)
            }
        }
        store.execute(query)
    }
}

// MARK: - Preview / Demo / Test Mock

/// Simulates the Watch's stream: a plausible riding heart rate drifting in
/// a slow sinusoid around 150 BPM. `bpmProvider` overrides the waveform for
/// tests that need exact values.
@MainActor
@Observable
final class MockHeartRateService: HeartRateMonitoring {
    private(set) var currentBPM: Double?
    private(set) var isAuthorized: Bool
    private(set) var hasReceivedSamples = false

    private var startedAt: Date?
    private var timer: Timer?
    private let bpmProvider: ((TimeInterval) -> Double?)?

    init(authorized: Bool = true, bpmProvider: ((TimeInterval) -> Double?)? = nil) {
        self.isAuthorized = authorized
        self.bpmProvider = bpmProvider
    }

    func start() async {
        guard isAuthorized, timer == nil else { return }
        startedAt = .now
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        currentBPM = nil
    }

    /// Real heart rate isn't constant — the mock breathes with a slow
    /// sinusoid (±10 BPM around 150, ~90 s period) so the demo chip visibly
    /// responds over a ride.
    private func tick() {
        guard let startedAt else { return }
        if let provider = bpmProvider {
            currentBPM = provider(Date.now.timeIntervalSince(startedAt))
        } else {
            let phase = Date.now.timeIntervalSince(startedAt) * (2 * .pi / 90)
            currentBPM = 150 + 10 * sin(phase)
        }
        if currentBPM != nil { hasReceivedSamples = true }
    }
}
