import Foundation

// MARK: - RouteCandidate

struct RouteCandidate: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var strategyType: RouteStrategyType
    var segments: [RouteSegment]
    var totalDistanceMeters: Double
    var etaSeconds: Double
    var totalElevationGainMeters: Double
    var maxGrade: Double
    var protectedLanePercent: Double
    var bikeFacilityPercent: Double
    var roadBikeSuitabilityScore: Double
    var routeStressScore: Double
    var directnessScore: Double
    var confidenceScore: Double
    var recommendationReason: String
    var cautionNotes: [String]
    var scoreBreakdown: RouteScoreBreakdown?
    /// Estimated metabolic kilocalories for this rider on this route, from
    /// the same physics model used to total calories during a recorded ride.
    var estimatedCalories: Double

    // MARK: - Computed Properties

    var distanceFormatted: String {
        let km = totalDistanceMeters / 1000
        return String(format: "%.1f km", km)
    }

    var durationFormatted: String {
        let minutes = Int(etaSeconds / 60)
        if minutes >= 60 {
            let hours = minutes / 60
            let remainingMinutes = minutes % 60
            if remainingMinutes > 0 {
                return "\(hours)h \(remainingMinutes)m"
            }
            return "\(hours)h"
        }
        return "\(minutes)m"
    }

    var elevationGainFormatted: String {
        return "\(Int(totalElevationGainMeters))m"
    }

    var maxGradeFormatted: String {
        return String(format: "%.1f%%", maxGrade * 100)
    }

    init(
        id: UUID = UUID(),
        label: String = "",
        strategyType: RouteStrategyType = .balanced,
        segments: [RouteSegment] = [],
        totalDistanceMeters: Double = 0,
        etaSeconds: Double = 0,
        totalElevationGainMeters: Double = 0,
        maxGrade: Double = 0,
        protectedLanePercent: Double = 0,
        bikeFacilityPercent: Double = 0,
        roadBikeSuitabilityScore: Double = 0,
        routeStressScore: Double = 0,
        directnessScore: Double = 0,
        confidenceScore: Double = 1.0,
        recommendationReason: String = "",
        cautionNotes: [String] = [],
        scoreBreakdown: RouteScoreBreakdown? = nil,
        estimatedCalories: Double = 0
    ) {
        self.id = id
        self.label = label
        self.strategyType = strategyType
        self.segments = segments
        self.totalDistanceMeters = totalDistanceMeters
        self.etaSeconds = etaSeconds
        self.totalElevationGainMeters = totalElevationGainMeters
        self.maxGrade = maxGrade
        self.protectedLanePercent = protectedLanePercent
        self.bikeFacilityPercent = bikeFacilityPercent
        self.roadBikeSuitabilityScore = roadBikeSuitabilityScore
        self.routeStressScore = routeStressScore
        self.directnessScore = directnessScore
        self.confidenceScore = confidenceScore
        self.recommendationReason = recommendationReason
        self.cautionNotes = cautionNotes
        self.scoreBreakdown = scoreBreakdown
        self.estimatedCalories = estimatedCalories
    }
}
