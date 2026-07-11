import Foundation
import CoreLocation

// MARK: - Route Scoring Service Implementation

/// Pure segment/route scoring — stateless, so a value type suffices.
struct RouteScoringService: RouteScoringServiceProtocol {

    func scoreSegment(
        _ segment: RouteSegment,
        profile: RiderProfile,
        preferences: RoutePreferenceProfile
    ) -> SegmentScore {
        let bikeFactors = bikeTypeMultipliers(for: profile.bikeType)

        // Travel time score (normalized)
        let travelTimeScore = max(0, 1.0 - (segment.estimatedSeconds / 3600) * 0.5)

        // Climb penalty: average grade weighted by segment length
        let gradeSeverity = segment.averageGrade * segment.lengthMeters / 100
        let climbPenalty = gradeSeverity * preferences.climbingPenaltyWeight * bikeFactors.gradePenalty

        // Max grade penalty: any segment exceeding rider's max triggers heavy penalty
        let maxGradePenalty = segment.maxGrade > preferences.maxGradeAvoidance
            ? (segment.maxGrade - preferences.maxGradeAvoidance) * 10 * bikeFactors.gradePenalty
            : 0

        // Facility bonus: better bike facilities get bonus
        let facilityBonus = segment.bikeFacilityType != .mixedTraffic
            ? facilityScore(for: segment.bikeFacilityType) * preferences.protectedLanePriority
            : 0

        // Protection bonus
        let protectionBonus = protectionScore(for: segment.protectionLevel) * preferences.protectedLanePriority

        // Arterial penalty
        let arterialPenalty = segment.roadClass == .arterial || segment.roadClass == .primary
            ? preferences.dangerousIntersectionPenalty * bikeFactors.stressFactor
            : 0

        // Surface penalty
        let surfacePenalty = segment.surfaceType == .unknown || segment.surfaceType == .gravel || segment.surfaceType == .dirt
            ? preferences.surfacePenaltyWeight * bikeFactors.surfaceFactor
            : 0

        // Crossing penalty: high-stress intersections
        let crossingPenalty = segment.intersectionStressScore > 0.6
            ? segment.intersectionStressScore * preferences.dangerousIntersectionPenalty
            : 0

        // Turn penalty: complex turns add cognitive load
        let turnPenalty = turnComplexityPenalty(for: segment.turnType)

        let totalScore = travelTimeScore
            - climbPenalty
            - maxGradePenalty
            + facilityBonus
            + protectionBonus
            - arterialPenalty
            - surfacePenalty
            - crossingPenalty
            - turnPenalty

        return SegmentScore(
            travelTimeScore: travelTimeScore,
            climbPenalty: climbPenalty,
            maxGradePenalty: maxGradePenalty,
            facilityBonus: facilityBonus,
            protectionBonus: protectionBonus,
            arterialPenalty: arterialPenalty,
            surfacePenalty: surfacePenalty,
            crossingPenalty: crossingPenalty,
            turnPenalty: turnPenalty,
            totalScore: totalScore
        )
    }

    func computeRouteScore(
        segments: [RouteSegment],
        segmentScores: [SegmentScore],
        directnessRatio: Double
    ) -> RouteScoreBreakdown {
        guard !segments.isEmpty, !segmentScores.isEmpty else {
            return RouteScoreBreakdown(
                travelTimeScore: 0,
                climbPenalty: 0,
                maxGradePenalty: 0,
                protectedLaneBonus: 0,
                bikeLaneBonus: 0,
                offStreetBonus: 0,
                arterialPenalty: 0,
                roughSurfacePenalty: 0,
                crossingPenalty: 0,
                detourPenalty: 0,
                descentPenalty: 0
            )
        }

        let totalLength = segments.reduce(0) { $0 + $1.lengthMeters }

        // Weight segment scores by length
        let weightedScores = zip(segments, segmentScores).map { segment, score in
            let weight = segment.lengthMeters / max(totalLength, 1)
            return (score, weight)
        }

        let travelTimeScore = weightedScores.reduce(0) { $0 + $1.0.travelTimeScore * $1.1 }
        let climbPenalty = weightedScores.reduce(0) { $0 + $1.0.climbPenalty * $1.1 }
        let maxGradePenalty = segments.map(\.maxGrade).max() ?? 0

        // Bonuses
        let protectedLength = segments.filter { $0.protectionLevel == .fullyProtected }.reduce(0) { $0 + $1.lengthMeters }
        let protectedLaneBonus = (protectedLength / max(totalLength, 1)) * 2.0

        let bikeLaneLength = segments.filter { $0.bikeFacilityType == .bikeLane }.reduce(0) { $0 + $1.lengthMeters }
        let bikeLaneBonus = (bikeLaneLength / max(totalLength, 1)) * 1.5

        let offStreetLength = segments.filter { $0.bikeFacilityType == .offStreetPath }.reduce(0) { $0 + $1.lengthMeters }
        let offStreetBonus = (offStreetLength / max(totalLength, 1)) * 2.5

        // Penalties
        let arterialLength = segments.filter { $0.roadClass == .arterial }.reduce(0) { $0 + $1.lengthMeters }
        let arterialPenalty = (arterialLength / max(totalLength, 1)) * 1.5

        let roughLength = segments.filter { $0.surfaceType == .gravel || $0.surfaceType == .dirt || $0.surfaceType == .unknown }.reduce(0) { $0 + $1.lengthMeters }
        let roughSurfacePenalty = (roughLength / max(totalLength, 1)) * 1.0

        let crossingPenalty = weightedScores.reduce(0) { $0 + $1.0.crossingPenalty * $1.1 }

        // Detour penalty: how much longer vs direct
        let detourPenalty = max(0, (directnessRatio - 1.0)) * 1.5

        // Descent penalty
        let descentSegments = segments.filter { $0.averageGrade < -0.03 }
        let descentPenalty = Double(descentSegments.count) * 0.1

        return RouteScoreBreakdown(
            travelTimeScore: travelTimeScore,
            climbPenalty: climbPenalty,
            maxGradePenalty: maxGradePenalty * 2.0,
            protectedLaneBonus: protectedLaneBonus,
            bikeLaneBonus: bikeLaneBonus,
            offStreetBonus: offStreetBonus,
            arterialPenalty: arterialPenalty,
            roughSurfacePenalty: roughSurfacePenalty,
            crossingPenalty: crossingPenalty,
            detourPenalty: detourPenalty,
            descentPenalty: descentPenalty
        )
    }

    // MARK: - Private Helpers

    private struct BikeTypeMultipliers {
        let gradePenalty: Double
        let surfaceFactor: Double
        let stressFactor: Double
    }

    private func bikeTypeMultipliers(for bikeType: BikeType) -> BikeTypeMultipliers {
        switch bikeType {
        case .roadBike:
            return BikeTypeMultipliers(gradePenalty: 1.2, surfaceFactor: 1.5, stressFactor: 1.0)
        case .gravel:
            return BikeTypeMultipliers(gradePenalty: 1.0, surfaceFactor: 0.4, stressFactor: 0.7)
        case .eBike:
            return BikeTypeMultipliers(gradePenalty: 0.3, surfaceFactor: 1.0, stressFactor: 0.8)
        case .hybridFitness, .cityBike:
            return BikeTypeMultipliers(gradePenalty: 1.0, surfaceFactor: 0.8, stressFactor: 1.2)
        }
    }

    private func facilityScore(for type: BikeFacilityType) -> Double {
        switch type {
        case .protectedBikeLane: return 2.0
        case .bikeLane: return 1.5
        case .offStreetPath: return 2.5
        case .sharedLane: return 0.5
        case .bikeRoute: return 1.0
        case .mixedTraffic: return 0
        case .unknown: return 0
        }
    }

    private func protectionScore(for level: ProtectionLevel) -> Double {
        switch level {
        case .fullyProtected: return 2.0
        case .buffered: return 1.5
        case .standard: return 1.0
        case .sharrows: return 0.3
        case .none: return 0
        case .unknown: return 0
        }
    }

    private func turnComplexityPenalty(for turn: TurnType) -> Double {
        switch turn {
        case .straight: return 0
        case .slightLeft, .slightRight: return 0.05
        case .left, .right: return 0.1
        case .sharpLeft, .sharpRight: return 0.2
        case .uTurn: return 0.3
        case .unknown: return 0.1
        }
    }
}
