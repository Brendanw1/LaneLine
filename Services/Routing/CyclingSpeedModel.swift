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

    /// Effective speed on a given grade. Climbing costs ~9% of speed per
    /// percent of grade (floored — nobody rides below walking pace, they
    /// walk); descending gains a capped bonus because SF riders brake on
    /// steep downhills rather than bomb blind intersections.
    static func speedKmh(bikeType: BikeType, grade: Double) -> Double {
        let base = baseSpeedKmh(for: bikeType)
        if grade > 0 {
            let climbCostPerPercent = bikeType == .eBike ? 0.035 : 0.09
            let factor = max(0.25, 1 - grade * 100 * climbCostPerPercent)
            return base * factor
        } else {
            let factor = min(1.35, 1 + abs(grade) * 100 * 0.03)
            return base * factor
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
