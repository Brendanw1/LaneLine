import SwiftUI
import Charts

/// A point on an elevation chart; grade colors the line per stretch.
struct ElevationChartPoint: Identifiable {
    let id = UUID()
    let distanceMeters: Double
    let elevationMeters: Double
    let grade: Double
}

/// Reusable grade-colored elevation chart: route previews plot planned
/// segments, ride summaries plot the recorded track.
struct ElevationChart: View {
    let points: [ElevationChartPoint]
    let accessibilityText: String

    var body: some View {
        Chart(points) { point in
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
        .accessibilityLabel(accessibilityText)
    }
}
