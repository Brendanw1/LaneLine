import Foundation
import CoreLocation

/// Assembles a graph path into a `RouteCandidate`: merges micro-edges into
/// street-level segments, computes rider-specific ETA, and derives every
/// route-level metric shown on the comparison and detail screens.
struct RouteMetricsCalculator {
    /// Fixed cost per maneuver: slowing, checking traffic, accelerating.
    var secondsPerManeuver: Double = 8

    func candidate(
        from edges: [RouteGraph.Edge],
        strategy: RouteStrategyType,
        profile: RiderProfile,
        origin: CLLocationCoordinate2D,
        destination: CLLocationCoordinate2D
    ) -> RouteCandidate {
        let segments = mergeIntoSegments(edges, bikeType: profile.bikeType)

        let totalLength = edges.reduce(0) { $0 + $1.lengthMeters }
        let totalGain = edges.reduce(0) { $0 + $1.elevationGainMeters }
        let maxGrade = edges.map { max(0, $0.grade) }.max() ?? 0
        let rideSeconds = edges.reduce(0) {
            $0 + CyclingSpeedModel.traversalSeconds(
                lengthMeters: $1.lengthMeters, grade: $1.grade, bikeType: profile.bikeType
            )
        }
        let maneuverCount = Double(max(0, segments.count - 1))
        let etaSeconds = rideSeconds + maneuverCount * secondsPerManeuver

        func lengthShare(_ predicate: (RouteGraph.Edge) -> Bool) -> Double {
            guard totalLength > 0 else { return 0 }
            return edges.filter(predicate).reduce(0) { $0 + $1.lengthMeters } / totalLength
        }

        let protectedShare = lengthShare {
            $0.protectionLevel == .fullyProtected || $0.protectionLevel == .buffered
                || $0.facilityType == .offStreetPath
        }
        let facilityShare = lengthShare {
            $0.facilityType != .mixedTraffic && $0.facilityType != .unknown
        }

        let stress = weightedAverage(edges, totalLength: totalLength) { $0.stressScore }
        let confidence = weightedAverage(edges, totalLength: totalLength) { $0.confidenceScore }
        let crowDistance = GeoMath.distanceMeters(from: origin, to: destination)
        let directness = totalLength > 0 ? min(1, crowDistance / totalLength) : 0

        return RouteCandidate(
            label: strategy.displayName,
            strategyType: strategy,
            segments: segments,
            totalDistanceMeters: totalLength,
            etaSeconds: etaSeconds,
            totalElevationGainMeters: totalGain,
            maxGrade: maxGrade,
            protectedLanePercent: protectedShare,
            bikeFacilityPercent: facilityShare,
            roadBikeSuitabilityScore: roadBikeSuitability(edges, totalLength: totalLength),
            routeStressScore: stress,
            directnessScore: directness,
            confidenceScore: confidence
        )
    }

    // MARK: Segment assembly

    /// Merge consecutive micro-edges that share a street and facility into
    /// one rider-visible segment, deriving the turn type at each boundary
    /// from the bearing change.
    func mergeIntoSegments(_ edges: [RouteGraph.Edge], bikeType: BikeType) -> [RouteSegment] {
        guard !edges.isEmpty else { return [] }

        var groups: [[RouteGraph.Edge]] = []
        for edge in edges {
            if let last = groups.last?.last,
               last.streetName == edge.streetName,
               last.facilityType == edge.facilityType,
               last.protectionLevel == edge.protectionLevel {
                groups[groups.count - 1].append(edge)
            } else {
                groups.append([edge])
            }
        }

        return groups.enumerated().map { index, group in
            let length = group.reduce(0) { $0 + $1.lengthMeters }
            let gain = group.reduce(0) { $0 + $1.elevationGainMeters }
            let avgGrade = length > 0
                ? group.reduce(0) { $0 + $1.grade * $1.lengthMeters } / length
                : 0
            let seconds = group.reduce(0) {
                $0 + CyclingSpeedModel.traversalSeconds(
                    lengthMeters: $1.lengthMeters, grade: $1.grade, bikeType: bikeType
                )
            }
            var geometry = group.first?.geometry ?? []
            for edge in group.dropFirst() {
                geometry.append(contentsOf: edge.geometry.dropFirst())
            }

            let stress = length > 0
                ? group.reduce(0) { $0 + $1.stressScore * $1.lengthMeters } / length
                : 0.5
            let representative = group.max(by: { $0.lengthMeters < $1.lengthMeters }) ?? group[0]

            return RouteSegment(
                streetName: representative.streetName,
                geometry: geometry,
                lengthMeters: length,
                estimatedSeconds: seconds,
                averageGrade: avgGrade,
                maxGrade: group.map { max(0, $0.grade) }.max() ?? 0,
                elevationGainMeters: gain,
                bikeFacilityType: representative.facilityType,
                protectionLevel: representative.protectionLevel,
                roadClass: representative.roadClass,
                surfaceType: representative.surfaceType,
                turnType: turnType(entering: groups, at: index),
                intersectionStressScore: StressModel.intersectionStress(
                    edgeStress: stress,
                    crossesRoadClass: index + 1 < groups.count ? groups[index + 1].first?.roadClass : nil
                ),
                segmentStressScore: stress,
                roadBikeSuitabilityScore: roadBikeSuitability(group, totalLength: length),
                confidenceScore: group.map(\.confidenceScore).min() ?? 0.5
            )
        }
    }

    private func turnType(entering groups: [[RouteGraph.Edge]], at index: Int) -> TurnType {
        guard index > 0,
              let previous = groups[index - 1].last, previous.geometry.count >= 2,
              let next = groups[index].first, next.geometry.count >= 2 else {
            return .straight
        }
        let inBearing = GeoMath.bearingDegrees(
            from: previous.geometry[previous.geometry.count - 2].clCoordinate,
            to: previous.geometry[previous.geometry.count - 1].clCoordinate
        )
        let outBearing = GeoMath.bearingDegrees(
            from: next.geometry[0].clCoordinate,
            to: next.geometry[1].clCoordinate
        )
        return GeoMath.turnType(fromBearing: inBearing, toBearing: outBearing)
    }

    // MARK: Scores

    /// How well the route suits a road bike (0...1): smooth pavement,
    /// no punchy spikes, decent separation from traffic.
    func roadBikeSuitability(_ edges: [RouteGraph.Edge], totalLength: Double) -> Double {
        guard totalLength > 0 else { return 0.5 }
        return weightedAverage(edges, totalLength: totalLength) { edge in
            var score = 1.0
            switch edge.surfaceType {
            case .gravel: score *= 0.35
            case .dirt: score *= 0.2
            case .cobblestone: score *= 0.4
            case .unknown: score *= 0.7
            case .paved, .asphalt, .concrete: break
            }
            if edge.grade > 0.10 { score *= 0.45 }
            else if edge.grade > 0.08 { score *= 0.6 }
            score *= 1 - edge.stressScore * 0.35
            return min(1, score)
        }
    }

    private func weightedAverage(
        _ edges: [RouteGraph.Edge],
        totalLength: Double,
        _ value: (RouteGraph.Edge) -> Double
    ) -> Double {
        guard totalLength > 0 else { return 0 }
        return edges.reduce(0) { $0 + value($1) * $1.lengthMeters } / totalLength
    }
}
