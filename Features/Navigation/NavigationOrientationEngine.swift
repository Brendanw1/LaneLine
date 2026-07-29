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
