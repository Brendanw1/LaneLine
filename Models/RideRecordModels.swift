import Foundation

// MARK: - Ride Sample

/// One recorded measurement (~1 Hz) of an active ride.
struct RideSample: Codable, Equatable {
    /// Seconds since ride start (manual pauses excluded).
    var t: Double
    var latitude: Double
    var longitude: Double
    var altitudeMeters: Double?
    var speedKmh: Double
    /// Cumulative distance at this sample.
    var distanceMeters: Double
    var gradeDecimal: Double?
}

// MARK: - Ride Summary

/// The lightweight totals of a ride — what the history list shows without
/// loading the full sample log.
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
    /// False for checkpoint-only (interrupted) rides.
    var isComplete: Bool
}

// MARK: - Ride Record

/// A complete recorded ride: summary plus the full sample log.
struct RideRecord: Identifiable, Codable, Equatable {
    var summary: RideSummary
    var samples: [RideSample]

    var id: UUID { summary.id }
}
