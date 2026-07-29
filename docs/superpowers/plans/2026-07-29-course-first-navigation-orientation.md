# Course-First Navigation Orientation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the live-navigation map/puck orientation follow real GPS travel direction (course) while moving, falling back to compass heading only when slow/stopped, with smoothing that kills jitter without lagging real turns — plus a follow-suspend/recenter mechanism so the camera stops fighting manual pans.

**Architecture:** A new standalone, unit-testable `NavigationOrientationEngine` (course/heading/route-bearing fusion state machine) replaces `ActiveRideModel`'s private heading logic; generic angle math moves into the existing `Core/GeoMath.swift`. `LocationServicing` gains one new published value (`currentHeadingAccuracy`) so the engine can apply its own configurable trust threshold. `ActiveNavigationView` gains gesture-aware follow-suspend by diffing the map's settled camera against the last camera it commanded itself.

**Tech Stack:** Swift 5.10, SwiftUI, MapKit (`Map`, `MapCamera`, `onMapCameraChange`), CoreLocation (`CLLocation.course`/`.speed`/`.courseAccuracy`, `CLHeading.headingAccuracy`), XCTest.

## Global Constraints

- Deployment target iOS 17.0 — `onMapCameraChange(frequency:)` and the full `CLLocation` initializer with course/courseAccuracy/speed/speedAccuracy are both available at this floor; no availability guards needed.
- Spec doc: `docs/superpowers/specs/2026-07-29-course-first-navigation-orientation-design.md` — every task below implements a specific section of it.
- No Info.plist or entitlement changes anywhere in this plan.
- Voice guidance (`RideVoiceGuide`, `RideAnnouncements`, `updateAnnouncements()`) is not touched by any task.
- No `Co-Authored-By` trailer on any commit (standing project convention).
- Never stage or touch the untracked `data_to_explore/` directory.
- Version bump (`CFBundleShortVersionString`/`CFBundleVersion` in `project.yml`) happens once, in the final task, not per-task.
- Test command throughout: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/<TestClassName>` for a single new test class, and the same command without `-only-testing` for the full suite in the final task.

---

### Task 1: Angle utilities in `GeoMath`

**Files:**
- Modify: `Core/GeoMath.swift`
- Test: `Tests/GeoMathAngleTests.swift` (create)

**Interfaces:**
- Produces: `GeoMath.normalizedDegrees(_ degrees: Double) -> Double`, `GeoMath.interpolatedAngle(from: Double, to: Double, fraction: Double) -> Double`. Both reuse the existing `GeoMath.turnAngleDegrees(fromBearing:toBearing:)` (already in this file) rather than duplicating shortest-angle-delta math.

- [ ] **Step 1: Write the failing tests**

Create `Tests/GeoMathAngleTests.swift`:

```swift
import XCTest
@testable import LaneLine

final class GeoMathAngleTests: XCTestCase {
    func testNormalizedDegreesWrapsPositiveOverflow() {
        XCTAssertEqual(GeoMath.normalizedDegrees(370), 10, accuracy: 0.0001)
    }

    func testNormalizedDegreesWrapsNegativeValues() {
        XCTAssertEqual(GeoMath.normalizedDegrees(-10), 350, accuracy: 0.0001)
    }

    func testNormalizedDegreesHandlesMultiLapMagnitudes() {
        XCTAssertEqual(GeoMath.normalizedDegrees(725), 5, accuracy: 0.0001)
    }

    func testTurnAngleTakesShortestPathAcrossWraparound() {
        // 359 -> 1 should read as +2 (short way through 0), not -358.
        XCTAssertEqual(GeoMath.turnAngleDegrees(fromBearing: 359, toBearing: 1), 2, accuracy: 0.0001)
    }

    func testInterpolatedAngleStepsTheShortWayAcrossWraparound() {
        let result = GeoMath.interpolatedAngle(from: 359, to: 1, fraction: 0.5)
        XCTAssertEqual(result, 0, accuracy: 0.0001)
    }

    func testInterpolatedAngleAtZeroFractionStaysPut() {
        XCTAssertEqual(GeoMath.interpolatedAngle(from: 45, to: 200, fraction: 0), 45, accuracy: 0.0001)
    }

    func testInterpolatedAngleAtFullFractionReachesTarget() {
        let result = GeoMath.interpolatedAngle(from: 45, to: 200, fraction: 1)
        XCTAssertEqual(result, 200, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/GeoMathAngleTests`
Expected: FAIL / build error — `normalizedDegrees` and `interpolatedAngle` are not members of `GeoMath`.

- [ ] **Step 3: Implement the two functions**

In `Core/GeoMath.swift`, add these two static functions to `enum GeoMath`, directly after `bearingDegrees(from:to:)` and before `turnAngleDegrees(fromBearing:toBearing:)`:

```swift
    /// Wraps to the 0..<360 range, handling any input magnitude (including
    /// already-accumulated multi-lap deltas).
    static func normalizedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// One exponential-smoothing step from `from` toward `to`, always
    /// taking the shorter way around the 0/360 boundary (so e.g. 359 -> 1
    /// rotates forward through 0, not backward through 180).
    static func interpolatedAngle(from: Double, to: Double, fraction: Double) -> Double {
        let delta = turnAngleDegrees(fromBearing: from, toBearing: to)
        return normalizedDegrees(from + delta * fraction)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/GeoMathAngleTests`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add Core/GeoMath.swift Tests/GeoMathAngleTests.swift
git commit -m "Add angle normalization and interpolation to GeoMath"
```

---

### Task 2: `NavigationOrientationConfig`, `OrientationSource`, and pure trust filters

**Files:**
- Create: `Features/Navigation/NavigationOrientationEngine.swift`
- Test: `Tests/NavigationOrientationEngineTests.swift` (create)

**Interfaces:**
- Consumes: nothing from other tasks (pure, standalone).
- Produces: `NavigationOrientationConfig` (struct, `.default` static), `OrientationSource` (enum: `.course`, `.heading`, `.routeBearing`), `NavigationOrientationFilters.isCourseTrustworthy(speedMetersPerSecond:course:config:) -> Bool`, `NavigationOrientationFilters.isHeadingTrustworthy(heading:accuracy:config:) -> Bool`. Task 3 builds the stateful engine on top of these in the same file.

- [ ] **Step 1: Write the failing tests**

Create `Tests/NavigationOrientationEngineTests.swift`:

```swift
import XCTest
@testable import LaneLine

final class NavigationOrientationFilterTests: XCTestCase {
    private let config = NavigationOrientationConfig.default

    func testCourseIsTrustworthyWhenMovingWithValidCourse() {
        XCTAssertTrue(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: 5, course: 90, config: config
        ))
    }

    func testCourseIsNotTrustworthyBelowSpeedThreshold() {
        XCTAssertFalse(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: 0.5, course: 90, config: config
        ))
    }

    func testCourseIsNotTrustworthyWhenInvalid() {
        XCTAssertFalse(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: 5, course: -1, config: config
        ))
    }

    func testCourseIsNotTrustworthyWhenEitherValueIsMissing() {
        XCTAssertFalse(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: nil, course: 90, config: config
        ))
        XCTAssertFalse(NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: 5, course: nil, config: config
        ))
    }

    func testHeadingIsTrustworthyWithGoodAccuracy() {
        XCTAssertTrue(NavigationOrientationFilters.isHeadingTrustworthy(
            heading: 200, accuracy: 10, config: config
        ))
    }

    func testHeadingIsNotTrustworthyWithPoorAccuracy() {
        XCTAssertFalse(NavigationOrientationFilters.isHeadingTrustworthy(
            heading: 200, accuracy: 60, config: config
        ))
    }

    func testHeadingIsNotTrustworthyWhenAccuracyIsInvalid() {
        XCTAssertFalse(NavigationOrientationFilters.isHeadingTrustworthy(
            heading: 200, accuracy: -1, config: config
        ))
    }

    func testHeadingIsNotTrustworthyWhenMissing() {
        XCTAssertFalse(NavigationOrientationFilters.isHeadingTrustworthy(
            heading: nil, accuracy: 10, config: config
        ))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/NavigationOrientationFilterTests`
Expected: FAIL / build error — `NavigationOrientationConfig`/`NavigationOrientationFilters` do not exist yet.

- [ ] **Step 3: Implement the config, source enum, and filters**

Create `Features/Navigation/NavigationOrientationEngine.swift`:

```swift
import Foundation

/// Tunable thresholds for course-first orientation fusion. See
/// `docs/superpowers/specs/2026-07-29-course-first-navigation-orientation-design.md`
/// for the reasoning behind each default.
struct NavigationOrientationConfig {
    /// Below this speed, GPS course is not trusted as travel direction —
    /// noise dominates the signal once you're near-stationary.
    var minimumSpeedForCourseMetersPerSecond: Double = 1.4
    /// `CLHeading.headingAccuracy` above this (degrees) is too noisy to use.
    var maximumHeadingAccuracyDegrees: Double = 35
    /// How long to keep steering by the last good course after slowing
    /// below threshold, before falling back to heading — long enough to
    /// cover a stop-sign roll-through without twitching to compass.
    var courseFreezeGraceSeconds: Double = 3
    /// Exponential blend factor toward each new raw bearing.
    var smoothingFactor: Double = 0.35
    /// Minimum change before the displayed bearing moves at all — keeps
    /// sub-noise-floor jitter off the screen entirely.
    var minimumAngleDeltaDegrees: Double = 1.5

    static let `default` = NavigationOrientationConfig()
}

/// Which signal is currently driving the displayed bearing.
enum OrientationSource: Equatable {
    case course
    case heading
    case routeBearing
}

enum NavigationOrientationFilters {
    /// `CLLocation.speed`/`.course` are negative when the value is invalid.
    static func isCourseTrustworthy(
        speedMetersPerSecond: Double?,
        course: Double?,
        config: NavigationOrientationConfig
    ) -> Bool {
        guard let speedMetersPerSecond, let course else { return false }
        return speedMetersPerSecond >= config.minimumSpeedForCourseMetersPerSecond
            && course >= 0
    }

    /// `CLHeading.headingAccuracy` is negative when the reading is invalid.
    static func isHeadingTrustworthy(
        heading: Double?,
        accuracy: Double?,
        config: NavigationOrientationConfig
    ) -> Bool {
        guard let heading, let accuracy else { return false }
        return accuracy >= 0
            && accuracy <= config.maximumHeadingAccuracyDegrees
            && heading >= 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/NavigationOrientationFilterTests`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add Features/Navigation/NavigationOrientationEngine.swift Tests/NavigationOrientationEngineTests.swift
git commit -m "Add orientation config and course/heading trust filters"
```

---

### Task 3: `NavigationOrientationEngine` state machine

**Files:**
- Modify: `Features/Navigation/NavigationOrientationEngine.swift` (append)
- Test: `Tests/NavigationOrientationEngineTests.swift` (append)

**Interfaces:**
- Consumes: `NavigationOrientationConfig`, `OrientationSource`, `NavigationOrientationFilters.isCourseTrustworthy`/`isHeadingTrustworthy` (Task 2). `GeoMath.turnAngleDegrees`, `GeoMath.normalizedDegrees`, `GeoMath.interpolatedAngle` (Task 1, existing `GeoMath`).
- Produces: `NavigationOrientationEngine` — `init(initialBearing: Double, config: NavigationOrientationConfig = .default)`, `var displayBearing: Double { get }`, `var activeSource: OrientationSource { get }`, `func seed(bearing: Double)`, `func update(speedMetersPerSecond: Double?, course: Double?, heading: Double?, headingAccuracy: Double?, routeBearing: Double, deltaSeconds: Double) -> Double`. Task 5 (`ActiveRideModel`) calls `seed` once at ride start and `update` once per tick, in that exact parameter order.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/NavigationOrientationEngineTests.swift`:

```swift

final class NavigationOrientationEngineTests: XCTestCase {
    private func makeEngine(initialBearing: Double = 0) -> NavigationOrientationEngine {
        NavigationOrientationEngine(initialBearing: initialBearing)
    }

    func testPrefersCourseWhenMovingWithGoodCourse() {
        let engine = makeEngine()
        let result = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: 10, headingAccuracy: 5,
            routeBearing: 0, deltaSeconds: 1
        )
        XCTAssertEqual(engine.activeSource, .course)
        XCTAssertGreaterThan(result, 0, "Should have started moving toward the course, away from the seed bearing")
    }

    func testFreezesLastGoodCourseThroughTheGraceWindow() {
        let engine = makeEngine(initialBearing: 90)
        _ = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: nil, headingAccuracy: nil,
            routeBearing: 90, deltaSeconds: 1
        )
        for _ in 0..<3 {
            _ = engine.update(
                speedMetersPerSecond: 0.2, course: 90, heading: 200, headingAccuracy: 5,
                routeBearing: 90, deltaSeconds: 1
            )
        }
        XCTAssertEqual(engine.activeSource, .course, "Still within the grace window")
    }

    func testFallsBackToHeadingAfterTheGraceWindowExpires() {
        let engine = makeEngine(initialBearing: 90)
        _ = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: nil, headingAccuracy: nil,
            routeBearing: 90, deltaSeconds: 1
        )
        for _ in 0..<4 {
            _ = engine.update(
                speedMetersPerSecond: 0.2, course: 90, heading: 200, headingAccuracy: 5,
                routeBearing: 90, deltaSeconds: 1
            )
        }
        XCTAssertEqual(engine.activeSource, .heading)
    }

    func testFallsBackToRouteBearingWhenNeitherCourseNorHeadingAreTrustworthy() {
        let engine = makeEngine(initialBearing: 45)
        for _ in 0..<4 {
            _ = engine.update(
                speedMetersPerSecond: 0.2, course: -1, heading: nil, headingAccuracy: nil,
                routeBearing: 200, deltaSeconds: 1
            )
        }
        XCTAssertEqual(engine.activeSource, .routeBearing)
    }

    func testResumesCourseImmediatelyOnceTrustworthyAgainWithNoExtraGrace() {
        let engine = makeEngine(initialBearing: 90)
        _ = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: nil, headingAccuracy: nil,
            routeBearing: 90, deltaSeconds: 1
        )
        for _ in 0..<4 {
            _ = engine.update(
                speedMetersPerSecond: 0.2, course: 90, heading: 200, headingAccuracy: 5,
                routeBearing: 90, deltaSeconds: 1
            )
        }
        XCTAssertEqual(engine.activeSource, .heading, "Sanity check: should have fallen back first")

        _ = engine.update(
            speedMetersPerSecond: 5, course: 90, heading: 200, headingAccuracy: 5,
            routeBearing: 90, deltaSeconds: 1
        )
        XCTAssertEqual(engine.activeSource, .course, "Should resume course the instant it's trustworthy again")
    }

    func testSuppressesJitterBelowTheMinimumAngleDelta() {
        let engine = makeEngine(initialBearing: 90)
        let result = engine.update(
            speedMetersPerSecond: 5, course: 90.5, heading: nil, headingAccuracy: nil,
            routeBearing: 90, deltaSeconds: 1
        )
        XCTAssertEqual(result, 90, accuracy: 0.0001, "A sub-threshold nudge should not move the display bearing at all")
    }

    func testStillRotatesPromptlyThroughARealSharpTurn() {
        let engine = makeEngine(initialBearing: 0)
        var bearing = 0.0
        for _ in 0..<3 {
            bearing = engine.update(
                speedMetersPerSecond: 5, course: 90, heading: nil, headingAccuracy: nil,
                routeBearing: 0, deltaSeconds: 1
            )
        }
        XCTAssertGreaterThan(bearing, 45, "Three ticks of smoothing through a real 90 degree turn should have visibly rotated, not lagged")
    }

    func testHandlesWraparoundWithoutSpinningTheLongWayAround() {
        let engine = makeEngine(initialBearing: 359)
        let result = engine.update(
            speedMetersPerSecond: 5, course: 1, heading: nil, headingAccuracy: nil,
            routeBearing: 0, deltaSeconds: 1
        )
        XCTAssertTrue(result < 5 || result > 355, "Expected a short step across the wraparound, got \(result)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/NavigationOrientationEngineTests`
Expected: FAIL / build error — `NavigationOrientationEngine` does not exist yet.

- [ ] **Step 3: Implement the engine**

Append to `Features/Navigation/NavigationOrientationEngine.swift`:

```swift

/// Fuses GPS course and compass heading into one smoothed, jitter-resistant
/// bearing for the ride camera/puck. Course-first while moving; frozen on
/// the last good course briefly when slowing (avoids twitching at
/// intersections); falls back to compass, then route bearing, only once
/// course has truly gone stale.
final class NavigationOrientationEngine {
    private(set) var displayBearing: Double
    private(set) var activeSource: OrientationSource = .routeBearing

    private var frozenCourse: Double?
    private var secondsSinceCourseTrustworthy: Double = .infinity
    private let config: NavigationOrientationConfig

    init(initialBearing: Double, config: NavigationOrientationConfig = .default) {
        self.displayBearing = GeoMath.normalizedDegrees(initialBearing)
        self.config = config
    }

    /// Snaps the display bearing directly to `bearing`, bypassing
    /// smoothing — used once at ride start so the first camera frame
    /// doesn't spin in from wherever the engine happened to initialize.
    func seed(bearing: Double) {
        displayBearing = GeoMath.normalizedDegrees(bearing)
    }

    /// One fusion step. Call once per ride tick.
    @discardableResult
    func update(
        speedMetersPerSecond: Double?,
        course: Double?,
        heading: Double?,
        headingAccuracy: Double?,
        routeBearing: Double,
        deltaSeconds: Double
    ) -> Double {
        let target: Double

        if NavigationOrientationFilters.isCourseTrustworthy(
            speedMetersPerSecond: speedMetersPerSecond, course: course, config: config
        ), let course {
            target = course
            frozenCourse = course
            secondsSinceCourseTrustworthy = 0
            activeSource = .course
        } else if let frozenCourse, secondsSinceCourseTrustworthy < config.courseFreezeGraceSeconds {
            target = frozenCourse
            secondsSinceCourseTrustworthy += deltaSeconds
            activeSource = .course
        } else if NavigationOrientationFilters.isHeadingTrustworthy(
            heading: heading, accuracy: headingAccuracy, config: config
        ), let heading {
            target = heading
            activeSource = .heading
        } else {
            target = routeBearing
            activeSource = .routeBearing
        }

        let delta = GeoMath.turnAngleDegrees(fromBearing: displayBearing, toBearing: target)
        if abs(delta) >= config.minimumAngleDeltaDegrees {
            displayBearing = GeoMath.interpolatedAngle(
                from: displayBearing, to: target, fraction: config.smoothingFactor
            )
        }
        return displayBearing
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/NavigationOrientationEngineTests`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add Features/Navigation/NavigationOrientationEngine.swift Tests/NavigationOrientationEngineTests.swift
git commit -m "Add NavigationOrientationEngine course/heading fusion state machine"
```

---

### Task 4: `LocationServicing.currentHeadingAccuracy` + `MockLocationService` course/speed setters

**Files:**
- Modify: `Services/Location/LocationService.swift`
- Test: `Tests/MockLocationServiceOrientationTests.swift` (create)

**Interfaces:**
- Produces: `LocationServicing.currentHeadingAccuracy: Double? { get }` (implemented on both `LocationService` and `MockLocationService`); `MockLocationService.setLocation(_ coordinate: CLLocationCoordinate2D, heading: Double? = nil, headingAccuracy: Double? = nil, course: Double? = nil, courseAccuracy: Double? = nil, speed: Double? = nil)`. Task 5 reads `locationService.currentHeadingAccuracy` and `locationService.currentLocation?.course`/`.speed`; Task 5's test and Task 6 rely on this exact `setLocation` parameter order.

- [ ] **Step 1: Write the failing tests**

Create `Tests/MockLocationServiceOrientationTests.swift`:

```swift
import XCTest
import CoreLocation
@testable import LaneLine

@MainActor
final class MockLocationServiceOrientationTests: XCTestCase {
    func testSetLocationPopulatesCourseSpeedAndHeadingAccuracy() {
        let service = MockLocationService(coordinate: nil)
        service.setLocation(
            CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42),
            heading: 42, headingAccuracy: 6,
            course: 88, courseAccuracy: 12, speed: 4.5
        )

        XCTAssertEqual(service.currentHeading, 42)
        XCTAssertEqual(service.currentHeadingAccuracy, 6)
        XCTAssertEqual(service.currentLocation?.course, 88)
        XCTAssertEqual(service.currentLocation?.courseAccuracy, 12)
        XCTAssertEqual(service.currentLocation?.speed, 4.5)
    }

    func testSetLocationDefaultsLeaveCourseAndSpeedInvalid() {
        let service = MockLocationService(coordinate: nil)
        service.setLocation(CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42))

        XCTAssertNil(service.currentHeading)
        XCTAssertNil(service.currentHeadingAccuracy)
        XCTAssertEqual(service.currentLocation?.course ?? -1, -1)
        XCTAssertEqual(service.currentLocation?.speed ?? -1, -1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/MockLocationServiceOrientationTests`
Expected: FAIL / build error — `currentHeadingAccuracy` and the new `setLocation` parameters don't exist yet.

- [ ] **Step 3: Add `currentHeadingAccuracy` and extend `setLocation`**

In `Services/Location/LocationService.swift`, modify the protocol (add the new property after `currentHeading`):

```swift
@MainActor
protocol LocationServicing: AnyObject, Observable {
    var currentLocation: CLLocation? { get }
    /// Heading in degrees, when available.
    var currentHeading: Double? { get }
    /// `CLHeading.headingAccuracy` in degrees, alongside `currentHeading` —
    /// published separately so consumers can apply their own trust
    /// threshold instead of the coarse valid/invalid check done here.
    var currentHeadingAccuracy: Double? { get }
    var authorizationStatus: CLAuthorizationStatus { get }
    var isAuthorized: Bool { get }

    func requestAuthorization()
    func startUpdating()
    func stopUpdating()
    func reverseGeocodeStreetName(at coordinate: CLLocationCoordinate2D) async -> String?
}
```

In `LocationService`, add the stored property and update the delegate wiring:

```swift
    private(set) var currentLocation: CLLocation?
    private(set) var currentHeading: Double?
    private(set) var currentHeadingAccuracy: Double?
    private(set) var authorizationStatus: CLAuthorizationStatus
```

```swift
        proxy.onHeadingUpdate = { [weak self] heading, accuracy in
            Task { @MainActor in
                self?.currentHeading = heading
                self?.currentHeadingAccuracy = accuracy
            }
        }
```

In `DelegateProxy`, update the closure type and the delegate method:

```swift
        var onHeadingUpdate: ((Double, Double) -> Void)?
```

```swift
        func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
            guard newHeading.headingAccuracy >= 0 else { return }
            onHeadingUpdate?(newHeading.trueHeading, newHeading.headingAccuracy)
        }
```

In `MockLocationService`, add the stored property and replace `setLocation`:

```swift
    private(set) var currentLocation: CLLocation?
    private(set) var currentHeading: Double?
    private(set) var currentHeadingAccuracy: Double?
    private(set) var authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse
```

```swift
    func setLocation(
        _ coordinate: CLLocationCoordinate2D,
        heading: Double? = nil,
        headingAccuracy: Double? = nil,
        course: Double? = nil,
        courseAccuracy: Double? = nil,
        speed: Double? = nil
    ) {
        currentLocation = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: course ?? -1,
            courseAccuracy: courseAccuracy ?? -1,
            speed: speed ?? -1,
            speedAccuracy: 5,
            timestamp: Date()
        )
        if let heading { currentHeading = heading }
        if let headingAccuracy { currentHeadingAccuracy = headingAccuracy }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/MockLocationServiceOrientationTests`
Expected: PASS (2 tests). Also run the existing `RideRecorderTests` to confirm the `setLocation` signature change doesn't break its 3 call sites: `-only-testing:LaneLineTests/RideRecorderTests` — Expected: PASS (unchanged).

- [ ] **Step 5: Commit**

```bash
git add Services/Location/LocationService.swift Tests/MockLocationServiceOrientationTests.swift
git commit -m "Publish heading accuracy and course/speed test hooks on LocationServicing"
```

---

### Task 5: Wire `NavigationOrientationEngine` into `ActiveRideModel`

**Files:**
- Modify: `Features/Navigation/ActiveRideModel.swift`
- Test: `Tests/ActiveRideModelOrientationTests.swift` (create)

**Interfaces:**
- Consumes: `NavigationOrientationEngine` (Task 3), `LocationServicing.currentHeadingAccuracy` + `MockLocationService.setLocation(...)` (Task 4).
- Produces: `ActiveRideModel.displayHeading: Double` (unchanged type/name — `ActiveNavigationView` needs no changes for this), `ActiveRideModel.orientationSource: OrientationSource` (new, for testing the wiring). Task 6 continues to read `ride.displayHeading` exactly as before.

- [ ] **Step 1: Write the failing test**

Create `Tests/ActiveRideModelOrientationTests.swift`:

```swift
import XCTest
import CoreLocation
@testable import LaneLine

/// End-to-end check that ActiveRideModel's tick loop actually wires the new
/// course-first fusion through to `displayHeading` — the unit-level engine
/// tests (NavigationOrientationEngineTests) cover the state machine in
/// isolation; this proves the real LocationServicing -> ActiveRideModel
/// plumbing matches it.
@MainActor
final class ActiveRideModelOrientationTests: XCTestCase {
    private func northRoute() async throws -> (candidate: RouteCandidate, routing: RoutingService) {
        let o = TestGraphs.coordinate(37.7600, -122.4200, 10)
        let n = TestGraphs.coordinate(37.7700, -122.4200, 10)
        let graph = try await TestGraphs.build([
            TestGraphs.rawEdge(from: o, to: n, street: "North St"),
        ])
        let routing = RoutingService(geospatialService: StubGeospatialService(graph: graph))
        let routes = try await routing.generateRoutes(
            from: o.clCoordinate, to: n.clCoordinate,
            profile: .testProfile(bikeType: .hybridFitness), strategies: [.balanced]
        )
        let candidate = try XCTUnwrap(routes.first)
        return (candidate, routing)
    }

    func testDisplayHeadingPrefersCourseThenFreezesThenFallsBackToHeadingThenResumesCourse() async throws {
        let (candidate, routing) = try await northRoute()
        let origin = try XCTUnwrap(candidate.allCoordinates.first)
        let location = MockLocationService(coordinate: origin)

        let model = ActiveRideModel(
            route: candidate,
            profile: .testProfile(bikeType: .hybridFitness),
            locationService: location,
            routingService: routing
        )

        XCTAssertEqual(model.orientationSource, .routeBearing)

        // Moving east at a real bike speed with a good course: converges on
        // the course, not the route's own (north) bearing.
        for _ in 0..<15 {
            location.setLocation(origin, course: 90, speed: 5)
            model.tick(deltaSeconds: 1)
        }
        XCTAssertEqual(model.orientationSource, .course)
        XCTAssertLessThan(
            abs(GeoMath.turnAngleDegrees(fromBearing: model.displayHeading, toBearing: 90)), 2,
            "Should have converged on the moving course, not stayed near the route's own bearing"
        )

        // Slow down (below the trust threshold) but stay within the
        // freeze-grace window: still course, not yet drifting to heading.
        let headingAtSlowdown = model.displayHeading
        for _ in 0..<3 {
            location.setLocation(origin, heading: 45, headingAccuracy: 10, course: 90, speed: 0.2)
            model.tick(deltaSeconds: 1)
        }
        XCTAssertEqual(model.orientationSource, .course, "Should still be frozen on the last good course")
        XCTAssertLessThan(
            abs(GeoMath.turnAngleDegrees(fromBearing: headingAtSlowdown, toBearing: model.displayHeading)), 1,
            "Frozen course should not drift toward heading during the grace window"
        )

        // Past the grace window: falls back to the (different) compass
        // heading.
        for _ in 0..<10 {
            location.setLocation(origin, heading: 45, headingAccuracy: 10, course: 90, speed: 0.2)
            model.tick(deltaSeconds: 1)
        }
        XCTAssertEqual(model.orientationSource, .heading)
        XCTAssertLessThan(
            abs(GeoMath.turnAngleDegrees(fromBearing: model.displayHeading, toBearing: 45)), 2,
            "Should have converged on the compass heading once course went stale"
        )

        // Resuming real movement snaps straight back to course, with no
        // extra grace period on the way up.
        location.setLocation(origin, heading: 45, headingAccuracy: 10, course: 90, speed: 5)
        model.tick(deltaSeconds: 1)
        XCTAssertEqual(model.orientationSource, .course, "Resuming speed should switch back to course immediately")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/ActiveRideModelOrientationTests`
Expected: FAIL / build error — `ActiveRideModel.orientationSource` does not exist yet.

- [ ] **Step 3: Replace `ActiveRideModel`'s heading logic with the engine**

In `Features/Navigation/ActiveRideModel.swift`, replace this block (the doc comment through `normalizedDegrees`, currently right before `routeBearingHeading`):

```swift
    /// Camera/marker heading, preferring the phone's real compass so the
    /// map turns with however the rider is actually holding/facing it —
    /// route-bearing alone assumes you're pointed exactly along the road,
    /// which isn't true the moment you glance sideways, walk the bike, or
    /// drift off-line. Falls back to route bearing when there's no real
    /// heading (simulator/demo mode, or momentarily poor compass accuracy).
    ///
    /// This is the *smoothed* value — raw magnetometer readings genuinely
    /// jitter several degrees moment to moment, especially bike-mounted
    /// (vibration, nearby metal), and feeding that straight into the camera
    /// every tick reads as a constant small wobble rather than a settled
    /// direction. `refreshHeading()` (called once per tick) low-pass
    /// filters it; this just returns the filtered result.
    private(set) var displayHeading: Double = 0

    /// Exponential blend factor toward the latest raw reading — low enough
    /// to damp jitter, high enough to still catch up to a real turn within
    /// a couple of ticks rather than lagging behind it.
    private let headingSmoothingFactor: Double = 0.35

    private func refreshHeading() {
        let raw = locationService.currentHeading ?? routeBearingHeading
        let delta = Self.shortestAngleDelta(from: displayHeading, to: raw)
        displayHeading = Self.normalizedDegrees(displayHeading + delta * headingSmoothingFactor)
    }

    private static func shortestAngleDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        return delta
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }
```

with:

```swift
    /// Camera/marker heading — course-first while moving (real GPS travel
    /// direction, immune to the phone's compass being noisy on a bike
    /// mount), falling back to compass heading and finally route bearing
    /// only once course has genuinely gone stale. See
    /// `NavigationOrientationEngine` for the full fusion/smoothing policy;
    /// this just returns the smoothed result it produces.
    var displayHeading: Double { orientationEngine.displayBearing }

    /// Which signal is currently driving `displayHeading` — exposed for
    /// testing the tick-loop wiring end to end.
    var orientationSource: OrientationSource { orientationEngine.activeSource }

    private let orientationEngine = NavigationOrientationEngine(initialBearing: 0)

    private func refreshOrientation(deltaSeconds: Double) {
        let location = locationService.currentLocation
        orientationEngine.update(
            speedMetersPerSecond: location?.speed,
            course: location?.course,
            heading: locationService.currentHeading,
            headingAccuracy: locationService.currentHeadingAccuracy,
            routeBearing: routeBearingHeading,
            deltaSeconds: deltaSeconds
        )
    }
```

`routeBearingHeading` (the property directly after this block) is unchanged — leave it exactly as is.

In `start()`, replace:

```swift
        // Seed at the real starting direction rather than 0, so the first
        // camera frame doesn't spin in from due north.
        displayHeading = locationService.currentHeading ?? routeBearingHeading
```

with:

```swift
        // Seed at the real starting direction rather than the engine's
        // default, so the first camera frame doesn't spin in from due north.
        orientationEngine.seed(bearing: locationService.currentHeading ?? routeBearingHeading)
```

In `tick(deltaSeconds:)`, replace:

```swift
        refreshHeading()
```

with:

```swift
        refreshOrientation(deltaSeconds: deltaSeconds)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:LaneLineTests/ActiveRideModelOrientationTests`
Expected: PASS (1 test). Also run `-only-testing:LaneLineTests/RideGuidanceTests` — Expected: PASS (unchanged; none of those tests touch heading).

- [ ] **Step 5: Commit**

```bash
git add Features/Navigation/ActiveRideModel.swift Tests/ActiveRideModelOrientationTests.swift
git commit -m "Wire NavigationOrientationEngine into ActiveRideModel"
```

---

### Task 6: Camera follow-suspend and recenter in `ActiveNavigationView`

**Files:**
- Modify: `Features/Navigation/ActiveNavigationView.swift`

**Interfaces:**
- Consumes: `ride.displayHeading` (unchanged from Task 5), `GeoMath.distanceMeters`, `GeoMath.turnAngleDegrees` (existing).
- Produces: no new public interface — this is the final, view-only task. Nothing later depends on it.
- **No automated test for this task.** This is SwiftUI view/gesture-detection code; the project has no UI-testing harness (confirmed — `LaneLineTests` is unit-only), and MapKit's own gesture recognizers aren't something XCTest can drive. The verification step is a full build plus the complete existing test suite staying green, and this task's logic has been traced through manually below. Flag this honestly rather than fabricating a test.

- [ ] **Step 1: Add follow-suspend state and the epsilon constants**

In `Features/Navigation/ActiveNavigationView.swift`, in `ActiveNavigationView`'s state declarations, change:

```swift
    @State private var camera: MapCameraPosition = .automatic
```

to:

```swift
    @State private var camera: MapCameraPosition = .automatic
    @State private var isFollowSuspended = false
    @State private var lastCommandedCamera: MapCamera?

    /// Beyond any of these, a settled camera that doesn't match what we
    /// last commanded ourselves is treated as a user gesture, not our own
    /// animation completing.
    private static let followSuspendDistanceEpsilonMeters: Double = 15
    private static let followSuspendHeadingEpsilonDegrees: Double = 8
    private static let followSuspendZoomEpsilonMeters: Double = 200
```

- [ ] **Step 2: Route camera writes through one place, and detect gestures on settle**

Replace:

```swift
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea()
        .onChange(of: ride.progressMeters, initial: true) {
            // Duration runs a touch past the 1s tick interval so consecutive
            // camera animations always overlap slightly instead of settling
            // and re-starting each tick — that dead stop-start is what read
            // as choppy before. Ease in/out reads as far more fluid than
            // linear for the heading swing through a turn specifically.
            withAnimation(.easeInOut(duration: 1.1)) {
                camera = .camera(followCamera(ride))
            }
        }
    }
```

with:

```swift
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea()
        .onChange(of: ride.progressMeters, initial: true) {
            guard !isFollowSuspended else { return }
            // Duration runs a touch past the 1s tick interval so consecutive
            // camera animations always overlap slightly instead of settling
            // and re-starting each tick — that dead stop-start is what read
            // as choppy before. Ease in/out reads as far more fluid than
            // linear for the heading swing through a turn specifically.
            commitFollowCamera(ride, animation: .easeInOut(duration: 1.1))
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            guard let lastCommandedCamera else { return }
            let driftMeters = GeoMath.distanceMeters(
                from: context.camera.centerCoordinate, to: lastCommandedCamera.centerCoordinate
            )
            let headingDriftDegrees = abs(GeoMath.turnAngleDegrees(
                fromBearing: lastCommandedCamera.heading, toBearing: context.camera.heading
            ))
            let zoomDriftMeters = abs(context.camera.distance - lastCommandedCamera.distance)
            if driftMeters > Self.followSuspendDistanceEpsilonMeters
                || headingDriftDegrees > Self.followSuspendHeadingEpsilonDegrees
                || zoomDriftMeters > Self.followSuspendZoomEpsilonMeters {
                isFollowSuspended = true
            }
        }
    }
```

Then, directly after `followCamera(_:)`, add:

```swift

    /// Every programmatic camera write goes through here so
    /// `onMapCameraChange` always has a ground truth to diff a settled
    /// camera against — the only way a discrepancy can appear is a user
    /// gesture, since nothing else ever touches `camera` directly.
    private func commitFollowCamera(_ ride: ActiveRideModel, animation: Animation) {
        let target = followCamera(ride)
        lastCommandedCamera = target
        withAnimation(animation) {
            camera = .camera(target)
        }
    }
```

**Why this doesn't false-positive on our own animation:** `.onEnd` frequency fires once a camera change *settles* — including at the end of our own 1.1s programmatic animation. But since our own animation always settles exactly at `followCamera(ride)`'s target (the same value just stashed in `lastCommandedCamera`), that settle is a no-op match and never trips the epsilon check. Only a resting position that differs from what we last commanded — which nothing but a user gesture can produce — sets `isFollowSuspended`.

- [ ] **Step 3: Add the recenter button and wire it into the trailing controls**

Replace:

```swift
                mapModeToggle
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, LaneLineDesign.Spacing.medium)
```

with:

```swift
                trailingMapControls(ride)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, LaneLineDesign.Spacing.medium)
```

Then, directly after the existing `mapModeToggle` computed property, add:

```swift

    private func trailingMapControls(_ ride: ActiveRideModel) -> some View {
        VStack(spacing: LaneLineDesign.Spacing.small) {
            if isFollowSuspended {
                recenterButton(ride)
            }
            mapModeToggle
        }
    }

    /// Appears only while a manual pan/rotate/pinch has suspended auto-
    /// follow (see `onMapCameraChange` above). Tapping it resumes follow
    /// and snaps the camera back onto the rider.
    private func recenterButton(_ ride: ActiveRideModel) -> some View {
        Button {
            isFollowSuspended = false
            commitFollowCamera(ride, animation: .easeInOut(duration: 0.6))
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: largerControls ? 22 : 18, weight: .semibold))
                .frame(
                    width: largerControls ? 52 : 44,
                    height: largerControls ? 52 : 44
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(LaneLineDesign.Colors.primary, in: Circle())
        .accessibilityLabel("Recenter map on your position")
    }
```

- [ ] **Step 4: Build and run the full existing test suite**

Run: `xcodebuild build -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: BUILD SUCCEEDED

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS, full suite (previous 81 + this plan's new tests — 7 GeoMath + 8 filter + 8 engine + 2 mock + 1 integration = 27 new — should read around 108 total)

- [ ] **Step 5: Commit**

```bash
git add Features/Navigation/ActiveNavigationView.swift
git commit -m "Suspend camera follow on manual map gestures with a recenter action"
```

---

### Task 7: Version bump, device install, and ship

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Bump the version**

In `project.yml`, change:

```yaml
        CFBundleShortVersionString: "1.7.0"
        CFBundleVersion: "15"
```

to:

```yaml
        CFBundleShortVersionString: "1.8.0"
        CFBundleVersion: "16"
```

- [ ] **Step 2: Regenerate the Xcode project**

Run: `xcodegen generate`
Expected: `Generated project at LaneLine.xcodeproj`

- [ ] **Step 3: Full simulator build and test suite**

Run: `xcodebuild test -project LaneLine.xcodeproj -scheme LaneLine -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
Expected: PASS, full suite green (all tasks' new tests plus every pre-existing test).

- [ ] **Step 4: Build for the physical device**

Run: `xcodebuild build -project LaneLine.xcodeproj -scheme LaneLine -destination 'generic/platform=iOS'`
Expected: BUILD SUCCEEDED (pre-existing benign warnings about extension `CFBundleVersion` mismatch and interface orientations are expected and not new).

- [ ] **Step 5: Install and launch on the connected device**

Run: `xcrun devicectl device install app --device 0AA47941-472B-5AA9-9467-1A1FF9F69256 <path to the built .app from step 4>`
Expected: install succeeded

Run: `xcrun devicectl device process launch --device 0AA47941-472B-5AA9-9467-1A1FF9F69256 com.laneline.LaneLine`
Expected: process launched

- [ ] **Step 6: Commit and push**

```bash
git add project.yml
git commit -m "Bump version to 1.8.0 (16) for course-first navigation orientation"
git push
```

## Self-Review Notes

- **Spec coverage:** every numbered "IMPORTANT NAVIGATION BEHAVIOR" item in the spec maps to a task — course-first + speed/validity gating (Task 2/3), smoothing + shortest-angle interpolation (Task 1/3), freeze-then-fallback-then-resume (Task 3), separation of travel-direction/heading/camera-bearing concepts (Task 2/3/5 as distinct types), camera-follows-course not just phone orientation (Task 5, since `followCamera` already consumed `displayHeading`), manual-gesture follow-suspend + recenter (Task 6), config struct (Task 2), and pure testable functions for normalization/delta/interpolation/source-selection/filtering (Tasks 1-3, all as free functions/methods with dedicated tests).
- **Placeholder scan:** none — every step has complete, exact code.
- **Type consistency:** `NavigationOrientationEngine.update(...)` parameter order (`speedMetersPerSecond, course, heading, headingAccuracy, routeBearing, deltaSeconds`) is identical between its Task 3 definition and its Task 5 call site. `MockLocationService.setLocation(...)` parameter order (`heading, headingAccuracy, course, courseAccuracy, speed`) is identical between its Task 4 definition and every call site in Task 5's and Task 4's own tests. `OrientationSource`/`NavigationOrientationConfig`/`NavigationOrientationFilters` names match everywhere they're referenced across Tasks 2, 3, and 5.
