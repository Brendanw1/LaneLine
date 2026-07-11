import Foundation

// Single home for user-facing names of model enums, so screens never
// redefine them and copy stays consistent app-wide.

extension BikeType {
    var displayName: String {
        switch self {
        case .roadBike: return "Road bike"
        case .hybridFitness: return "Hybrid / fitness"
        case .gravel: return "Gravel bike"
        case .cityBike: return "City bike"
        case .eBike: return "E-bike"
        }
    }

    /// One-line summary of how routing treats this bike, shown in onboarding.
    var routingSummary: String {
        switch self {
        case .roadBike:
            return "Smooth pavement, steady grades, protected lanes — avoids punchy climbs and rough surfaces."
        case .hybridFitness:
            return "Balanced routing with a preference for calm streets and manageable hills."
        case .gravel:
            return "Comfortable on mixed surfaces; rough segments barely register."
        case .cityBike:
            return "Comfort first: calmer streets, gentler grades, more protected lanes."
        case .eBike:
            return "Hills matter much less; safety and lane quality still count."
        }
    }
}

extension HillTolerance {
    var displayName: String {
        switch self {
        case .low: return "Avoid hills"
        case .moderate: return "Some climbing is fine"
        case .high: return "Bring on the climbs"
        }
    }
}

extension SafetyPreference {
    var displayName: String {
        switch self {
        case .low: return "Speed first"
        case .moderate: return "Balanced"
        case .high: return "Protected lanes first"
        }
    }
}

extension DirectnessPreference {
    var displayName: String {
        switch self {
        case .direct: return "Most direct"
        case .balanced: return "Balanced"
        case .scenic: return "Scenic detours OK"
        }
    }
}

extension SurfaceSensitivity {
    var displayName: String {
        switch self {
        case .low: return "Anything rideable"
        case .moderate: return "Prefer pavement"
        case .high: return "Smooth pavement only"
        }
    }
}

extension MetricsPriority {
    var displayName: String {
        switch self {
        case .distance: return "Distance"
        case .time: return "Time / ETA"
        case .climb: return "Climb remaining"
        }
    }
}

extension BikeFacilityType {
    var displayName: String {
        switch self {
        case .protectedBikeLane: return "Protected lane"
        case .bikeLane: return "Bike lane"
        case .sharedLane: return "Shared lane"
        case .bikeRoute: return "Bike route"
        case .offStreetPath: return "Car-free path"
        case .mixedTraffic: return "Mixed traffic"
        case .unknown: return "Unknown"
        }
    }
}

extension RoadClass {
    var displayName: String {
        switch self {
        case .residential: return "Residential"
        case .tertiary: return "Local road"
        case .secondary: return "Secondary"
        case .primary: return "Primary"
        case .arterial: return "Arterial"
        case .highway: return "Highway"
        case .unknown: return "Unknown"
        }
    }
}

extension TurnType {
    var displayName: String {
        switch self {
        case .straight: return "Continue"
        case .slightLeft: return "Bear left"
        case .slightRight: return "Bear right"
        case .left: return "Turn left"
        case .right: return "Turn right"
        case .sharpLeft: return "Sharp left"
        case .sharpRight: return "Sharp right"
        case .uTurn: return "U-turn"
        case .unknown: return "Continue"
        }
    }

    var systemImage: String {
        switch self {
        case .straight, .unknown: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .slightRight: return "arrow.up.right"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .sharpLeft: return "arrow.uturn.left"
        case .sharpRight: return "arrow.uturn.right"
        case .uTurn: return "arrow.uturn.down"
        }
    }
}
