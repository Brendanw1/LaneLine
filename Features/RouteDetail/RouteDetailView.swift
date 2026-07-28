import SwiftUI
import MapKit

/// Full breakdown of one candidate: per-segment colored map, elevation
/// profile, the "why this route" explanation, and the score ledger showing
/// what was rewarded or penalized.
struct RouteDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.services) private var services
    let route: RouteCandidate

    @State private var destinationRacks: [BikeParkingRack] = []
    /// True once the docked "Start Ride" button (the real one, at the end of
    /// the scroll content) has scrolled into view — at that point the
    /// floating copy hides so the docked one takes over seamlessly.
    @State private var isDockedButtonVisible = false

    private let explanationBuilder = RouteExplanationBuilder()

    var body: some View {
        GeometryReader { screenGeometry in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.medium) {
                        segmentMap
                            .frame(height: 220)
                            .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))

                        headerCard
                        explanationCard
                        elevationCard
                        if !destinationRacks.isEmpty {
                            bikeParkingCard
                        }
                        segmentsCard
                        if let breakdown = route.scoreBreakdown {
                            scoreCard(breakdown)
                        }

                        startRideButton
                            .background(
                                GeometryReader { buttonGeometry in
                                    Color.clear.preference(
                                        key: DockedButtonPositionKey.self,
                                        value: buttonGeometry.frame(in: .global).minY
                                    )
                                }
                            )
                    }
                    .padding(LaneLineDesign.Spacing.medium)
                }
                .onPreferenceChange(DockedButtonPositionKey.self) { minY in
                    isDockedButtonVisible = minY < screenGeometry.frame(in: .global).maxY
                }

                if !isDockedButtonVisible {
                    startRideButton
                        .padding(.horizontal, LaneLineDesign.Spacing.medium)
                        .padding(.bottom, LaneLineDesign.Spacing.small)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isDockedButtonVisible)
        }
        .background(LaneLineDesign.Colors.background)
        .navigationTitle(route.label)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let destination = route.allCoordinates.last else { return }
            destinationRacks = await services.bikeParkingService.racks(near: destination, limit: 4)
        }
    }

    /// Immediately clickable the moment this screen appears (floating, until
    /// the docked copy at the true bottom of the content scrolls into view).
    private var startRideButton: some View {
        StartRideButton(title: "Start Ride", icon: "bicycle") {
            appModel.startRide(route)
        }
    }

    // MARK: Bike parking

    private var bikeParkingCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.small) {
                Label("Bike parking at destination", systemImage: "parkingsign.circle")
                    .font(LaneLineDesign.Typography.sectionHeader)
                    .foregroundStyle(LaneLineDesign.Colors.textPrimary)

                ForEach(Array(destinationRacks.enumerated()), id: \.element.id) { index, rack in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rack.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(LaneLineDesign.Colors.textPrimary)
                                .lineLimit(1)
                            Text(rackDetail(rack))
                                .font(LaneLineDesign.Typography.caption)
                                .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                        }
                        Spacer()
                        if let destination = route.allCoordinates.last {
                            Text(RideFormat.distance(
                                GeoMath.distanceMeters(from: rack.coordinate, to: destination)
                            ))
                            .font(LaneLineDesign.Typography.caption)
                            .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                        }
                    }
                    if index < destinationRacks.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func rackDetail(_ rack: BikeParkingRack) -> String {
        var parts = ["\(rack.spaces) spaces"]
        if let placement = rack.placement { parts.append(placement.lowercased()) }
        if rack.name != rack.address, !rack.address.isEmpty { parts.append(rack.address) }
        return parts.joined(separator: " · ")
    }

    // MARK: Map

    /// Route drawn per segment: color encodes traffic protection, and steep
    /// stretches get warning markers.
    private var segmentMap: some View {
        Map(initialPosition: .region(routeRegion)) {
            ForEach(route.segments) { segment in
                MapPolyline(coordinates: segment.geometry.map(\.clCoordinate))
                    .stroke(
                        segmentColor(segment),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
            }
            ForEach(steepSegments) { segment in
                if let midpoint = segment.geometry[safe: segment.geometry.count / 2] {
                    Annotation(
                        "\(RideFormat.grade(segment.maxGrade))",
                        coordinate: midpoint.clCoordinate
                    ) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(LaneLineDesign.Colors.warning)
                            .clipShape(Circle())
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var steepSegments: [RouteSegment] {
        route.segments.filter { $0.maxGrade > 0.08 }
    }

    private func segmentColor(_ segment: RouteSegment) -> Color {
        switch (segment.bikeFacilityType, segment.protectionLevel) {
        case (.offStreetPath, _), (_, .fullyProtected):
            return LaneLineDesign.Colors.saferRoute
        case (_, .buffered), (_, .standard):
            return LaneLineDesign.Colors.primary
        default:
            return segment.segmentStressScore > 0.55
                ? LaneLineDesign.Colors.danger
                : LaneLineDesign.Colors.textSecondary
        }
    }

    private var routeRegion: MKCoordinateRegion {
        let coordinates = route.allCoordinates
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 37.7702, longitude: -122.4270),
                latitudinalMeters: 3000, longitudinalMeters: 3000
            )
        }
        let lats = coordinates.map(\.latitude)
        let lons = coordinates.map(\.longitude)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (lats.min()! + lats.max()!) / 2,
                longitude: (lons.min()! + lons.max()!) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.008, (lats.max()! - lats.min()!) * 1.4),
                longitudeDelta: max(0.008, (lons.max()! - lons.min()!) * 1.4)
            )
        )
    }

    // MARK: Cards

    private var headerCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.medium) {
                HStack {
                    StrategyBadge(
                        strategy: route.strategyType,
                        isRecommended: route.strategyType == .balanced
                    )
                    Spacer()
                    Text("ETA \(RideFormat.eta(arrivingIn: route.etaSeconds))")
                        .font(LaneLineDesign.Typography.caption)
                        .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                }

                HStack(spacing: LaneLineDesign.Spacing.large) {
                    MetricTile(label: "Time", value: route.durationFormatted, icon: "clock")
                    MetricTile(label: "Distance", value: route.distanceFormatted, icon: "point.topleft.down.curvedto.point.bottomright.up")
                    MetricTile(label: "Climb", value: route.elevationGainFormatted, icon: "arrow.up.right")
                    MetricTile(
                        label: "Max grade",
                        value: route.maxGradeFormatted,
                        icon: "triangle",
                        tint: LaneLineDesign.Colors.grade(route.maxGrade)
                    )
                }

                HStack(spacing: LaneLineDesign.Spacing.large) {
                    QualityIndicator(value: route.roadBikeSuitabilityScore, label: "Road-bike fit")
                    QualityIndicator(value: route.routeStressScore, label: "Stress", higherIsBetter: false)
                    QualityIndicator(value: route.confidenceScore, label: "Confidence")
                }

                HStack {
                    RouteMetricRow(
                        label: "On protected lanes or paths",
                        value: RideFormat.percent(route.protectedLanePercent),
                        icon: "shield.lefthalf.filled"
                    )
                }
                RouteMetricRow(
                    label: "On any bike facility",
                    value: RideFormat.percent(route.bikeFacilityPercent),
                    icon: "bicycle"
                )
                RouteMetricRow(
                    label: "Directness",
                    value: RideFormat.percent(route.directnessScore),
                    icon: "arrow.triangle.swap"
                )
            }
        }
    }

    private var explanationCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.small) {
                Label("Why this route", systemImage: "lightbulb")
                    .font(LaneLineDesign.Typography.sectionHeader)
                    .foregroundStyle(LaneLineDesign.Colors.textPrimary)

                Text(explanationBuilder.detailExplanation(for: route, profile: appModel.riderProfile))
                    .font(.subheadline)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !route.cautionNotes.isEmpty {
                    Divider()
                    ForEach(route.cautionNotes, id: \.self) { note in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(LaneLineDesign.Colors.warning)
                                .padding(.top, 2)
                            Text(note)
                                .font(LaneLineDesign.Typography.caption)
                                .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var elevationCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.small) {
                Label("Elevation", systemImage: "mountain.2")
                    .font(LaneLineDesign.Typography.sectionHeader)
                    .foregroundStyle(LaneLineDesign.Colors.textPrimary)
                ElevationProfileView(route: route)
                    .frame(height: 140)
            }
        }
    }

    private var segmentsCard: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.small) {
                Label("Turn by turn", systemImage: "list.bullet")
                    .font(LaneLineDesign.Typography.sectionHeader)
                    .foregroundStyle(LaneLineDesign.Colors.textPrimary)

                ForEach(Array(route.segments.enumerated()), id: \.element.id) { index, segment in
                    SegmentRow(index: index, segment: segment)
                    if index < route.segments.count - 1 {
                        Divider()
                    }
                }
            }
        }
    }

    private func scoreCard(_ breakdown: RouteScoreBreakdown) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: LaneLineDesign.Spacing.small) {
                Label("Score ledger", systemImage: "plus.forwardslash.minus")
                    .font(LaneLineDesign.Typography.sectionHeader)
                    .foregroundStyle(LaneLineDesign.Colors.textPrimary)

                scoreRow("Travel time", breakdown.travelTimeScore, positive: true)
                scoreRow("Protected lanes", breakdown.protectedLaneBonus, positive: true)
                scoreRow("Bike lanes", breakdown.bikeLaneBonus, positive: true)
                scoreRow("Car-free paths", breakdown.offStreetBonus, positive: true)
                scoreRow("Climbing", breakdown.climbPenalty, positive: false)
                scoreRow("Max grade", breakdown.maxGradePenalty, positive: false)
                scoreRow("Arterial exposure", breakdown.arterialPenalty, positive: false)
                scoreRow("Rough surface", breakdown.roughSurfacePenalty, positive: false)
                scoreRow("Stressful crossings", breakdown.crossingPenalty, positive: false)
                scoreRow("Detour", breakdown.detourPenalty, positive: false)
                scoreRow("Steep descents", breakdown.descentPenalty, positive: false)

                Divider()
                HStack {
                    Text("Overall")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(LaneLineDesign.Colors.textPrimary)
                    Spacer()
                    Text(String(format: "%+.1f", breakdown.finalScore))
                        .font(LaneLineDesign.Typography.metricValue)
                        .foregroundStyle(
                            breakdown.finalScore >= 0
                                ? LaneLineDesign.Colors.success
                                : LaneLineDesign.Colors.warning
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func scoreRow(_ label: String, _ value: Double, positive: Bool) -> some View {
        if value > 0.005 {
            HStack {
                Text(label)
                    .font(LaneLineDesign.Typography.caption)
                    .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                Spacer()
                Text(String(format: positive ? "+%.1f" : "−%.1f", value))
                    .font(LaneLineDesign.Typography.mono)
                    .foregroundStyle(
                        positive ? LaneLineDesign.Colors.success : LaneLineDesign.Colors.danger
                    )
            }
        }
    }
}

// MARK: - Segment Row

private struct SegmentRow: View {
    let index: Int
    let segment: RouteSegment

    var body: some View {
        HStack(spacing: LaneLineDesign.Spacing.medium) {
            Image(systemName: segment.turnType.systemImage)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(LaneLineDesign.Colors.primary)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(maneuverText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(LaneLineDesign.Colors.textPrimary)

                HStack(spacing: LaneLineDesign.Spacing.small) {
                    FacilityBadge(
                        facility: segment.bikeFacilityType,
                        protection: segment.protectionLevel
                    )
                    Text(RideFormat.distance(segment.lengthMeters))
                        .font(LaneLineDesign.Typography.caption)
                        .foregroundStyle(LaneLineDesign.Colors.textSecondary)
                    if segment.averageGrade > 0.02 {
                        Label(
                            RideFormat.grade(segment.maxGrade),
                            systemImage: "arrow.up.right"
                        )
                        .font(LaneLineDesign.Typography.caption)
                        .foregroundStyle(LaneLineDesign.Colors.grade(segment.maxGrade))
                    }
                }
            }

            Spacer()

            Circle()
                .fill(LaneLineDesign.Colors.stress(segment.segmentStressScore))
                .frame(width: 10, height: 10)
                .accessibilityLabel(
                    "Stress level \(RideFormat.score(segment.segmentStressScore)) of 10"
                )
        }
        .padding(.vertical, 2)
    }

    private var maneuverText: String {
        let street = segment.streetName ?? "unnamed street"
        return index == 0 ? "Start on \(street)" : "\(segment.turnType.displayName) onto \(street)"
    }
}

// MARK: - Safe indexing

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Docked button tracking

/// Global-space minY of the docked "Start Ride" button, reported up from
/// inside the scroll content so the floating copy knows when to hide.
private struct DockedButtonPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    NavigationStack {
        RouteDetailView(route: PreviewData.sampleCandidates[0])
    }
    .serviceContainer(.preview())
    .environment(PreviewData.appModel())
}
