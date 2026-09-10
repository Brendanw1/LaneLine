import Foundation

/// Grade- and bike-aware speed estimation. Used by the graph builder for
/// neutral edge estimates and by `RouteMetricsCalculator` for rider ETAs.
enum CyclingSpeedModel {
    /// Flat-ground cruising speed in km/h.
    static func baseSpeedKmh(for bikeType: BikeType) -> Double {
        switch bikeType {
        case .roadBike: return 20
        case .hybridFitness: return 17
        case .gravel: return 17
        case .cityBike: return 14
        case .eBike: return 22
        }
    }

    /// Effective speed on a given grade. Climbing cost is piecewise:
    /// gentle grades lose ~9% of base speed per percent (the linear
    /// approximation holds for typical SF terrain); past ~8% the slope
    /// steepens because riders drop into their lowest gear and approach
    /// walking pace, which floors at ~3 km/h rather than the previous
    /// 5 km/h — that floor left 10–30% grades indistinguishable, so two
    /// SF streets of very different steepness cost the same. Descending
    /// gains a capped bonus because SF riders brake on steep downhills
    /// rather than bomb blind intersections.
    static func speedKmh(bikeType: BikeType, grade: Double) -> Double {
        let base = baseSpeedKmh(for: bikeType)
        if grade > 0 {
            let climbCostPerPercent = bikeType == .eBike ? 0.035 : 0.09
            let climbPct = grade * 100
            let factor: Double
            if climbPct < 8 {
                factor = max(walkingFactor(for: bikeType), 1 - climbPct * climbCostPerPercent)
            } else {
                // Past the linear zone, drop faster and floor at walking pace
                // so 10%/15%/20%/25% climbs differentiate. The steep slope is
                // tuned so realistic SF grades (10–15%) land in the
                // grinding-lowest-gear band (3–5 km/h) rather than collapsing
                // to the floor at 10% as the previous linear model did.
                // E-bikes degrade faster here than below 8%: the motor's
                // assist fades on truly steep pitches and the rider's legs
                // take over, so the curve bends toward acoustic pace while
                // staying above it (see testEBikeRetainsMoreSpeedThanRoadBikeAtSteepGrades).
                let steepSlope = bikeType == .eBike ? 0.05 : 0.030
                let steepBase = 1 - 8 * climbCostPerPercent
                factor = max(walkingFactor(for: bikeType), steepBase - (climbPct - 8) * steepSlope)
            }
            return base * factor
        } else {
            // Descending: gain a capped bonus because SF riders brake on
            // steep downhills rather than bomb blind intersections. The
            // naive linear `1 + 0.03 * descentPct` model hits the 1.35×
            // cap at -11.7% and stayed flat for every grade steeper than
            // that, making a -25% descent cost *less* time than a -9% one
            // even though it's materially more dangerous. Tighten the cap
            // past -10% so very steep descents don't get free speed.
            let descentPct = abs(grade) * 100
            let bonus = descentPct * 0.03
            let cap: Double
            if descentPct < 10 {
                cap = 1.35
            } else {
                // Past -10%, the cap drops — riders are braking hard at
                // -15% and can't actually go 1.35× faster than flat.
                let capDrop = (descentPct - 10) * 0.015
                cap = max(1.20, 1.35 - capDrop)
            }
            let factor = min(cap, 1 + bonus)
            return base * factor
        }
    }

    /// Walking pace floor per bike type. Real cyclists dismount or shuffle
    /// at the steepest grades; this is the speed that the model converges
    /// to rather than allowing negative factors or zero speed. Road bikes
    /// grind lowest gear; city bikes are slower in general; gravel riders
    /// are willing to walk more; e-bikes keep moving under motor.
    private static func walkingFactor(for bikeType: BikeType) -> Double {
        switch bikeType {
        case .roadBike: return 0.17  // ~3.4 km/h grinding
        case .hybridFitness: return 0.18
        case .gravel: return 0.17
        case .cityBike: return 0.17
        case .eBike: return 0.35  // motor still assists under walk speed
        }
    }

    static func traversalSeconds(
        lengthMeters: Double,
        grade: Double,
        bikeType: BikeType
    ) -> Double {
        let speedMs = speedKmh(bikeType: bikeType, grade: grade) / 3.6
        return lengthMeters / max(0.1, speedMs)
    }

    /// Neutral estimate stored on graph edges, independent of any rider.
    static func neutralTraversalSeconds(lengthMeters: Double, grade: Double) -> Double {
        traversalSeconds(lengthMeters: lengthMeters, grade: grade, bikeType: .hybridFitness)
    }
}

/// Traffic-stress proxy derived from road class, bike infrastructure, and
/// (when OSM provides them) posted speed and lane count. Follows the shape of
/// LTS (Level of Traffic Stress) methodology, normalized to 0...1.
enum StressModel {
    static func segmentStress(
        roadClass: RoadClass,
        facilityType: BikeFacilityType,
        protectionLevel: ProtectionLevel,
        speedLimitKmh: Double? = nil,
        laneCount: Int? = nil
    ) -> Double {
        var stress: Double
        switch roadClass {
        case .residential: stress = 0.15
        case .tertiary: stress = 0.30
        case .secondary: stress = 0.45
        case .primary: stress = 0.60
        case .arterial: stress = 0.75
        case .highway: stress = 0.90
        case .unknown: stress = 0.45
        }

        if let speed = speedLimitKmh, speed > 40 { stress += 0.10 }
        if let lanes = laneCount, lanes >= 4 { stress += 0.10 }

        // Off-street paths are insulated from traffic entirely.
        if facilityType == .offStreetPath { return 0.05 }

        switch protectionLevel {
        case .fullyProtected: stress -= 0.35
        case .buffered: stress -= 0.20
        case .standard: stress -= 0.12
        case .sharrows: stress -= 0.03
        case .none, .unknown: break
        }

        return min(0.95, max(0.05, stress))
    }

    /// Crossing stress at the downstream intersection of an edge. Without
    /// signal/crossing data (a v2 ingestion source), the dominant approach
    /// road is the best available proxy.
    static func intersectionStress(
        edgeStress: Double,
        crossesRoadClass: RoadClass?
    ) -> Double {
        var stress = edgeStress
        if let crossed = crossesRoadClass,
           crossed == .primary || crossed == .arterial || crossed == .highway {
            stress += 0.15
        }
        return min(0.95, max(0.05, stress))
    }
}
