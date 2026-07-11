import SwiftUI
import MapKit

/// The mounted-phone ride screen. Route guidance owns the top of the screen;
/// metrics sit mid-stack; music stays compact at the bottom and expands into
/// a sheet. Layout honors `RideScreenCustomization`.
struct ActiveNavigationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.services) private var services

    let route: RouteCandidate

    @State private var ride: ActiveRideModel?
    @State private var showMusicSheet = false
    @State private var camera: MapCameraPosition = .automatic

    private var customization: RideScreenCustomization { appModel.rideCustomization }
    private var largerControls: Bool {
        customization.largerControlsEnabled || customization.layoutMode == .largerControls
    }
    private var musicEnabled: Bool { appModel.riderProfile.appleMusicEnabled }

    var body: some View {
        ZStack {
            if let ride {
                rideMap(ride)
                overlay(ride)
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(customization.highContrastEnabled ? .dark : nil)
        .sheet(isPresented: $showMusicSheet) {
            MusicExpandedSheet(
                music: services.musicService,
                defaultPlaylistID: appModel.riderProfile.defaultRidePlaylistID
            )
        }
        .onAppear {
            let model = ActiveRideModel(
                route: route,
                profile: appModel.riderProfile,
                locationService: services.locationService,
                routingService: services.routingService
            )
            model.start()
            ride = model
            if musicEnabled && customization.musicTrayDefaultExpanded {
                showMusicSheet = true
            }
        }
        .onDisappear {
            ride?.end()
        }
    }

    // MARK: Map

    private func rideMap(_ ride: ActiveRideModel) -> some View {
        Map(position: $camera) {
            ForEach(ride.route.segments) { segment in
                MapPolyline(coordinates: segment.geometry.map(\.clCoordinate))
                    .stroke(
                        segment.maxGrade > 0.08
                            ? LaneLineDesign.Colors.warning
                            : LaneLineDesign.Colors.primary,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)
                    )
            }
            Annotation("", coordinate: ride.currentCoordinate) {
                ZStack {
                    Circle().fill(.white).frame(width: 22, height: 22)
                    Circle().fill(LaneLineDesign.Colors.primary).frame(width: 14, height: 14)
                }
                .shadow(radius: 3)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea()
        .onChange(of: ride.progressMeters, initial: true) {
            withAnimation(.linear(duration: 1)) {
                camera = .camera(MapCamera(
                    centerCoordinate: ride.currentCoordinate,
                    distance: 900,
                    heading: ride.currentHeading,
                    pitch: 40
                ))
            }
        }
    }

    // MARK: Overlay stack

    private func overlay(_ ride: ActiveRideModel) -> some View {
        VStack(spacing: LaneLineDesign.Spacing.small) {
            ManeuverBanner(ride: ride, largerControls: largerControls)
            statusRow(ride)
            Spacer()

            if customization.layoutMode != .standard || !customization.visibleSecondaryMetrics.isEmpty {
                secondaryMetricsRow(ride)
            }
            metricsBar(ride)

            if musicEnabled && !showMusicSheet {
                MusicCompactBar(
                    music: services.musicService,
                    largerControls: largerControls
                ) {
                    showMusicSheet = true
                }
            }

            controlsRow(ride)
        }
        .padding(LaneLineDesign.Spacing.medium)
    }

    private func statusRow(_ ride: ActiveRideModel) -> some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            if ride.isRerouting {
                statusChip(text: "Rerouting…", icon: "arrow.triangle.2.circlepath", tint: LaneLineDesign.Colors.primary)
            }
            if ride.isPaused {
                statusChip(text: "Paused", icon: "pause.fill", tint: LaneLineDesign.Colors.warning)
            }
            if ride.isComplete {
                statusChip(text: "You've arrived", icon: "flag.checkered", tint: LaneLineDesign.Colors.success)
            }
            Spacer()
            statusChip(
                text: RideFormat.score(route.confidenceScore),
                icon: "checkmark.seal",
                tint: LaneLineDesign.Colors.textSecondary
            )
            .accessibilityLabel("Route confidence \(RideFormat.score(route.confidenceScore)) out of 10")
        }
    }

    private func statusChip(text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
    }

    // MARK: Metrics

    private func metricsBar(_ ride: ActiveRideModel) -> some View {
        HStack(spacing: 0) {
            ForEach(orderedPrimaryMetrics(ride), id: \.label) { metric in
                VStack(spacing: 2) {
                    Text(metric.value)
                        .font(largerControls
                            ? LaneLineDesign.Typography.metricValueLarge
                            : LaneLineDesign.Typography.metricValue)
                        .foregroundStyle(metric.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(metric.label)
                        .font(LaneLineDesign.Typography.metricLabel)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, LaneLineDesign.Spacing.medium)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
    }

    private struct PrimaryMetric {
        let label: String
        let value: String
        var tint: Color = .primary
    }

    /// `metricsPriority` puts the rider's chosen metric first (leftmost).
    private func orderedPrimaryMetrics(_ ride: ActiveRideModel) -> [PrimaryMetric] {
        let eta = PrimaryMetric(label: "ETA", value: RideFormat.eta(arrivingIn: ride.etaSeconds))
        let remaining = PrimaryMetric(label: "Remaining", value: RideFormat.distance(ride.remainingMeters))
        let climb = PrimaryMetric(
            label: "Climb left",
            value: RideFormat.elevation(ride.climbRemainingMeters),
            tint: ride.climbRemainingMeters > 40 ? LaneLineDesign.Colors.warning : .primary
        )

        switch customization.metricsPriority {
        case .time: return [eta, remaining, climb]
        case .distance: return [remaining, eta, climb]
        case .climb: return [climb, remaining, eta]
        }
    }

    private func secondaryMetricsRow(_ ride: ActiveRideModel) -> some View {
        HStack(spacing: LaneLineDesign.Spacing.medium) {
            if customization.visibleSecondaryMetrics.contains(.currentGrade) {
                secondaryChip(
                    icon: ride.currentGrade >= 0 ? "arrow.up.right" : "arrow.down.right",
                    text: RideFormat.signedGrade(ride.currentGrade),
                    tint: LaneLineDesign.Colors.grade(ride.currentGrade)
                )
                .accessibilityLabel("Current grade \(RideFormat.signedGrade(ride.currentGrade))")
            }
            if customization.visibleSecondaryMetrics.contains(.climbRemaining) {
                secondaryChip(
                    icon: "mountain.2",
                    text: RideFormat.elevation(ride.climbRemainingMeters),
                    tint: .primary
                )
            }
            if customization.visibleSecondaryMetrics.contains(.routeQuality) {
                secondaryChip(
                    icon: "shield.checkered",
                    text: RideFormat.score(route.roadBikeSuitabilityScore),
                    tint: LaneLineDesign.Colors.success
                )
            }
            if customization.visibleSecondaryMetrics.contains(.currentSpeed) {
                secondaryChip(
                    icon: "speedometer",
                    text: String(format: "%.0f km/h", ride.currentSpeedKmh),
                    tint: .primary
                )
            }
            if customization.visibleSecondaryMetrics.contains(.averageSpeed) {
                secondaryChip(
                    icon: "gauge.medium",
                    text: averageSpeedText(ride),
                    tint: .primary
                )
            }
            Spacer()
        }
    }

    private func averageSpeedText(_ ride: ActiveRideModel) -> String {
        guard ride.elapsedSeconds > 10 else { return "—" }
        let kmh = ride.progressMeters / ride.elapsedSeconds * 3.6
        return String(format: "%.0f km/h", kmh)
    }

    private func secondaryChip(icon: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
    }

    // MARK: Controls

    private func controlsRow(_ ride: ActiveRideModel) -> some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            controlButton(
                icon: ride.guidanceMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: ride.guidanceMuted ? "Unmute" : "Mute"
            ) {
                // Voice guidance is scaffolded for v1; the toggle persists so
                // the synthesis layer can respect it when it lands.
                ride.guidanceMuted.toggle()
            }

            controlButton(icon: "arrow.triangle.2.circlepath", label: "Reroute") {
                Task { await ride.reroute() }
            }

            controlButton(
                icon: ride.isPaused ? "play.fill" : "pause.fill",
                label: ride.isPaused ? "Resume" : "Pause"
            ) {
                ride.togglePause()
            }

            Button {
                ride.end()
                appModel.endRide()
            } label: {
                Label("End", systemImage: "xmark")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: largerControls
                        ? LaneLineDesign.HitTarget.large
                        : LaneLineDesign.HitTarget.comfortable)
            }
            .buttonStyle(.borderedProminent)
            .tint(LaneLineDesign.Colors.danger)
        }
    }

    private func controlButton(
        icon: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity)
                .frame(height: largerControls
                    ? LaneLineDesign.HitTarget.large
                    : LaneLineDesign.HitTarget.comfortable)
        }
        .buttonStyle(.bordered)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium))
        .accessibilityLabel(label)
    }
}

// MARK: - Maneuver Banner

/// The dominant information layer: next turn, distance to it, current and
/// upcoming street.
struct ManeuverBanner: View {
    let ride: ActiveRideModel
    let largerControls: Bool

    var body: some View {
        HStack(spacing: LaneLineDesign.Spacing.medium) {
            Image(systemName: ride.nextSegment?.turnType.systemImage ?? "flag.checkered")
                .font(.system(size: largerControls ? 44 : 36, weight: .bold))
                .frame(width: largerControls ? 64 : 52)

            VStack(alignment: .leading, spacing: 2) {
                if let next = ride.nextSegment {
                    if let distance = ride.distanceToNextTurnMeters {
                        Text(RideFormat.distance(distance))
                            .font(largerControls
                                ? LaneLineDesign.Typography.metricValueLarge
                                : LaneLineDesign.Typography.metricValue)
                    }
                    Text("\(next.turnType.displayName) onto \(next.streetName ?? "next street")")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Text(RideFormat.distance(ride.remainingMeters))
                        .font(LaneLineDesign.Typography.metricValue)
                    Text("Destination ahead")
                        .font(.subheadline.weight(.semibold))
                }
                if let street = ride.currentStreet {
                    Text("on \(street)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(LaneLineDesign.Spacing.medium)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ActiveNavigationView(route: PreviewData.sampleCandidates[0])
        .serviceContainer(.preview())
        .environment(PreviewData.appModel())
}
