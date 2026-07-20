import SwiftUI
import MapKit

/// Post-ride summary: the recorded track on a map, the totals grid, and the
/// traveled elevation profile. Presented with save/discard at ride end, and
/// read-only (nil actions) from ride history.
struct RideSummaryView: View {
    let record: RideRecord
    var onSave: (() -> Void)?
    var onDiscard: (() -> Void)?

    private var summary: RideSummary { record.summary }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: LaneLineDesign.Spacing.medium) {
                    trackMap
                    statsGrid
                    if elevationPoints.count >= 2 {
                        ElevationChart(
                            points: elevationPoints,
                            accessibilityText: "Ride elevation: \(RideFormat.elevation(summary.ascentMeters)) climbed"
                        )
                        .frame(height: 140)
                        .padding(.horizontal, LaneLineDesign.Spacing.medium)
                    }
                }
                .padding(.vertical, LaneLineDesign.Spacing.medium)
            }
            .navigationTitle(summary.routeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onDiscard {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Discard", role: .destructive, action: onDiscard)
                    }
                }
                if let onSave {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save ride", action: onSave)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: Map

    private var trackCoordinates: [CLLocationCoordinate2D] {
        record.samples.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private var trackMap: some View {
        Map {
            MapPolyline(coordinates: trackCoordinates)
                .stroke(
                    LaneLineDesign.Colors.primary,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .padding(.horizontal, LaneLineDesign.Spacing.medium)
        .allowsHitTesting(false)
    }

    // MARK: Stats

    private struct Stat: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    private var stats: [Stat] {
        [
            Stat(label: "Distance", value: RideFormat.distance(summary.distanceMeters)),
            Stat(label: "Moving time", value: RideFormat.stopwatch(summary.movingSeconds)),
            Stat(label: "Elapsed", value: RideFormat.stopwatch(summary.durationSeconds)),
            Stat(label: "Avg speed", value: "\(RideFormat.speedValue(summary.averageSpeedKmh)) km/h"),
            Stat(label: "Max speed", value: "\(RideFormat.speedValue(summary.maxSpeedKmh)) km/h"),
            Stat(label: "Ascent", value: RideFormat.elevation(summary.ascentMeters)),
            Stat(label: "Descent", value: RideFormat.elevation(summary.descentMeters)),
            Stat(label: "Calories", value: "\(RideFormat.wholeNumber(summary.calories)) kcal"),
        ]
    }

    private var statsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible())],
            spacing: LaneLineDesign.Spacing.small
        ) {
            ForEach(stats) { stat in
                VStack(spacing: 2) {
                    Text(stat.value)
                        .font(LaneLineDesign.Typography.metricValue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(stat.label)
                        .font(LaneLineDesign.Typography.metricLabel)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                .background(
                    LaneLineDesign.Colors.surface,
                    in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium)
                )
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, LaneLineDesign.Spacing.medium)
    }

    // MARK: Elevation

    private var elevationPoints: [ElevationChartPoint] {
        record.samples.filter { $0.altitudeMeters != nil }.map {
            ElevationChartPoint(
                distanceMeters: $0.distanceMeters,
                elevationMeters: $0.altitudeMeters ?? 0,
                grade: $0.gradeDecimal ?? 0
            )
        }
    }
}
