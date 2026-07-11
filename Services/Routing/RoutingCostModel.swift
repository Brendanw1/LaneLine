import Foundation

/// Weight configuration resolved from rider profile + strategy. All values
/// convert edge attributes into "equivalent seconds" so cost is directly
/// comparable to travel time and explainable to the rider.
struct RoutingWeights {
    /// Extra perceived seconds per meter of elevation gain, beyond the real
    /// time cost the speed model already charges.
    var climbSecondsPerMeter: Double
    /// Grade above which an edge counts as a punchy spike.
    var steepGradeThreshold: Double
    /// Time multiplier applied per unit of grade above the threshold.
    var steepGradePenaltyFactor: Double
    /// Scales the traffic-stress surcharge (stress 0...1 → up to
    /// `stressWeight` × 100% extra time).
    var stressWeight: Double
    /// Cost multipliers under 1 reward good infrastructure.
    var offStreetFactor: Double
    var protectedFactor: Double
    var bufferedFactor: Double
    var paintedFactor: Double
    /// Surface multipliers by type; unlisted surfaces cost 1.0.
    var surfaceFactors: [SurfaceType: Double]
    /// Time multiplier on steep descents (braking, caution).
    var descentCautionFactor: Double
    /// Descents steeper than this trigger the caution factor.
    var descentCautionThreshold: Double = -0.08

    // MARK: Resolution

    /// Base weights implied by who the rider is and what they ride.
    static func base(for profile: RiderProfile) -> RoutingWeights {
        var weights = bikeTypeDefaults(profile.bikeType)

        switch profile.hillTolerance {
        case .low: weights.climbSecondsPerMeter *= 2.0
        case .moderate: break
        case .high: weights.climbSecondsPerMeter *= 0.5
        }

        switch profile.safetyPreference {
        case .low: weights.stressWeight *= 0.5
        case .moderate: break
        case .high:
            weights.stressWeight *= 1.8
            weights.protectedFactor -= 0.05
            weights.offStreetFactor -= 0.05
        }

        switch profile.surfaceSensitivity {
        case .low:
            weights.surfaceFactors = weights.surfaceFactors.mapValues { 1 + ($0 - 1) * 0.5 }
        case .moderate: break
        case .high:
            weights.surfaceFactors = weights.surfaceFactors.mapValues { 1 + ($0 - 1) * 1.5 }
        }

        return weights
    }

    /// Strategy variants perturb the base weights to produce candidates with
    /// genuinely different tradeoff profiles.
    func applying(_ strategy: RouteStrategyType) -> RoutingWeights {
        var weights = self
        switch strategy {
        case .balanced:
            break
        case .safer:
            weights.stressWeight *= 2.0
            weights.offStreetFactor *= 0.9
            weights.protectedFactor *= 0.9
        case .faster:
            // Near-pure travel time: a rider choosing "faster" accepts
            // arterials, so infrastructure rewards are switched off — any
            // residual facility bonus would out-discount the time savings
            // of a direct arterial and collapse faster into balanced.
            weights.stressWeight *= 0.25
            weights.climbSecondsPerMeter *= 0.5
            weights.offStreetFactor = 1
            weights.protectedFactor = 1
            weights.bufferedFactor = 1
            weights.paintedFactor = 1
        case .easierClimbing:
            weights.climbSecondsPerMeter *= 2.5
            weights.steepGradeThreshold = max(0.04, weights.steepGradeThreshold - 0.02)
            weights.steepGradePenaltyFactor *= 2
        }
        return weights
    }

    private static func bikeTypeDefaults(_ bikeType: BikeType) -> RoutingWeights {
        switch bikeType {
        case .roadBike:
            // Smooth pavement and predictable streets above all; punchy
            // grades and sketchy surfaces are what road riders route around.
            return RoutingWeights(
                climbSecondsPerMeter: 3.0,
                steepGradeThreshold: 0.08,
                steepGradePenaltyFactor: 30,
                stressWeight: 0.9,
                offStreetFactor: 0.82,
                protectedFactor: 0.84,
                bufferedFactor: 0.90,
                paintedFactor: 0.95,
                surfaceFactors: [
                    .gravel: 2.6, .dirt: 3.6, .cobblestone: 2.2, .unknown: 1.35,
                ],
                descentCautionFactor: 1.3
            )
        case .hybridFitness:
            return RoutingWeights(
                climbSecondsPerMeter: 3.0,
                steepGradeThreshold: 0.09,
                steepGradePenaltyFactor: 22,
                stressWeight: 1.0,
                offStreetFactor: 0.82,
                protectedFactor: 0.85,
                bufferedFactor: 0.91,
                paintedFactor: 0.95,
                surfaceFactors: [
                    .gravel: 1.5, .dirt: 2.2, .cobblestone: 1.8, .unknown: 1.15,
                ],
                descentCautionFactor: 1.2
            )
        case .gravel:
            return RoutingWeights(
                climbSecondsPerMeter: 2.5,
                steepGradeThreshold: 0.10,
                steepGradePenaltyFactor: 18,
                stressWeight: 0.8,
                offStreetFactor: 0.80,
                protectedFactor: 0.88,
                bufferedFactor: 0.93,
                paintedFactor: 0.96,
                surfaceFactors: [
                    .gravel: 1.0, .dirt: 1.15, .cobblestone: 1.4, .unknown: 1.0,
                ],
                descentCautionFactor: 1.1
            )
        case .cityBike:
            return RoutingWeights(
                climbSecondsPerMeter: 4.0,
                steepGradeThreshold: 0.07,
                steepGradePenaltyFactor: 26,
                stressWeight: 1.4,
                offStreetFactor: 0.80,
                protectedFactor: 0.83,
                bufferedFactor: 0.90,
                paintedFactor: 0.94,
                surfaceFactors: [
                    .gravel: 1.6, .dirt: 2.4, .cobblestone: 1.9, .unknown: 1.15,
                ],
                descentCautionFactor: 1.35
            )
        case .eBike:
            // The motor does the climbing, so perceived climb burden is a
            // fraction of an acoustic bike's — hills stop being detour-worthy.
            return RoutingWeights(
                climbSecondsPerMeter: 0.5,
                steepGradeThreshold: 0.12,
                steepGradePenaltyFactor: 10,
                stressWeight: 1.0,
                offStreetFactor: 0.85,
                protectedFactor: 0.86,
                bufferedFactor: 0.92,
                paintedFactor: 0.96,
                surfaceFactors: [
                    .gravel: 1.5, .dirt: 2.2, .cobblestone: 1.8, .unknown: 1.15,
                ],
                descentCautionFactor: 1.2
            )
        }
    }
}

/// Converts one graph edge into equivalent-seconds cost for a specific rider
/// and strategy. Pure and stateless: the unit under test for all routing
/// behavior.
struct RoutingCostModel {
    let bikeType: BikeType
    let weights: RoutingWeights

    init(profile: RiderProfile, strategy: RouteStrategyType) {
        self.bikeType = profile.bikeType
        self.weights = RoutingWeights.base(for: profile).applying(strategy)
    }

    init(bikeType: BikeType, weights: RoutingWeights) {
        self.bikeType = bikeType
        self.weights = weights
    }

    func cost(of edge: RouteGraph.Edge) -> Double {
        let time = CyclingSpeedModel.traversalSeconds(
            lengthMeters: edge.lengthMeters,
            grade: edge.grade,
            bikeType: bikeType
        )

        var cost = time

        // Infrastructure reward / traffic-stress surcharge.
        cost *= facilityFactor(for: edge)
        cost *= 1 + weights.stressWeight * edge.stressScore

        // Surface quality.
        cost *= weights.surfaceFactors[edge.surfaceType] ?? 1.0

        // Perceived climb burden beyond raw slowdown.
        cost += edge.elevationGainMeters * weights.climbSecondsPerMeter

        // Punchy grade spikes hurt disproportionately.
        if edge.grade > weights.steepGradeThreshold {
            cost += time * (edge.grade - weights.steepGradeThreshold) * weights.steepGradePenaltyFactor
        }

        // Steep descents demand braking and caution, not free speed.
        if edge.grade < weights.descentCautionThreshold {
            cost += time * (weights.descentCautionFactor - 1)
        }

        // Low-confidence attribution earns a mild hedge so uncertain edges
        // lose ties against well-understood ones.
        cost *= 1 + (1 - edge.confidenceScore) * 0.15

        return cost
    }

    private func facilityFactor(for edge: RouteGraph.Edge) -> Double {
        if edge.facilityType == .offStreetPath { return weights.offStreetFactor }
        switch edge.protectionLevel {
        case .fullyProtected: return weights.protectedFactor
        case .buffered: return weights.bufferedFactor
        case .standard: return weights.paintedFactor
        case .sharrows, .none, .unknown: return 1.0
        }
    }

    /// Admissible A* heuristic: straight-line distance at the fastest
    /// achievable speed, discounted below the deepest facility reward so it
    /// never overestimates remaining cost.
    func heuristicCost(distanceMeters: Double) -> Double {
        let maxSpeedMs = CyclingSpeedModel.baseSpeedKmh(for: bikeType) * 1.4 / 3.6
        return 0.75 * distanceMeters / maxSpeedMs
    }
}
