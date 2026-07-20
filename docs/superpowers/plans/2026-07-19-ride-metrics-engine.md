# Ride Metrics Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Real, measured ride statistics (speed, averages, elevation, grade, calories) on customizable bike-computer data pages, with completed rides persisted and browsable in a history tab.

**Architecture:** A pure `RideAggregator` (deterministic math, fully unit-tested) is driven by a per-ride `RideRecorder` (`@Observable`, 1 Hz tick, GPS + barometer inputs, demo fallback). Rides persist through a `RideStore` actor (one JSON file per ride + summaries index in Application Support). The ride screen becomes a horizontal pager: page 0 is the existing navigation view untouched, pages 1+ render metric-ID-driven data grids. Spec: `docs/superpowers/specs/2026-07-19-ride-metrics-engine-design.md`.

**Tech Stack:** Swift 5.10, SwiftUI, iOS 17+, CoreLocation, CoreMotion (CMAltimeter), Swift Charts, XCTest. No third-party dependencies.

## Global Constraints

- iOS 17.0 deployment target, Swift 5.10, SwiftUI-first (from `project.yml`).
- The Xcode project is **generated**: after creating or deleting files, run `xcodegen generate` before building.
- Build command: `xcodebuild build -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5` — expect `BUILD SUCCEEDED`.
- Test command (scoped): `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LaneLineTests/<TestClass> 2>&1 | tail -15`.
- Metric units only (km/h, m, kcal) — matches the rest of the app.
- Services are protocol-typed and injected via `ServiceContainer`; previews/tests substitute mocks through initializers, never separate code paths.
- All existing 28 tests must keep passing.
- **Commit messages must NOT include a Co-Authored-By trailer** (project owner's explicit preference).
- Design tokens: use `LaneLineDesign.Colors/Typography/Spacing/CornerRadius/HitTarget` (all referenced tokens below exist today).

---

### Task 1: Rider weight + calorie power model

**Files:**
- Modify: `Models/RiderProfile.swift`
- Create: `Services/RideRecording/CyclingPowerModel.swift`
- Modify: `Features/Settings/SettingsView.swift` (riderProfileSection, ~line 27)
- Test: `Tests/CyclingPowerModelTests.swift`

**Interfaces:**
- Consumes: `BikeType` (existing enum: `.roadBike, .hybridFitness, .gravel, .cityBike, .eBike`).
- Produces: `RiderProfile.weightKg: Double` (default 75, decode-safe for old blobs); `CyclingPowerModel.mechanicalWatts(speedMs:gradeDecimal:riderKg:bikeType:) -> Double`; `CyclingPowerModel.kilocalories(mechanicalJoules:) -> Double`. Task 3 consumes both.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CyclingPowerModelTests.swift`:

```swift
import XCTest
@testable import LaneLine

final class CyclingPowerModelTests: XCTestCase {
    // 20 km/h on the flat, 75 kg rider on a road bike: rolling + aero only,
    // should land in the easy-spin band.
    func testFlatCruisePowerIsPlausible() {
        let watts = CyclingPowerModel.mechanicalWatts(
            speedMs: 20 / 3.6, gradeDecimal: 0, riderKg: 75, bikeType: .roadBike
        )
        XCTAssertGreaterThan(watts, 40)
        XCTAssertLessThan(watts, 80)
    }

    // 8 km/h up an 8% grade: climbing power dominates.
    func testClimbingPowerIsPlausible() {
        let watts = CyclingPowerModel.mechanicalWatts(
            speedMs: 8 / 3.6, gradeDecimal: 0.08, riderKg: 75, bikeType: .roadBike
        )
        XCTAssertGreaterThan(watts, 120)
        XCTAssertLessThan(watts, 220)
    }

    // Steep descent demands no pedaling.
    func testDescendingPowerIsZero() {
        let watts = CyclingPowerModel.mechanicalWatts(
            speedMs: 30 / 3.6, gradeDecimal: -0.08, riderKg: 75, bikeType: .roadBike
        )
        XCTAssertEqual(watts, 0)
    }

    // The motor shoulders half the load on an e-bike.
    func testEBikeRiderPowerIsBelowCityBike() {
        let ebike = CyclingPowerModel.mechanicalWatts(
            speedMs: 20 / 3.6, gradeDecimal: 0, riderKg: 75, bikeType: .eBike
        )
        let city = CyclingPowerModel.mechanicalWatts(
            speedMs: 20 / 3.6, gradeDecimal: 0, riderKg: 75, bikeType: .cityBike
        )
        XCTAssertLessThan(ebike, city * 0.7)
    }

    // ~1 kJ of mechanical work ≈ 1 kcal metabolic (the classic cycling rule).
    func testKilocalorieConversion() {
        XCTAssertEqual(CyclingPowerModel.kilocalories(mechanicalJoules: 1004.16), 1, accuracy: 0.01)
    }

    // Profiles saved before weightKg existed must decode with the default.
    func testLegacyProfileDecodesWithDefaultWeight() throws {
        let legacy = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"B","bikeType":"roadBike",
         "hillTolerance":"moderate","safetyPreference":"moderate",
         "directnessPreference":"balanced","surfaceSensitivity":"moderate",
         "appleMusicEnabled":false}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(RiderProfile.self, from: legacy)
        XCTAssertEqual(profile.weightKg, 75)
        XCTAssertEqual(profile.name, "B")
    }

    func testProfileWeightRoundTrips() throws {
        var profile = RiderProfile()
        profile.weightKg = 82
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(RiderProfile.self, from: data)
        XCTAssertEqual(decoded.weightKg, 82)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LaneLineTests/CyclingPowerModelTests 2>&1 | tail -15`
Expected: BUILD FAILS — `CyclingPowerModel` not found, `weightKg` not a member.

- [ ] **Step 3: Add `weightKg` to RiderProfile**

In `Models/RiderProfile.swift`, add the property after `defaultRidePlaylistID`, extend the memberwise init, and add a custom decoder (encoding stays synthesized):

```swift
    var defaultRidePlaylistID: String?
    /// Used for calorie estimation; kilograms.
    var weightKg: Double
```

Add `weightKg: Double = 75` as the last init parameter and `self.weightKg = weightKg` in the body. Then add inside the struct:

```swift
    /// Custom decoding so profiles saved before `weightKg` existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bikeType = try c.decode(BikeType.self, forKey: .bikeType)
        hillTolerance = try c.decode(HillTolerance.self, forKey: .hillTolerance)
        safetyPreference = try c.decode(SafetyPreference.self, forKey: .safetyPreference)
        directnessPreference = try c.decode(DirectnessPreference.self, forKey: .directnessPreference)
        surfaceSensitivity = try c.decode(SurfaceSensitivity.self, forKey: .surfaceSensitivity)
        appleMusicEnabled = try c.decode(Bool.self, forKey: .appleMusicEnabled)
        defaultRidePlaylistID = try c.decodeIfPresent(String.self, forKey: .defaultRidePlaylistID)
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg) ?? 75
    }
```

(`CodingKeys` stays compiler-synthesized; defining `init(from:)` does not suppress it.)

- [ ] **Step 4: Create CyclingPowerModel**

Create `Services/RideRecording/CyclingPowerModel.swift`:

```swift
import Foundation

/// Physics-based pedaling power: rolling resistance + aero drag + climbing,
/// from speed, grade, rider weight, and per-bike-type constants. Drives
/// calorie estimation until real power meters arrive (BLE phase).
enum CyclingPowerModel {
    private static let airDensityKgM3 = 1.225
    private static let gravity = 9.81

    /// Bike mass in kg, including typical lock/cargo load.
    static func bikeMassKg(_ type: BikeType) -> Double {
        switch type {
        case .roadBike: return 9
        case .hybridFitness: return 12
        case .gravel: return 10
        case .cityBike: return 15
        case .eBike: return 23
        }
    }

    /// Drag coefficient × frontal area (CdA, m²) for the typical riding
    /// position on each bike type.
    static func dragAreaM2(_ type: BikeType) -> Double {
        switch type {
        case .roadBike: return 0.36
        case .hybridFitness: return 0.45
        case .gravel: return 0.40
        case .cityBike: return 0.55
        case .eBike: return 0.50
        }
    }

    /// Rolling resistance coefficient for typical tires on asphalt.
    static func rollingResistance(_ type: BikeType) -> Double {
        switch type {
        case .roadBike: return 0.004
        case .hybridFitness: return 0.006
        case .gravel: return 0.008
        case .cityBike: return 0.007
        case .eBike: return 0.007
        }
    }

    /// The share of total power the rider provides; the motor covers the
    /// rest on an e-bike.
    private static func riderShare(_ type: BikeType) -> Double {
        type == .eBike ? 0.5 : 1.0
    }

    /// Mechanical watts the rider produces. Zero when coasting — descents
    /// can demand no pedaling.
    static func mechanicalWatts(
        speedMs: Double, gradeDecimal: Double, riderKg: Double, bikeType: BikeType
    ) -> Double {
        guard speedMs > 0 else { return 0 }
        let massKg = riderKg + bikeMassKg(bikeType)
        let rolling = rollingResistance(bikeType) * massKg * gravity * speedMs
        let aero = 0.5 * airDensityKgM3 * dragAreaM2(bikeType) * pow(speedMs, 3)
        let climbing = massKg * gravity * speedMs * gradeDecimal
        return max(0, (rolling + aero + climbing) * riderShare(bikeType))
    }

    /// Mechanical joules → metabolic kilocalories at ~24 % efficiency.
    static func kilocalories(mechanicalJoules: Double) -> Double {
        mechanicalJoules / (4184 * 0.24)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodegen generate && xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LaneLineTests/CyclingPowerModelTests 2>&1 | tail -15`
Expected: `Test Suite 'CyclingPowerModelTests' passed` (7 tests).

- [ ] **Step 6: Add the weight row in Settings**

In `Features/Settings/SettingsView.swift`, inside `riderProfileSection` after the "Surface pickiness" picker, add:

```swift
            Stepper(value: profileBinding(\.weightKg), in: 40...150, step: 1) {
                HStack {
                    Text("Weight")
                    Spacer()
                    Text("\(Int(appModel.riderProfile.weightKg)) kg")
                        .foregroundStyle(.secondary)
                }
            }
```

(`profileBinding` is the existing generic helper at the bottom of the file — verify its name matches before use.)

- [ ] **Step 7: Build**

Run the build command from Global Constraints. Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Models/RiderProfile.swift Services/RideRecording/CyclingPowerModel.swift Features/Settings/SettingsView.swift Tests/CyclingPowerModelTests.swift
git commit -m "Rider weight and physics-based cycling power model"
```

---

### Task 2: Ride record models + RideStore

**Files:**
- Create: `Models/RideRecordModels.swift`
- Create: `Services/RideRecording/RideStore.swift`
- Modify: `Core/ServiceContainer.swift`
- Test: `Tests/RideStoreTests.swift`

**Interfaces:**
- Produces (consumed by Tasks 3, 4, 10, 11):

```swift
struct RideSample: Codable, Equatable {
    var t: Double            // seconds since ride start
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
    var speedKmh: Double
    var distanceMeters: Double   // cumulative
    var gradeDecimal: Double?
}

struct RideSummary: Identifiable, Codable, Equatable {
    let id: UUID
    var startedAt: Date
    var routeName: String
    var durationSeconds: Double
    var movingSeconds: Double
    var distanceMeters: Double
    var averageSpeedKmh: Double
    var maxSpeedKmh: Double
    var ascentMeters: Double
    var descentMeters: Double
    var calories: Double
    var isComplete: Bool     // false for checkpoint-only (interrupted) rides
}

struct RideRecord: Identifiable, Codable, Equatable {
    var summary: RideSummary
    var samples: [RideSample]
    var id: UUID { summary.id }
}

protocol RideStoring: Sendable {
    func save(_ record: RideRecord) async throws
    func checkpoint(_ record: RideRecord) async   // crash-safety write, errors swallowed
    func loadSummaries() async -> [RideSummary]   // newest first
    func loadRecord(id: UUID) async -> RideRecord?
    func delete(id: UUID) async
}
```

- `ServiceContainer` gains `let rideStore: any RideStoring` (init param, default `RideStore()`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/RideStoreTests.swift`:

```swift
import XCTest
@testable import LaneLine

final class RideStoreTests: XCTestCase {
    private var directory: URL!
    private var store: RideStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = RideStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeRecord(name: String = "Test ride", complete: Bool = true) -> RideRecord {
        let summary = RideSummary(
            id: UUID(), startedAt: .now, routeName: name,
            durationSeconds: 600, movingSeconds: 550, distanceMeters: 3000,
            averageSpeedKmh: 19.6, maxSpeedKmh: 32.1, ascentMeters: 45,
            descentMeters: 40, calories: 120, isComplete: complete
        )
        let samples = (0..<10).map {
            RideSample(t: Double($0), latitude: 37.76, longitude: -122.42,
                       altitudeMeters: 10, speedKmh: 18,
                       distanceMeters: Double($0) * 5, gradeDecimal: 0)
        }
        return RideRecord(summary: summary, samples: samples)
    }

    func testSaveAndLoadRoundTrip() async throws {
        let record = makeRecord()
        try await store.save(record)
        let loaded = await store.loadRecord(id: record.id)
        XCTAssertEqual(loaded, record)
    }

    func testSummariesIndexNewestFirst() async throws {
        var old = makeRecord(name: "Old")
        old.summary.startedAt = Date(timeIntervalSinceNow: -3600)
        let new = makeRecord(name: "New")
        try await store.save(old)
        try await store.save(new)
        let summaries = await store.loadSummaries()
        XCTAssertEqual(summaries.map(\.routeName), ["New", "Old"])
    }

    func testCheckpointThenFinalSaveKeepsOneEntry() async throws {
        var record = makeRecord(complete: false)
        await store.checkpoint(record)
        record.summary.isComplete = true
        try await store.save(record)
        let summaries = await store.loadSummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(summaries[0].isComplete)
    }

    func testDeleteRemovesRecordAndSummary() async throws {
        let record = makeRecord()
        try await store.save(record)
        await store.delete(id: record.id)
        let summaries = await store.loadSummaries()
        let loaded = await store.loadRecord(id: record.id)
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertNil(loaded)
    }

    func testEmptyStoreListsNothing() async {
        let summaries = await store.loadSummaries()
        XCTAssertTrue(summaries.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LaneLineTests/RideStoreTests 2>&1 | tail -15`
Expected: BUILD FAILS — `RideStore`, `RideRecord` not found.

- [ ] **Step 3: Create the models**

Create `Models/RideRecordModels.swift` with `RideSample`, `RideSummary`, and `RideRecord` exactly as in the Interfaces block above (plain structs, no extra logic).

- [ ] **Step 4: Create RideStore**

Create `Services/RideRecording/RideStore.swift`:

```swift
import Foundation

// MARK: - Ride Store Protocol

protocol RideStoring: Sendable {
    func save(_ record: RideRecord) async throws
    /// Crash-safety write of an in-progress ride; failures are swallowed —
    /// a checkpoint must never interrupt a ride.
    func checkpoint(_ record: RideRecord) async
    /// Newest first.
    func loadSummaries() async -> [RideSummary]
    func loadRecord(id: UUID) async -> RideRecord?
    func delete(id: UUID) async
}

// MARK: - File-backed implementation

/// One JSON file per ride plus a summaries index for fast history listing.
/// Sample logs grow far beyond what UserDefaults should hold, so rides live
/// in Application Support/Rides; tests inject a temp directory.
actor RideStore: RideStoring {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rides", isDirectory: true)
    }

    func save(_ record: RideRecord) async throws {
        try ensureDirectory()
        let data = try encoder.encode(record)
        try data.write(to: recordURL(record.id), options: .atomic)
        var summaries = await loadSummaries().filter { $0.id != record.id }
        summaries.append(record.summary)
        summaries.sort { $0.startedAt > $1.startedAt }
        try writeIndex(summaries)
    }

    func checkpoint(_ record: RideRecord) async {
        try? await save(record)
    }

    func loadSummaries() async -> [RideSummary] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? decoder.decode([RideSummary].self, from: data)) ?? []
    }

    func loadRecord(id: UUID) async -> RideRecord? {
        guard let data = try? Data(contentsOf: recordURL(id)) else { return nil }
        return try? decoder.decode(RideRecord.self, from: data)
    }

    func delete(id: UUID) async {
        try? FileManager.default.removeItem(at: recordURL(id))
        let remaining = await loadSummaries().filter { $0.id != id }
        try? writeIndex(remaining)
    }

    // MARK: Internals

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private var indexURL: URL {
        directory.appendingPathComponent("summaries.json")
    }

    private func writeIndex(_ summaries: [RideSummary]) throws {
        try ensureDirectory()
        try encoder.encode(summaries).write(to: indexURL, options: .atomic)
    }
}
```

- [ ] **Step 5: Register in ServiceContainer**

In `Core/ServiceContainer.swift`: add `let rideStore: any RideStoring` after `persistenceService`; add init parameter `rideStore: any RideStoring = RideStore()` and `self.rideStore = rideStore` in the body.

- [ ] **Step 6: Run tests to verify they pass**

Run the Step 2 command. Expected: `Test Suite 'RideStoreTests' passed` (5 tests).

- [ ] **Step 7: Commit**

```bash
git add Models/RideRecordModels.swift Services/RideRecording/RideStore.swift Core/ServiceContainer.swift Tests/RideStoreTests.swift
git commit -m "Ride record models and file-backed ride store"
```

---

### Task 3: RideAggregator — the pure metrics math

**Files:**
- Create: `Services/RideRecording/RideAggregator.swift`
- Test: `Tests/RideAggregatorTests.swift`

**Interfaces:**
- Consumes: `RideSample` (Task 2), `CyclingPowerModel` + `RiderProfile.weightKg` (Task 1), `GeoMath.distanceMeters(from:to:)` (existing, takes two `CLLocationCoordinate2D`).
- Produces (consumed by Task 4):

```swift
struct RideAggregator {
    struct Config {
        var speedSmoothingSeconds: Double = 3
        var autoPauseBelowMs: Double = 1.0
        var autoPauseAfterSeconds: Double = 3
        var ascentHysteresisMeters: Double = 2
        var gradeWindowMeters: Double = 20
        var maxPlausibleJumpMeters: Double = 100
        var maxGradeDecimal: Double = 0.25
    }
    struct Input {
        var timestamp: Double        // seconds since ride start
        var latitude: Double
        var longitude: Double
        var altitudeMeters: Double?
        var speedMs: Double?         // nil → derived from position deltas
    }
    struct Totals: Equatable {
        var distanceMeters: Double
        var elapsedSeconds: Double
        var movingSeconds: Double
        var speedMs: Double          // smoothed current
        var maxSpeedMs: Double
        var ascentMeters: Double
        var descentMeters: Double
        var kilocalories: Double
        var gradeDecimal: Double?
        var altitudeMeters: Double?
        var isAutoPaused: Bool
        var averageSpeedMs: Double   // distance / moving time
    }
    private(set) var totals: Totals
    init(profile: RiderProfile, config: Config = Config())
    mutating func ingest(_ input: Input) -> RideSample
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/RideAggregatorTests.swift`:

```swift
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

    func testGradeOverTrailingWindow() {
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
```

Note the `try` in `testGradeOverTrailingWindow` — mark that method `throws`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LaneLineTests/RideAggregatorTests 2>&1 | tail -15`
Expected: BUILD FAILS — `RideAggregator` not found.

- [ ] **Step 3: Implement RideAggregator**

Create `Services/RideRecording/RideAggregator.swift`:

```swift
import Foundation
import CoreLocation

/// Pure ride-statistics math. Fed one positional input at a time (~1 Hz), it
/// maintains running totals using bike-computer conventions: auto-pause
/// below walking speed, hysteresis on climbing, gap-tolerant distance.
/// No timers, no services — fully deterministic for tests.
struct RideAggregator {
    struct Config {
        var speedSmoothingSeconds: Double = 3
        var autoPauseBelowMs: Double = 1.0
        var autoPauseAfterSeconds: Double = 3
        var ascentHysteresisMeters: Double = 2
        var gradeWindowMeters: Double = 20
        var maxPlausibleJumpMeters: Double = 100
        var maxGradeDecimal: Double = 0.25
    }

    struct Input {
        var timestamp: Double        // seconds since ride start
        var latitude: Double
        var longitude: Double
        var altitudeMeters: Double?
        var speedMs: Double?         // nil → derived from position deltas
    }

    struct Totals: Equatable {
        var distanceMeters: Double = 0
        var elapsedSeconds: Double = 0
        var movingSeconds: Double = 0
        var speedMs: Double = 0
        var maxSpeedMs: Double = 0
        var ascentMeters: Double = 0
        var descentMeters: Double = 0
        var kilocalories: Double = 0
        var gradeDecimal: Double?
        var altitudeMeters: Double?
        var isAutoPaused = false

        var averageSpeedMs: Double {
            movingSeconds > 0 ? distanceMeters / movingSeconds : 0
        }
    }

    private(set) var totals = Totals()

    private let profile: RiderProfile
    private let config: Config
    private var last: Input?
    private var slowSeconds: Double = 0
    /// Hysteresis reference: ascent/descent commit only when altitude moves
    /// more than the band away from this anchor.
    private var referenceAltitude: Double?
    /// Trailing (cumulative distance, altitude) points for grade.
    private var gradeTrail: [(distance: Double, altitude: Double)] = []

    init(profile: RiderProfile, config: Config = Config()) {
        self.profile = profile
        self.config = config
    }

    mutating func ingest(_ input: Input) -> RideSample {
        defer { last = input }

        guard let previous = last else {
            // First fix establishes baselines only.
            totals.speedMs = max(0, input.speedMs ?? 0)
            if let altitude = input.altitudeMeters {
                referenceAltitude = altitude
                totals.altitudeMeters = altitude
                gradeTrail = [(0, altitude)]
            }
            return sample(for: input)
        }

        let dt = input.timestamp - previous.timestamp
        guard dt > 0 else { return sample(for: input) }
        totals.elapsedSeconds += dt

        // Distance, with a teleport guard: implausible hops accrue nothing.
        let hop = GeoMath.distanceMeters(
            from: CLLocationCoordinate2D(latitude: previous.latitude, longitude: previous.longitude),
            to: CLLocationCoordinate2D(latitude: input.latitude, longitude: input.longitude)
        )
        let accepted = hop > config.maxPlausibleJumpMeters ? 0 : hop

        // Speed: reported when available, else positional; EMA-smoothed.
        let instantaneous = max(0, input.speedMs ?? (accepted / dt))
        let alpha = dt / (config.speedSmoothingSeconds + dt)
        totals.speedMs += alpha * (instantaneous - totals.speedMs)

        // Auto-pause state updates before time accrual.
        if totals.speedMs < config.autoPauseBelowMs {
            slowSeconds += dt
            if slowSeconds >= config.autoPauseAfterSeconds { totals.isAutoPaused = true }
        } else {
            slowSeconds = 0
            totals.isAutoPaused = false
        }

        totals.distanceMeters += accepted
        if !totals.isAutoPaused {
            totals.movingSeconds += dt
            totals.maxSpeedMs = max(totals.maxSpeedMs, totals.speedMs)
        }

        updateElevation(input.altitudeMeters)
        updateCalories(dt: dt)
        return sample(for: input)
    }

    // MARK: Internals

    private mutating func updateElevation(_ altitude: Double?) {
        guard let altitude else { return }
        totals.altitudeMeters = altitude

        guard let reference = referenceAltitude else {
            referenceAltitude = altitude
            gradeTrail = [(totals.distanceMeters, altitude)]
            return
        }
        let delta = altitude - reference
        if delta >= config.ascentHysteresisMeters {
            totals.ascentMeters += delta
            referenceAltitude = altitude
        } else if delta <= -config.ascentHysteresisMeters {
            totals.descentMeters += -delta
            referenceAltitude = altitude
        }

        // Grade over the trailing window: keep the most recent point that is
        // still a full window behind as the slope base.
        gradeTrail.append((totals.distanceMeters, altitude))
        while gradeTrail.count >= 2,
              totals.distanceMeters - gradeTrail[1].distance >= config.gradeWindowMeters {
            gradeTrail.removeFirst()
        }
        let base = gradeTrail[0]
        let run = totals.distanceMeters - base.distance
        if run >= config.gradeWindowMeters {
            let raw = (altitude - base.altitude) / run
            totals.gradeDecimal = min(config.maxGradeDecimal, max(-config.maxGradeDecimal, raw))
        }
    }

    private mutating func updateCalories(dt: Double) {
        guard !totals.isAutoPaused else { return }
        let watts = CyclingPowerModel.mechanicalWatts(
            speedMs: totals.speedMs,
            gradeDecimal: totals.gradeDecimal ?? 0,
            riderKg: profile.weightKg,
            bikeType: profile.bikeType
        )
        totals.kilocalories += CyclingPowerModel.kilocalories(mechanicalJoules: watts * dt)
    }

    private func sample(for input: Input) -> RideSample {
        RideSample(
            t: input.timestamp,
            latitude: input.latitude,
            longitude: input.longitude,
            altitudeMeters: totals.altitudeMeters,
            speedKmh: totals.speedMs * 3.6,
            distanceMeters: totals.distanceMeters,
            gradeDecimal: totals.gradeDecimal
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command. Expected: `Test Suite 'RideAggregatorTests' passed` (9 tests). If `testAutoPauseStopsMovingClock` is flaky on the bound, check the EMA decay math rather than loosening the assertion.

- [ ] **Step 5: Commit**

```bash
git add Services/RideRecording/RideAggregator.swift Tests/RideAggregatorTests.swift
git commit -m "RideAggregator: pure bike-computer metrics math"
```

---

### Task 4: AltimeterService + RideRecorder

**Files:**
- Create: `Services/RideRecording/AltimeterService.swift`
- Create: `Services/RideRecording/RideRecorder.swift`
- Modify: `project.yml` (Info.plist properties)
- Test: `Tests/RideRecorderTests.swift`

**Interfaces:**
- Consumes: `RideAggregator` (Task 3), `RideStoring`/`RideRecord` (Task 2), `LocationServicing` + `MockLocationService.setLocation(_:heading:)` (existing).
- Produces (consumed by Tasks 5, 7, 8, 10):

```swift
@MainActor protocol AltitudeProviding: AnyObject {
    var relativeAltitudeMeters: Double? { get }
    func start()
    func stop()
}
@MainActor final class AltimeterService: AltitudeProviding   // CMAltimeter-backed
@MainActor final class MockAltimeter: AltitudeProviding      // settable, for tests/previews

@MainActor @Observable final class RideRecorder {
    struct FallbackSample {
        var coordinate: CLLocationCoordinate2D
        var speedKmh: Double
        var altitudeMeters: Double?
    }
    // Live metrics (read by the metric catalog and ride screen):
    private(set) var distanceMeters, elapsedSeconds, movingSeconds: Double
    private(set) var currentSpeedKmh, averageSpeedKmh, maxSpeedKmh: Double
    private(set) var ascentMeters, descentMeters, calories: Double
    private(set) var currentGradeDecimal: Double?
    private(set) var altitudeMeters: Double?
    private(set) var isAutoPaused, isPaused, isRecording: Bool
    init(profile: RiderProfile, routeName: String, startElevationMeters: Double?,
         locationService: any LocationServicing, altimeter: any AltitudeProviding,
         store: (any RideStoring)?, fallbackSample: @escaping () -> FallbackSample? = { nil },
         tickInterval: Double = 1.0)
    func start()
    func setPaused(_ paused: Bool)
    func finish() -> RideRecord            // idempotent
    func processTick(now: Date)            // deterministic core; tests drive it directly
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/RideRecorderTests.swift`:

```swift
import XCTest
import CoreLocation
@testable import LaneLine

@MainActor
final class RideRecorderTests: XCTestCase {
    private func makeRecorder(
        location: MockLocationService,
        altimeter: MockAltimeter = MockAltimeter(),
        startElevation: Double? = 10
    ) -> RideRecorder {
        RideRecorder(
            profile: .testProfile(bikeType: .roadBike),
            routeName: "Test route",
            startElevationMeters: startElevation,
            locationService: location,
            altimeter: altimeter,
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
```

Note: manual pause skips ingestion entirely, so on resume the aggregator sees one large `dt` from the pre-pause timestamp. That is why `RideRecorder` must rebase its internal clock on resume — covered in Step 3.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LaneLineTests/RideRecorderTests 2>&1 | tail -15`
Expected: BUILD FAILS — `RideRecorder`, `MockAltimeter` not found.

- [ ] **Step 3: Implement AltimeterService and RideRecorder**

Create `Services/RideRecording/AltimeterService.swift`:

```swift
import Foundation
import CoreMotion
import Observation

// MARK: - Altitude Provider Protocol

/// Barometric altitude change since `start()`. Nil when the device has no
/// barometer (or Motion access is denied) — callers fall back to GPS.
@MainActor
protocol AltitudeProviding: AnyObject {
    var relativeAltitudeMeters: Double? { get }
    func start()
    func stop()
}

// MARK: - CMAltimeter implementation

@MainActor
@Observable
final class AltimeterService: AltitudeProviding {
    private(set) var relativeAltitudeMeters: Double?
    private let altimeter = CMAltimeter()

    func start() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            Task { @MainActor in
                self?.relativeAltitudeMeters = data.relativeAltitude.doubleValue
            }
        }
    }

    func stop() {
        altimeter.stopRelativeAltitudeUpdates()
        relativeAltitudeMeters = nil
    }
}

// MARK: - Mock

@MainActor
@Observable
final class MockAltimeter: AltitudeProviding {
    var relativeAltitudeMeters: Double?
    func start() {}
    func stop() {}
}
```

Create `Services/RideRecording/RideRecorder.swift`:

```swift
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

    /// A fix older than this is stale: fall back or record a gap.
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
           now.timeIntervalSince(location.timestamp) < fixFreshnessSeconds {
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
```

- [ ] **Step 4: Add the Motion usage string**

In `project.yml`, under `targets.LaneLine.info.properties`, after `NSLocationWhenInUseUsageDescription`, add:

```yaml
        NSMotionUsageDescription: >-
          LaneLine uses the barometer to measure climbing and descent
          accurately during rides.
```

- [ ] **Step 5: Run tests to verify they pass**

Run the Step 2 command (it regenerates the project, picking up the plist change). Expected: `Test Suite 'RideRecorderTests' passed` (5 tests).

- [ ] **Step 6: Commit**

```bash
git add Services/RideRecording/AltimeterService.swift Services/RideRecording/RideRecorder.swift project.yml Tests/RideRecorderTests.swift
git commit -m "RideRecorder: 1 Hz ride sampling with barometric altitude and demo fallback"
```

---

### Task 5: Formatters, RideMetricID, and the metric catalog

**Files:**
- Modify: `Core/Formatters.swift`
- Create: `Models/RideMetrics.swift`
- Create: `Features/Navigation/RideMetricCatalog.swift`
- Test: `Tests/RideMetricCatalogTests.swift`

**Interfaces:**
- Consumes: `RideRecorder` (Task 4), `ActiveRideModel` (existing: `remainingMeters`, `etaSeconds`, `climbRemainingMeters`, `currentGrade`), `RideFormat` (existing).
- Produces (consumed by Tasks 6, 7, 8):

```swift
// Core/Formatters.swift additions
static func speedValue(_ kmh: Double) -> String      // "18.4"
static func stopwatch(_ seconds: Double) -> String   // "1:02:45" or "12:05"
static func wholeNumber(_ value: Double) -> String   // "412"

// Models/RideMetrics.swift
enum RideMetricID: String, Codable, CaseIterable, Identifiable {
    case currentSpeed, averageSpeed, maxSpeed, distance, distanceRemaining,
         elapsedTime, movingTime, eta, clock, ascent, descent,
         climbRemaining, grade, altitude, calories
    var id: String { rawValue }
    var title: String { ... }
}
struct RideDataPage: Identifiable, Codable, Equatable {
    var id: UUID
    var metrics: [RideMetricID]
    init(id: UUID = UUID(), metrics: [RideMetricID])
    static let maxMetrics = 8
    static func defaultPage() -> RideDataPage
}

// Features/Navigation/RideMetricCatalog.swift
struct RideMetricDisplay: Equatable { let title: String; let unit: String; let value: String }
@MainActor enum RideMetricCatalog {
    static func display(_ id: RideMetricID, recorder: RideRecorder, ride: ActiveRideModel) -> RideMetricDisplay
}
```

- [ ] **Step 1: Write the failing tests**

Create `Tests/RideMetricCatalogTests.swift`:

```swift
import XCTest
import CoreLocation
@testable import LaneLine

@MainActor
final class RideMetricCatalogTests: XCTestCase {
    func testFormatters() {
        XCTAssertEqual(RideFormat.speedValue(18.44), "18.4")
        XCTAssertEqual(RideFormat.speedValue(-2), "0.0")
        XCTAssertEqual(RideFormat.stopwatch(65), "1:05")
        XCTAssertEqual(RideFormat.stopwatch(3725), "1:02:05")
        XCTAssertEqual(RideFormat.wholeNumber(411.6), "412")
    }

    func testDefaultPageFillsTheGrid() {
        let page = RideDataPage.defaultPage()
        XCTAssertEqual(page.metrics.count, RideDataPage.maxMetrics)
        XCTAssertEqual(Set(page.metrics).count, page.metrics.count, "no duplicate metrics")
    }

    func testEveryMetricProducesADisplay() async throws {
        let graph = try await TestGraphs.stressTradeoffGraph()
        let routing = RoutingService(
            geospatialService: StubGeospatialService(graph: graph),
            scoringService: RouteScoringService()
        )
        let ride = ActiveRideModel(
            route: PreviewData.sampleCandidates[0],
            profile: .testProfile(bikeType: .roadBike),
            locationService: MockLocationService(),
            routingService: routing,
            voiceGuide: nil
        )
        let recorder = RideRecorder(
            profile: .testProfile(bikeType: .roadBike),
            routeName: "Test",
            startElevationMeters: 10,
            locationService: MockLocationService(),
            altimeter: MockAltimeter(),
            store: nil
        )
        for id in RideMetricID.allCases {
            let display = RideMetricCatalog.display(id, recorder: recorder, ride: ride)
            XCTAssertFalse(display.title.isEmpty, "\(id) needs a title")
            XCTAssertFalse(display.value.isEmpty, "\(id) needs a value")
        }
    }
}
```

Note: `ActiveRideModel`'s initializer signature is `init(route:profile:locationService:routingService:voiceGuide:)` — verify the parameter labels against `Features/Navigation/ActiveRideModel.swift` before assuming; adjust the test if they differ.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LaneLineTests/RideMetricCatalogTests 2>&1 | tail -15`
Expected: BUILD FAILS — `speedValue`, `RideMetricID` not found.

- [ ] **Step 3: Extend RideFormat**

Add to `Core/Formatters.swift` inside `enum RideFormat`:

```swift
    /// Speed magnitude without unit — data cells show the unit separately.
    static func speedValue(_ kmh: Double) -> String {
        String(format: "%.1f", max(0, kmh))
    }

    /// Ride-timer style: "12:05" under an hour, "1:02:05" over.
    static func stopwatch(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func wholeNumber(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }
```

- [ ] **Step 4: Create RideMetricID and RideDataPage**

Create `Models/RideMetrics.swift`:

```swift
import Foundation

// MARK: - Ride Metric IDs

/// Every metric a data-page cell can show. Later sensor phases (power, HR,
/// cadence, radar) add cases here; pages render purely from IDs, so no
/// layout code changes.
enum RideMetricID: String, Codable, CaseIterable, Identifiable {
    case currentSpeed, averageSpeed, maxSpeed
    case distance, distanceRemaining
    case elapsedTime, movingTime, eta, clock
    case ascent, descent, climbRemaining, grade, altitude
    case calories

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentSpeed: "Speed"
        case .averageSpeed: "Avg speed"
        case .maxSpeed: "Max speed"
        case .distance: "Distance"
        case .distanceRemaining: "Remaining"
        case .elapsedTime: "Elapsed"
        case .movingTime: "Moving time"
        case .eta: "ETA"
        case .clock: "Clock"
        case .ascent: "Ascent"
        case .descent: "Descent"
        case .climbRemaining: "Climb left"
        case .grade: "Grade"
        case .altitude: "Altitude"
        case .calories: "Calories"
        }
    }
}

// MARK: - Data Page Layout

/// One customizable bike-computer page: an ordered grid of metric cells.
struct RideDataPage: Identifiable, Codable, Equatable {
    var id: UUID
    var metrics: [RideMetricID]

    init(id: UUID = UUID(), metrics: [RideMetricID]) {
        self.id = id
        self.metrics = metrics
    }

    static let maxMetrics = 8

    static func defaultPage() -> RideDataPage {
        RideDataPage(metrics: [
            .currentSpeed, .averageSpeed, .distance, .movingTime,
            .ascent, .grade, .calories, .eta,
        ])
    }
}
```

- [ ] **Step 5: Create the catalog**

Create `Features/Navigation/RideMetricCatalog.swift`:

```swift
import Foundation

struct RideMetricDisplay: Equatable {
    let title: String
    let unit: String
    let value: String
}

/// Maps metric IDs to formatted live values from the recorder (measured)
/// and the ride model (route-derived: remaining distance, ETA, climb left).
@MainActor
enum RideMetricCatalog {
    static func display(
        _ id: RideMetricID, recorder: RideRecorder, ride: ActiveRideModel
    ) -> RideMetricDisplay {
        switch id {
        case .currentSpeed:
            make(id, "km/h", RideFormat.speedValue(recorder.currentSpeedKmh))
        case .averageSpeed:
            make(id, "km/h", RideFormat.speedValue(recorder.averageSpeedKmh))
        case .maxSpeed:
            make(id, "km/h", RideFormat.speedValue(recorder.maxSpeedKmh))
        case .distance:
            make(id, "", RideFormat.distance(recorder.distanceMeters))
        case .distanceRemaining:
            make(id, "", RideFormat.distance(ride.remainingMeters))
        case .elapsedTime:
            make(id, "", RideFormat.stopwatch(recorder.elapsedSeconds))
        case .movingTime:
            make(id, "", RideFormat.stopwatch(recorder.movingSeconds))
        case .eta:
            make(id, "", RideFormat.eta(arrivingIn: ride.etaSeconds))
        case .clock:
            make(id, "", Date.now.formatted(date: .omitted, time: .shortened))
        case .ascent:
            make(id, "m", RideFormat.wholeNumber(recorder.ascentMeters))
        case .descent:
            make(id, "m", RideFormat.wholeNumber(recorder.descentMeters))
        case .climbRemaining:
            make(id, "m", RideFormat.wholeNumber(ride.climbRemainingMeters))
        case .grade:
            make(id, "", RideFormat.signedGrade(recorder.currentGradeDecimal ?? ride.currentGrade))
        case .altitude:
            make(id, "m", recorder.altitudeMeters.map(RideFormat.wholeNumber) ?? "—")
        case .calories:
            make(id, "kcal", RideFormat.wholeNumber(recorder.calories))
        }
    }

    private static func make(_ id: RideMetricID, _ unit: String, _ value: String) -> RideMetricDisplay {
        RideMetricDisplay(title: id.title, unit: unit, value: value)
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run the Step 2 command. Expected: `Test Suite 'RideMetricCatalogTests' passed` (3 tests).

- [ ] **Step 7: Commit**

```bash
git add Core/Formatters.swift Models/RideMetrics.swift Features/Navigation/RideMetricCatalog.swift Tests/RideMetricCatalogTests.swift
git commit -m "Ride metric IDs, formatters, and display catalog"
```

---

### Task 6: Data pages on RideScreenCustomization (backward-compatible)

**Files:**
- Modify: `Models/NavigationModels.swift` (`RideScreenCustomization`, lines 79–103)
- Test: `Tests/RideCustomizationCodableTests.swift`

**Interfaces:**
- Consumes: `RideDataPage` (Task 5).
- Produces: `RideScreenCustomization.dataPages: [RideDataPage]` (consumed by Tasks 7, 8); `RideScreenCustomization.maxDataPages = 3`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/RideCustomizationCodableTests.swift`:

```swift
import XCTest
@testable import LaneLine

final class RideCustomizationCodableTests: XCTestCase {
    // Blobs saved before dataPages existed must decode and gain the default page.
    func testLegacyBlobGainsDefaultPage() throws {
        let legacy = """
        {"layoutMode":"standard","largerControlsEnabled":true,
         "highContrastEnabled":false,"metricsPriority":"climb",
         "musicTrayDefaultExpanded":false,
         "visibleSecondaryMetrics":["currentGrade"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideScreenCustomization.self, from: legacy)
        XCTAssertTrue(decoded.largerControlsEnabled)
        XCTAssertEqual(decoded.metricsPriority, .climb)
        XCTAssertEqual(decoded.dataPages.count, 1)
        XCTAssertEqual(decoded.dataPages[0].metrics, RideDataPage.defaultPage().metrics)
    }

    func testDataPagesRoundTrip() throws {
        var customization = RideScreenCustomization.default
        customization.dataPages = [
            RideDataPage(metrics: [.currentSpeed, .grade]),
            RideDataPage(metrics: [.calories]),
        ]
        let data = try JSONEncoder().encode(customization)
        let decoded = try JSONDecoder().decode(RideScreenCustomization.self, from: data)
        XCTAssertEqual(decoded.dataPages, customization.dataPages)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodegen generate && xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LaneLineTests/RideCustomizationCodableTests 2>&1 | tail -15`
Expected: BUILD FAILS — `dataPages` not a member.

- [ ] **Step 3: Add dataPages with tolerant decoding**

In `Models/NavigationModels.swift`, inside `RideScreenCustomization`: add the property after `visibleSecondaryMetrics`, the constant, the custom decoder, and extend `default`:

```swift
    var visibleSecondaryMetrics: Set<SecondaryMetric>
    var dataPages: [RideDataPage]

    static let maxDataPages = 3
```

```swift
    /// Custom decoding so customizations saved before `dataPages` existed
    /// still load (the store falls back to `.default` on decode failure,
    /// which would silently reset the rider's other choices).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layoutMode = try c.decode(LayoutMode.self, forKey: .layoutMode)
        largerControlsEnabled = try c.decode(Bool.self, forKey: .largerControlsEnabled)
        highContrastEnabled = try c.decode(Bool.self, forKey: .highContrastEnabled)
        metricsPriority = try c.decode(MetricsPriority.self, forKey: .metricsPriority)
        musicTrayDefaultExpanded = try c.decode(Bool.self, forKey: .musicTrayDefaultExpanded)
        visibleSecondaryMetrics = try c.decode(Set<SecondaryMetric>.self, forKey: .visibleSecondaryMetrics)
        dataPages = try c.decodeIfPresent([RideDataPage].self, forKey: .dataPages) ?? [.defaultPage()]
    }
```

The memberwise init is compiler-synthesized today; defining `init(from:)` suppresses it, so also add the explicit memberwise init:

```swift
    init(
        layoutMode: LayoutMode,
        largerControlsEnabled: Bool,
        highContrastEnabled: Bool,
        metricsPriority: MetricsPriority,
        musicTrayDefaultExpanded: Bool,
        visibleSecondaryMetrics: Set<SecondaryMetric>,
        dataPages: [RideDataPage] = [.defaultPage()]
    ) {
        self.layoutMode = layoutMode
        self.largerControlsEnabled = largerControlsEnabled
        self.highContrastEnabled = highContrastEnabled
        self.metricsPriority = metricsPriority
        self.musicTrayDefaultExpanded = musicTrayDefaultExpanded
        self.visibleSecondaryMetrics = visibleSecondaryMetrics
        self.dataPages = dataPages
    }
```

(`static let default` keeps compiling unchanged because `dataPages` has a default parameter.)

- [ ] **Step 4: Run tests to verify they pass**

Run the Step 2 command. Expected: `Test Suite 'RideCustomizationCodableTests' passed` (2 tests). Also run the full suite once — `RideCustomizationView` compiles against the struct and must still build:
`xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5` — expect all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Models/NavigationModels.swift Tests/RideCustomizationCodableTests.swift
git commit -m "Customizable data pages on RideScreenCustomization, decode-compatible"
```

---

### Task 7: Ride screen pager, data page view, recorder wiring

**Files:**
- Create: `Features/Navigation/RideDataPageView.swift`
- Modify: `Features/Navigation/ActiveNavigationView.swift`
- Modify: `Features/Navigation/ActiveRideModel.swift` (one computed property)

**Interfaces:**
- Consumes: `RideRecorder` + `AltimeterService` (Task 4), `RideMetricCatalog` (Task 5), `customization.dataPages` (Task 6), `services.rideStore` (Task 2).
- Produces: `ActiveRideModel.currentElevationMeters: Double?` (consumed by the fallback closure); `RideDataPageView(page:recorder:ride:)` (extended in Task 8). `ActiveNavigationView` gains `@State private var recorder: RideRecorder?` and `@State private var pageIndex = 0`.

- [ ] **Step 1: Expose route elevation on ActiveRideModel**

In `Features/Navigation/ActiveRideModel.swift`, in the "Derived metrics" section after `currentHeading`, add:

```swift
    /// Route elevation at the current position — the demo/no-fix fallback
    /// altitude for ride recording.
    var currentElevationMeters: Double? {
        point(at: progressMeters)?.coordinate.elevation
    }
```

- [ ] **Step 2: Create RideDataPageView**

Create `Features/Navigation/RideDataPageView.swift`:

```swift
import SwiftUI

/// One full-screen bike-computer data page: a two-column grid of metric
/// cells driven entirely by metric IDs from `RideScreenCustomization`.
struct RideDataPageView: View {
    let page: RideDataPage
    let recorder: RideRecorder
    let ride: ActiveRideModel

    private let columns = [
        GridItem(.flexible(), spacing: LaneLineDesign.Spacing.small),
        GridItem(.flexible(), spacing: LaneLineDesign.Spacing.small),
    ]

    var body: some View {
        VStack(spacing: LaneLineDesign.Spacing.small) {
            LazyVGrid(columns: columns, spacing: LaneLineDesign.Spacing.small) {
                ForEach(page.metrics) { metric in
                    RideMetricCell(
                        display: RideMetricCatalog.display(metric, recorder: recorder, ride: ride)
                    )
                }
            }
            Spacer()
        }
        .padding(LaneLineDesign.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LaneLineDesign.Colors.background)
    }
}

struct RideMetricCell: View {
    let display: RideMetricDisplay

    var body: some View {
        VStack(spacing: 4) {
            Text(display.value)
                .font(LaneLineDesign.Typography.metricValueLarge)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 4) {
                Text(display.title)
                if !display.unit.isEmpty {
                    Text(display.unit)
                }
            }
            .font(LaneLineDesign.Typography.metricLabel)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 3: Wire the pager and recorder into ActiveNavigationView**

In `Features/Navigation/ActiveNavigationView.swift`:

a. Add state after `@State private var camera`:

```swift
    @State private var recorder: RideRecorder?
    @State private var pageIndex = 0
```

b. Replace the `ZStack` contents in `body` (the `if let ride { rideMap; overlay } else { ProgressView }` block) with:

```swift
            if let ride, let recorder {
                rideMap(ride)
                TabView(selection: $pageIndex) {
                    overlay(ride, recorder)
                        .tag(0)
                    ForEach(Array(customization.dataPages.enumerated()), id: \.element.id) { index, page in
                        RideDataPageView(page: page, recorder: recorder, ride: ride)
                            .tag(index + 1)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView()
            }
```

c. In `.onAppear`, after `ride = model`, create and start the recorder:

```swift
            let rideRecorder = RideRecorder(
                profile: appModel.riderProfile,
                routeName: route.label.isEmpty ? "Ride" : route.label,
                startElevationMeters: route.segments.first?.geometry.first?.elevation,
                locationService: services.locationService,
                altimeter: AltimeterService(),
                store: services.rideStore,
                fallbackSample: { [weak model] in
                    guard let model else { return nil }
                    return RideRecorder.FallbackSample(
                        coordinate: model.currentCoordinate,
                        speedKmh: model.currentSpeedKmh,
                        altitudeMeters: model.currentElevationMeters
                    )
                }
            )
            rideRecorder.start()
            recorder = rideRecorder
```

d. In `.onDisappear`, before `ride?.end()`, add:

```swift
            if let recorder, recorder.isRecording { _ = recorder.finish() }
```

e. Change `overlay(_ ride:)` to `overlay(_ ride: ActiveRideModel, _ recorder: RideRecorder)` and pass the recorder down to `secondaryMetricsRow(ride, recorder)` (change its signature the same way). In `secondaryMetricsRow`, replace the two speed chips' values:
   - `.currentSpeed` chip: `String(format: "%.0f km/h", recorder.currentSpeedKmh)` — measured, not modeled.
   - `.averageSpeed` chip: replace `averageSpeedText(ride)` with `recorder.movingSeconds > 10 ? String(format: "%.0f km/h", recorder.averageSpeedKmh) : "—"`, and delete the now-unused `averageSpeedText(_:)` helper.

f. In `controlsRow`, in the pause button's action, add `recorder?.setPaused(ride.isPaused)` **after** `ride.togglePause()` (so the recorder mirrors the new state).

g. Leave the End button unchanged in this task (the summary flow lands in Task 10).

- [ ] **Step 4: Build and verify the demo ride**

Run: `xcodegen generate && xcodebuild build -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

Then boot a simulator, install, and launch the demo ride:

```bash
xcrun simctl boot "iPhone 17" 2>/dev/null; xcrun simctl install booted <path-to-built-app> && xcrun simctl launch booted com.laneline.LaneLine -demoRide
```

(Find the built app under DerivedData or build with `-derivedDataPath` to control it.) Take a screenshot (`xcrun simctl io booted screenshot /tmp/ride.png`), swipe left is not scriptable — verify visually in the simulator that page dots appear and the data page shows moving numbers driven by the simulated ride.

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Features/Navigation/RideDataPageView.swift Features/Navigation/ActiveNavigationView.swift Features/Navigation/ActiveRideModel.swift
git commit -m "Ride screen pager with live data pages and measured speed"
```

---

### Task 8: Data page edit mode — metric picker, add/remove pages

**Files:**
- Modify: `Features/Navigation/RideDataPageView.swift`
- Modify: `Features/Navigation/ActiveNavigationView.swift`

**Interfaces:**
- Consumes: `appModel.updateCustomization(_:)` (existing), `RideScreenCustomization.maxDataPages` (Task 6), `RideDataPage.maxMetrics` (Task 5).
- Produces: `RideDataPageView` gains `onUpdate: (RideDataPage) -> Void`, `onDeletePage: (() -> Void)?`, `onAddPage: (() -> Void)?`; new `MetricPickerSheet` view.

- [ ] **Step 1: Add edit mode to RideDataPageView**

Replace `Features/Navigation/RideDataPageView.swift` with:

```swift
import SwiftUI

/// One full-screen bike-computer data page: a two-column grid of metric
/// cells driven entirely by metric IDs from `RideScreenCustomization`.
/// Edit mode lets the rider retarget any cell, add/remove cells, and
/// add/remove whole pages; changes persist through `onUpdate`.
struct RideDataPageView: View {
    let page: RideDataPage
    let recorder: RideRecorder
    let ride: ActiveRideModel
    var onUpdate: (RideDataPage) -> Void = { _ in }
    var onDeletePage: (() -> Void)?
    var onAddPage: (() -> Void)?

    @State private var isEditing = false
    @State private var editingSlot: EditingSlot?

    private struct EditingSlot: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private let columns = [
        GridItem(.flexible(), spacing: LaneLineDesign.Spacing.small),
        GridItem(.flexible(), spacing: LaneLineDesign.Spacing.small),
    ]

    var body: some View {
        VStack(spacing: LaneLineDesign.Spacing.small) {
            header
            LazyVGrid(columns: columns, spacing: LaneLineDesign.Spacing.small) {
                ForEach(Array(page.metrics.enumerated()), id: \.offset) { index, metric in
                    cell(for: metric, at: index)
                }
                if isEditing && page.metrics.count < RideDataPage.maxMetrics {
                    addMetricCell
                }
            }
            if isEditing {
                editActions
            }
            Spacer()
        }
        .padding(LaneLineDesign.Spacing.medium)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LaneLineDesign.Colors.background)
        .sheet(item: $editingSlot) { slot in
            MetricPickerSheet(current: page.metrics[slot.index]) { picked in
                var updated = page
                updated.metrics[slot.index] = picked
                onUpdate(updated)
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button {
                isEditing.toggle()
            } label: {
                Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil.circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isEditing ? "Done editing" : "Edit page")
        }
    }

    private func cell(for metric: RideMetricID, at index: Int) -> some View {
        RideMetricCell(
            display: RideMetricCatalog.display(metric, recorder: recorder, ride: ride)
        )
        .overlay(alignment: .topTrailing) {
            if isEditing && page.metrics.count > 1 {
                Button {
                    var updated = page
                    updated.metrics.remove(at: index)
                    onUpdate(updated)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(LaneLineDesign.Colors.danger)
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("Remove \(metric.title)")
            }
        }
        .onTapGesture {
            if isEditing { editingSlot = EditingSlot(index: index) }
        }
    }

    private var addMetricCell: some View {
        Button {
            var updated = page
            updated.metrics.append(firstUnusedMetric)
            onUpdate(updated)
        } label: {
            Image(systemName: "plus")
                .font(.title)
                .frame(maxWidth: .infinity, minHeight: 96)
        }
        .buttonStyle(.plain)
        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .accessibilityLabel("Add metric")
    }

    private var firstUnusedMetric: RideMetricID {
        RideMetricID.allCases.first { !page.metrics.contains($0) } ?? .currentSpeed
    }

    private var editActions: some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            if let onAddPage {
                Button("Add page", systemImage: "plus.rectangle.on.rectangle", action: onAddPage)
            }
            if let onDeletePage {
                Button("Remove page", systemImage: "trash", role: .destructive, action: onDeletePage)
                    .foregroundStyle(LaneLineDesign.Colors.danger)
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
    }
}

// MARK: - Metric Cell

struct RideMetricCell: View {
    let display: RideMetricDisplay

    var body: some View {
        VStack(spacing: 4) {
            Text(display.value)
                .font(LaneLineDesign.Typography.metricValueLarge)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            HStack(spacing: 4) {
                Text(display.title)
                if !display.unit.isEmpty {
                    Text(display.unit)
                }
            }
            .font(LaneLineDesign.Typography.metricLabel)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 96)
        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Metric Picker

struct MetricPickerSheet: View {
    let current: RideMetricID
    let onPick: (RideMetricID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(RideMetricID.allCases) { metric in
                Button {
                    onPick(metric)
                    dismiss()
                } label: {
                    HStack {
                        Text(metric.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if metric == current {
                            Image(systemName: "checkmark")
                                .foregroundStyle(LaneLineDesign.Colors.primary)
                        }
                    }
                }
            }
            .navigationTitle("Choose metric")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
```

- [ ] **Step 2: Wire persistence in ActiveNavigationView**

In the pager's `ForEach` (Task 7 step 3b), pass the new closures:

```swift
                    ForEach(Array(customization.dataPages.enumerated()), id: \.element.id) { index, page in
                        RideDataPageView(
                            page: page,
                            recorder: recorder,
                            ride: ride,
                            onUpdate: { updated in
                                var c = customization
                                c.dataPages[index] = updated
                                appModel.updateCustomization(c)
                            },
                            onDeletePage: customization.dataPages.count > 1 ? {
                                var c = customization
                                c.dataPages.remove(at: index)
                                appModel.updateCustomization(c)
                                pageIndex = min(pageIndex, c.dataPages.count)
                            } : nil,
                            onAddPage: customization.dataPages.count < RideScreenCustomization.maxDataPages ? {
                                var c = customization
                                c.dataPages.append(RideDataPage(metrics: [.currentSpeed]))
                                appModel.updateCustomization(c)
                            } : nil
                        )
                        .tag(index + 1)
                    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED. Launch the demo ride again and verify: pencil → tap a cell → picker swaps the metric; minus removes; plus adds; Add/Remove page work and survive relaunch.

- [ ] **Step 4: Commit**

```bash
git add Features/Navigation/RideDataPageView.swift Features/Navigation/ActiveNavigationView.swift
git commit -m "Editable data pages: metric picker, add/remove cells and pages"
```

---

### Task 9: Reusable elevation chart (extraction refactor)

**Files:**
- Create: `DesignSystem/ElevationChart.swift`
- Modify: `DesignSystem/ElevationProfileView.swift`

**Interfaces:**
- Produces (consumed by Task 10):

```swift
struct ElevationChartPoint: Identifiable {
    let id = UUID()
    let distanceMeters: Double
    let elevationMeters: Double
    let grade: Double
}
struct ElevationChart: View {
    let points: [ElevationChartPoint]
    let accessibilityText: String
}
```

- `ElevationProfileView` keeps its exact public interface (`init(route:)`) and delegates to `ElevationChart` — all existing call sites unchanged.

- [ ] **Step 1: Extract the chart**

Create `DesignSystem/ElevationChart.swift` containing `ElevationChartPoint` and `ElevationChart`. Move the entire `Chart(profile) { … }` body plus the `.chartXAxis`/`.chartYAxis` modifiers from `ElevationProfileView` verbatim, renaming the data source to `points` and replacing the accessibility label with `.accessibilityLabel(accessibilityText)`. Remember `import SwiftUI` and `import Charts`.

- [ ] **Step 2: Delegate from ElevationProfileView**

`ElevationProfileView` keeps its `route` property and private `points` computation (mapping to `ElevationChartPoint` instead of the private `ProfilePoint`, which is deleted), and its `body` becomes:

```swift
    var body: some View {
        ElevationChart(
            points: points,
            accessibilityText: "Elevation profile: \(RideFormat.elevation(route.totalElevationGainMeters)) total climb, "
                + "max grade \(RideFormat.grade(route.maxGrade))"
        )
    }
```

- [ ] **Step 3: Build and run the full suite**

Run: `xcodegen generate && xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED, all tests pass (this is a pure refactor).

- [ ] **Step 4: Commit**

```bash
git add DesignSystem/ElevationChart.swift DesignSystem/ElevationProfileView.swift
git commit -m "Extract reusable ElevationChart from ElevationProfileView"
```

---

### Task 10: Ride summary screen + save/discard flow

**Files:**
- Create: `Features/RideSummary/RideSummaryView.swift`
- Modify: `App/AppModel.swift`
- Modify: `App/LaneLineApp.swift` (RootView)
- Modify: `Features/Navigation/ActiveNavigationView.swift` (End button)

**Interfaces:**
- Consumes: `RideRecord` (Task 2), `ElevationChart` (Task 9), `services.rideStore` (Task 2), `RideFormat` incl. Task 5 additions.
- Produces: `AppModel.pendingRideRecord: RideRecord?`; `AppModel.finishRide(with: RideRecord?)`; `RideSummaryView(record:onSave:onDiscard:)` — with nil actions it renders read-only (Task 11 reuses it).

- [ ] **Step 1: Extend AppModel**

In `App/AppModel.swift`, after `var activeRoute`, add:

```swift
    /// Set when a ride ends; drives the summary cover with save/discard.
    var pendingRideRecord: RideRecord?
    /// A finished ride whose final save failed; drives a retry alert. The
    /// record stays in memory so no data is lost (spec: store failures never
    /// block the ride).
    var failedRideSave: RideRecord?
```

In the "Ride lifecycle" section, add:

```swift
    func finishRide(with record: RideRecord?) {
        activeRoute = nil
        pendingRideRecord = record
    }
```

(`endRide()` stays — previews and any cancel path still use it.)

- [ ] **Step 2: Create RideSummaryView**

Create `Features/RideSummary/RideSummaryView.swift`:

```swift
import SwiftUI
import MapKit

/// Post-ride summary: the recorded track on a map, the totals grid, and the
/// traveled elevation profile. Presented with save/discard at ride end, and
/// read-only (nil actions) from ride history.
struct RideSummaryView: View {
    let record: RideRecord
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?

    private var summary: RideSummary { record.summary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LaneLineDesign.Spacing.medium) {
                    trackMap
                    statsGrid
                    if elevationPoints.count >= 2 {
                        ElevationChart(
                            points: elevationPoints,
                            accessibilityText: "Ride elevation: \(RideFormat.elevation(summary.ascentMeters)) climbed"
                        )
                        .frame(height: 140)
                        .padding(.horizontal, LaneLineDesign.Spacing.medium)
                    }
                }
                .padding(.vertical, LaneLineDesign.Spacing.medium)
            }
            .navigationTitle(summary.routeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onDiscard {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Discard", role: .destructive, action: onDiscard)
                    }
                }
                if let onSave {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save ride", action: onSave)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: Map

    private var trackCoordinates: [CLLocationCoordinate2D] {
        record.samples.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private var trackMap: some View {
        Map {
            MapPolyline(coordinates: trackCoordinates)
                .stroke(
                    LaneLineDesign.Colors.primary,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .padding(.horizontal, LaneLineDesign.Spacing.medium)
        .allowsHitTesting(false)
    }

    // MARK: Stats

    private struct Stat: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var stats: [Stat] {
        [
            Stat(label: "Distance", value: RideFormat.distance(summary.distanceMeters)),
            Stat(label: "Moving time", value: RideFormat.stopwatch(summary.movingSeconds)),
            Stat(label: "Elapsed", value: RideFormat.stopwatch(summary.durationSeconds)),
            Stat(label: "Avg speed", value: "\(RideFormat.speedValue(summary.averageSpeedKmh)) km/h"),
            Stat(label: "Max speed", value: "\(RideFormat.speedValue(summary.maxSpeedKmh)) km/h"),
            Stat(label: "Ascent", value: RideFormat.elevation(summary.ascentMeters)),
            Stat(label: "Descent", value: RideFormat.elevation(summary.descentMeters)),
            Stat(label: "Calories", value: "\(RideFormat.wholeNumber(summary.calories)) kcal"),
        ]
    }

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: LaneLineDesign.Spacing.small
        ) {
            ForEach(stats) { stat in
                VStack(spacing: 2) {
                    Text(stat.value)
                        .font(LaneLineDesign.Typography.metricValue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(stat.label)
                        .font(LaneLineDesign.Typography.metricLabel)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(
                    LaneLineDesign.Colors.surface,
                    in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium)
                )
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, LaneLineDesign.Spacing.medium)
    }

    // MARK: Elevation

    private var elevationPoints: [ElevationChartPoint] {
        let withAltitude = record.samples.filter { $0.altitudeMeters != nil }
        return withAltitude.map {
            ElevationChartPoint(
                distanceMeters: $0.distanceMeters,
                elevationMeters: $0.altitudeMeters ?? 0,
                grade: $0.gradeDecimal ?? 0
            )
        }
    }
}
```

- [ ] **Step 3: Present the summary from RootView**

In `App/LaneLineApp.swift`, in `RootView`, after the existing `.fullScreenCover(item: $appModel.activeRoute)`, add:

```swift
        .fullScreenCover(item: $appModel.pendingRideRecord) { record in
            RideSummaryView(
                record: completed(record),
                onSave: {
                    let final = completed(record)
                    appModel.pendingRideRecord = nil
                    Task {
                        do { try await services.rideStore.save(final) }
                        catch { appModel.failedRideSave = final }
                    }
                },
                onDiscard: {
                    Task { await services.rideStore.delete(id: record.id) }
                    appModel.pendingRideRecord = nil
                }
            )
        }
        .alert(
            "Couldn't save your ride",
            isPresented: Binding(
                get: { appModel.failedRideSave != nil },
                set: { if !$0 { appModel.failedRideSave = nil } }
            )
        ) {
            Button("Try again") {
                guard let record = appModel.failedRideSave else { return }
                appModel.failedRideSave = nil
                Task {
                    do { try await services.rideStore.save(record) }
                    catch { appModel.failedRideSave = record }
                }
            }
            Button("Discard", role: .cancel) { appModel.failedRideSave = nil }
        } message: {
            Text("The ride couldn't be written to storage. It is still in memory — try again, or discard it.")
        }
```

and add a small helper in `RootView`:

```swift
    /// Rides shown at ride end are complete regardless of checkpoint state.
    private func completed(_ record: RideRecord) -> RideRecord {
        var record = record
        record.summary.isComplete = true
        return record
    }
```

- [ ] **Step 4: Route the End button through finishRide**

In `Features/Navigation/ActiveNavigationView.swift`, in `controlsRow`, replace the End button's action:

```swift
            Button {
                ride.end()
                let record = recorder?.finish()
                appModel.finishRide(with: record)
            } label: { … unchanged … }
```

(The `onDisappear` guard from Task 7 keeps covering the no-End dismissal path because `finish()` is idempotent.)

- [ ] **Step 5: Build, demo, full suite**

Run the build; launch `-demoRide`; ride a few seconds, hit End — the summary must appear with a drawn track, non-zero stats, and Save/Discard. Then run the full test suite. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Features/RideSummary/RideSummaryView.swift App/AppModel.swift App/LaneLineApp.swift Features/Navigation/ActiveNavigationView.swift
git commit -m "Ride summary screen with save/discard at ride end"
```

---

### Task 11: Ride history tab

**Files:**
- Create: `Features/RideHistory/RideHistoryView.swift`
- Modify: `App/LaneLineApp.swift` (MainTabView)

**Interfaces:**
- Consumes: `services.rideStore` (Task 2), `RideSummaryView` read-only mode (Task 10), `RideFormat`.
- Produces: `RideHistoryView` tab.

- [ ] **Step 1: Create RideHistoryView**

Create `Features/RideHistory/RideHistoryView.swift`:

```swift
import SwiftUI

/// Recorded rides, newest first. Rows open the stored ride's summary
/// read-only; swipe to delete.
struct RideHistoryView: View {
    @Environment(\.services) private var services

    @State private var summaries: [RideSummary] = []
    @State private var selectedRecord: RideRecord?

    var body: some View {
        NavigationStack {
            Group {
                if summaries.isEmpty {
                    ContentUnavailableView(
                        "No rides yet",
                        systemImage: "bicycle",
                        description: Text("Finish a ride and save it to see it here.")
                    )
                } else {
                    List {
                        ForEach(summaries) { summary in
                            Button {
                                Task {
                                    selectedRecord = await services.rideStore.loadRecord(id: summary.id)
                                }
                            } label: {
                                row(summary)
                            }
                        }
                        .onDelete { offsets in
                            let doomed = offsets.map { summaries[$0] }
                            summaries.remove(atOffsets: offsets)
                            Task {
                                for summary in doomed {
                                    await services.rideStore.delete(id: summary.id)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Rides")
            .task { await reload() }
            .refreshable { await reload() }
            .sheet(item: $selectedRecord) { record in
                RideSummaryView(record: record)
            }
        }
    }

    private func reload() async {
        summaries = await services.rideStore.loadSummaries()
    }

    private func row(_ summary: RideSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(summary.routeName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if !summary.isComplete {
                    Text("Interrupted")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            LaneLineDesign.Colors.warning.opacity(0.2),
                            in: Capsule()
                        )
                        .foregroundStyle(LaneLineDesign.Colors.warning)
                }
                Spacer()
                Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(
                "\(RideFormat.distance(summary.distanceMeters))  ·  "
                + "\(RideFormat.stopwatch(summary.movingSeconds))  ·  "
                + "↑ \(RideFormat.elevation(summary.ascentMeters))"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    RideHistoryView()
        .serviceContainer(.preview())
}
```

- [ ] **Step 2: Add the tab**

In `App/LaneLineApp.swift`, in `MainTabView`, between the Places and Settings tabs, add:

```swift
            RideHistoryView()
                .tabItem { Label("Rides", systemImage: "clock.arrow.circlepath") }
```

- [ ] **Step 3: Build, verify, full suite**

`xcodegen generate`, build, launch the demo ride, End → Save, then open the Rides tab: the ride must be listed and open read-only (no Save/Discard buttons). Swipe-delete must remove it. Run the full test suite — all pass.

- [ ] **Step 4: Commit**

```bash
git add Features/RideHistory/RideHistoryView.swift App/LaneLineApp.swift
git commit -m "Ride history tab with read-only summaries and delete"
```

---

### Task 12: Documentation + final verification

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update README**

In `README.md`:

a. In the Architecture tree, add under `Services/`:

```
  RideRecording/    RideRecorder (1 Hz sampling), RideAggregator (pure metrics
                    math), CyclingPowerModel (calorie physics), RideStore
                    (JSON-per-ride persistence), AltimeterService (barometer)
```

and extend the `Features/` line's flow list with `RideSummary, RideHistory`.

b. Add rows to the "Real vs. mocked" table:

```
| Ride statistics (speed, elevation, calories) | Real: GPS + barometer through `RideAggregator`; physics-based calorie model; demo mode feeds the same pipeline from the simulated position |
| Ride recording | Real file-backed `RideStore` (JSON per ride + summaries index in Application Support), 60 s crash checkpoints |
```

c. In the "Run it on your phone" first-install list, add motion permission to item 2: "Grant location, motion, and media permissions when the app asks."

- [ ] **Step 2: Full suite + build, one last time**

```bash
xcodegen generate && xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17' 2>&1 | tail -5
```

Expected: all tests pass (28 existing + ~26 new).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document ride recording architecture and stats pipeline"
```
