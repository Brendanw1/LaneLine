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
