import SwiftUI
import Charts

/// Elevation profile for a route, colored by grade severity per stretch.
/// Elevation series is reconstructed from segment grades and lengths, so it
/// works whether or not raw geometry carries per-vertex elevations.
struct ElevationProfileView: View {
    let route: RouteCandidate

    private struct ProfilePoint: Identifiable {
        let id = UUID()
        let distanceMeters: Double
        let elevationMeters: Double
        let grade: Double
    }

    private var points: [ProfilePoint] {
        var result: [ProfilePoint] = []
        var distance: Double = 0
        var elevation = route.segments.first?.geometry.first?.elevation ?? 0

        result.append(ProfilePoint(distanceMeters: 0, elevationMeters: elevation, grade: 0))
        for segment in route.segments {
            distance += segment.lengthMeters
            elevation += segment.averageGrade * segment.lengthMeters
            result.append(ProfilePoint(
                distanceMeters: distance,
                elevationMeters: elevation,
                grade: segment.averageGrade
            ))
        }
        return result
    }

    var body: some View {
        let profile = points
        Chart(profile) { point in
            AreaMark(
                x: .value("Distance", point.distanceMeters / 1000),
                y: .value("Elevation", point.elevationMeters)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [LaneLineDesign.Colors.primary.opacity(0.3), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Distance", point.distanceMeters / 1000),
                y: .value("Elevation", point.elevationMeters)
            )
            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .foregroundStyle(LaneLineDesign.Colors.grade(point.grade))
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let km = value.as(Double.self) {
                        Text(String(format: "%.1f km", km))
                            .font(LaneLineDesign.Typography.mono)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let meters = value.as(Double.self) {
                        Text("\(Int(meters)) m")
                            .font(LaneLineDesign.Typography.mono)
                    }
                }
            }
        }
        .accessibilityLabel(
            "Elevation profile: \(RideFormat.elevation(route.totalElevationGainMeters)) total climb, "
            + "max grade \(RideFormat.grade(route.maxGrade))"
        )
    }
}
