import SwiftUI
import MapKit

/// Side-by-side tradeoffs for the generated candidates: shared map preview
/// up top, one card per route below. The balanced candidate wears the
/// "Recommended" badge; every card exposes the metrics that differ.
struct RouteComparisonView: View {
    let candidates: [RouteCandidate]
    let origin: CLLocationCoordinate2D
    let destination: SelectedDestination

    @State private var selectedRouteID: UUID?

    var body: some View {
        ScrollView {
            VStack(spacing: LaneLineDesign.Spacing.medium) {
                mapPreview
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))

                ForEach(candidates) { candidate in
                    NavigationLink {
                        RouteDetailView(route: candidate)
                    } label: {
                        RouteCandidateCard(
                            candidate: candidate,
                            isRecommended: candidate.strategyType == .balanced
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(LaneLineDesign.Spacing.medium)
        }
        .background(LaneLineDesign.Colors.background)
        .navigationTitle("To \(destination.name)")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView(
                    "No routes found",
                    systemImage: "map",
                    description: Text("Try a destination closer to the bike network.")
                )
            }
        }
    }

    private var mapPreview: some View {
        Map(initialPosition: .region(regionContainingAllRoutes())) {
            ForEach(candidates) { candidate in
                MapPolyline(coordinates: candidate.allCoordinates)
                    .stroke(
                        LaneLineDesign.Colors.strategy(candidate.strategyType),
                        style: StrokeStyle(
                            lineWidth: candidate.strategyType == .balanced ? 5 : 3.5,
                            lineCap: .round, lineJoin: .round
                        )
                    )
            }
            Marker("Start", systemImage: "circle.fill", coordinate: origin)
                .tint(LaneLineDesign.Colors.textSecondary)
            Marker(destination.name, coordinate: destination.coordinate)
                .tint(LaneLineDesign.Colors.danger)
        }
        .allowsHitTesting(false)
    }

    private func regionContainingAllRoutes() -> MKCoordinateRegion {
        var coordinates = candidates.flatMap(\.allCoordinates)
        coordinates.append(origin)
        coordinates.append(destination.coordinate)
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: origin, latitudinalMeters: 3000, longitudinalMeters: 3000
            )
        }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (lats.min()! + lats.max()!) / 2,
            longitude: (lons.min()! + lons.max()!) / 2
        )
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(0.01, (lats.max()! - lats.min()!) * 1.4),
                longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.4)
            )
        )
    }
}

// MARK: - Candidate Card

struct RouteCandidateCard: View {
    let candidate: RouteCandidate
    let isRecommended: Bool

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.small) {
                HStack {
                    StrategyBadge(strategy: candidate.strategyType, isRecommended: isRecommended)
                    if candidate.usedWiggleCorridor {
                        WiggleBadge()
                    }
                    Spacer()
                    Text(candidate.durationFormatted)
                        .font(LaneLineDesign.Typography.metricValue)
                        .foregroundStyle(LaneLineDesign.Colors.textPrimary)
                }

                HStack(spacing: LaneLineDesign.Spacing.large) {
                    MetricTile(label: "Distance", value: candidate.distanceFormatted, icon: "point.topleft.down.curvedto.point.bottomright.up")
                    MetricTile(label: "Climb", value: candidate.elevationGainFormatted, icon: "arrow.up.right")
                    MetricTile(
                        label: "Max grade",
                        value: candidate.maxGradeFormatted,
                        icon: "triangle",
                        tint: LaneLineDesign.Colors.grade(candidate.maxGrade)
                    )
                    MetricTile(
                        label: "Protected",
                        value: RideFormat.percent(candidate.protectedLanePercent),
                        icon: "shield.lefthalf.filled"
                    )
                }

                HStack(spacing: LaneLineDesign.Spacing.large) {
                    MetricTile(
                        label: "Bike facility",
                        value: RideFormat.percent(candidate.bikeFacilityPercent),
                        icon: "bicycle"
                    )
                    MetricTile(
                        label: "Directness",
                        value: RideFormat.percent(candidate.directnessScore),
                        icon: "arrow.triangle.swap"
                    )
                    MetricTile(
                        label: "Calories",
                        value: "\(RideFormat.wholeNumber(candidate.estimatedCalories)) kcal",
                        icon: "flame.fill"
                    )
                }

                HStack(spacing: LaneLineDesign.Spacing.large) {
                    QualityIndicator(value: candidate.roadBikeSuitabilityScore, label: "Road-bike fit")
                    QualityIndicator(value: candidate.routeStressScore, label: "Stress", higherIsBetter: false)
                    QualityIndicator(value: candidate.confidenceScore, label: "Confidence")
                }

                Text(candidate.recommendationReason)
                    .font(LaneLineDesign.Typography.caption)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let caution = candidate.cautionNotes.first {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(LaneLineDesign.Colors.warning)
                        Text(caution)
                            .font(LaneLineDesign.Typography.caption)
                            .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - Geometry helpers

extension RouteCandidate {
    /// Concatenated route geometry for map rendering.
    var allCoordinates: [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        for segment in segments {
            let segmentCoordinates = segment.geometry.map(\.clCoordinate)
            coordinates.append(contentsOf: coordinates.isEmpty
                ? segmentCoordinates
                : Array(segmentCoordinates.dropFirst()))
        }
        return coordinates
    }
}

#Preview {
    NavigationStack {
        RouteComparisonView(
            candidates: PreviewData.sampleCandidates,
            origin: PreviewData.missionOrigin,
            destination: PreviewData.ferryBuildingDestination
        )
    }
    .serviceContainer(.preview())
    .environment(PreviewData.appModel())
}
