import SwiftUI

/// Elevation profile for a route, colored by grade severity per stretch.
/// Elevation series is reconstructed from segment grades and lengths, so it
/// works whether or not raw geometry carries per-vertex elevations.
struct ElevationProfileView: View {
    let route: RouteCandidate

    private var points: [ElevationChartPoint] {
        var result: [ElevationChartPoint] = []
        var distance: Double = 0
        var elevation = route.segments.first?.geometry.first?.elevation ?? 0

        result.append(ElevationChartPoint(distanceMeters: 0, elevationMeters: elevation, grade: 0))
        for segment in route.segments {
            distance += segment.lengthMeters
            elevation += segment.averageGrade * segment.lengthMeters
            result.append(ElevationChartPoint(
                distanceMeters: distance,
                elevationMeters: elevation,
                grade: segment.averageGrade
            ))
        }
        return result
    }

    var body: some View {
        ElevationChart(
            points: points,
            accessibilityText: "Elevation profile: \(RideFormat.elevation(route.totalElevationGainMeters)) total climb, "
                + "max grade \(RideFormat.grade(route.maxGrade))"
        )
    }
}
