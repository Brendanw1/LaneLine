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
    /// Apple Watch heart rate at this sample, when a stream existed.
    /// Optional so records written before HR integration still decode.
    var heartRateBPM: Double? = nil
    /// Pedaling cadence at this sample — from a Bluetooth cadence sensor
    /// (e.g. Magene S3+) or the Apple Watch's stream. 0 means coasting
    /// with a live sensor; nil means no cadence source.
    var cadenceRPM: Double? = nil
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
    /// Heart-rate totals from the Watch stream, nil for rides without one.
    /// Declared last with nil defaults so existing memberwise call sites
    /// (and old persisted JSON, via synthesized decodeIfPresent) are
    /// unaffected.
    var averageHeartRateBPM: Double? = nil
    var maxHeartRateBPM: Double? = nil
    /// Cadence totals, nil for rides without a cadence source. Average is
    /// pedaling-only (coasting zeros excluded), the bike-computer
    /// convention — a long descent shouldn't drag 88 RPM down to 60.
    var averageCadenceRPM: Double? = nil
    var maxCadenceRPM: Double? = nil
    /// Crank revolutions over the ride, estimated from per-sample cadence.
    var totalCrankRevolutions: Double? = nil
}

// MARK: - Ride Record

/// A complete recorded ride: summary plus the full sample log.
struct RideRecord: Identifiable, Codable, Equatable {
    var summary: RideSummary
    var samples: [RideSample]

    var id: UUID { summary.id }
}
