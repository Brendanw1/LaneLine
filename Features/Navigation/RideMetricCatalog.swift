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
