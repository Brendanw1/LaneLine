import Foundation

// MARK: - Surface Sensitivity

enum SurfaceSensitivity: String, Codable, CaseIterable {
    case low
    case moderate
    case high
}

// MARK: - RoutePreferenceProfile

struct RoutePreferenceProfile: Codable, Equatable {
    /// Weight multiplier for prioritizing protected lanes (higher = stronger preference)
    var protectedLanePriority: Double

    /// Penalty weight applied per meter of climbing
    var climbingPenaltyWeight: Double

    /// Maximum grade (as decimal, e.g. 0.08 = 8%) the rider is willing to accept
    var maxGradeAvoidance: Double

    /// Weight for preferring direct routes over detours
    var directnessWeight: Double

    /// Penalty weight for rough or unknown surfaces
    var surfacePenaltyWeight: Double

    /// Penalty for dangerous intersections
    var dangerousIntersectionPenalty: Double

    /// Whether to avoid unpaved segments entirely
    var avoidUnpaved: Bool

    /// Whether to prefer officially recommended bike corridors
    var preferRecommendedBikeCorridors: Bool

    /// Create a default profile tuned for the given bike type
    static func `default`(for bikeType: BikeType) -> RoutePreferenceProfile {
        switch bikeType {
        case .roadBike:
            return RoutePreferenceProfile(
                protectedLanePriority: 1.5,
                climbingPenaltyWeight: 1.2,
                maxGradeAvoidance: 0.10,
                directnessWeight: 0.8,
                surfacePenaltyWeight: 1.5,
                dangerousIntersectionPenalty: 1.3,
                avoidUnpaved: true,
                preferRecommendedBikeCorridors: true
            )
        case .gravel:
            return RoutePreferenceProfile(
                protectedLanePriority: 0.8,
                climbingPenaltyWeight: 1.0,
                maxGradeAvoidance: 0.12,
                directnessWeight: 0.9,
                surfacePenaltyWeight: 0.4,
                dangerousIntersectionPenalty: 1.0,
                avoidUnpaved: false,
                preferRecommendedBikeCorridors: false
            )
        case .eBike:
            return RoutePreferenceProfile(
                protectedLanePriority: 1.3,
                climbingPenaltyWeight: 0.3,
                maxGradeAvoidance: 0.15,
                directnessWeight: 1.2,
                surfacePenaltyWeight: 1.0,
                dangerousIntersectionPenalty: 1.0,
                avoidUnpaved: true,
                preferRecommendedBikeCorridors: true
            )
        case .hybridFitness, .cityBike:
            return RoutePreferenceProfile(
                protectedLanePriority: 1.4,
                climbingPenaltyWeight: 1.0,
                maxGradeAvoidance: 0.10,
                directnessWeight: 1.0,
                surfacePenaltyWeight: 0.8,
                dangerousIntersectionPenalty: 1.2,
                avoidUnpaved: true,
                preferRecommendedBikeCorridors: true
            )
        }
    }
}

// MARK: - Route Strategy Type

enum RouteStrategyType: String, Codable, CaseIterable {
    case balanced
    case safer
    case faster
    case easierClimbing

    var displayName: String {
        switch self {
        case .balanced: return "Balanced"
        case .safer: return "Safer"
        case .faster: return "Faster"
        case .easierClimbing: return "Easier Climbing"
        }
    }
}
