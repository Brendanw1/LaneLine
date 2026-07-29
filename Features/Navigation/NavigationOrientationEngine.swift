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
