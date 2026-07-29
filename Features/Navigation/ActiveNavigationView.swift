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
    @State private var recorder: RideRecorder?
    @State private var pageIndex = 0
    @State private var destinationRacks: [BikeParkingRack] = []
    @State private var mapMode: RideMapMode = .follow

    private enum RideMapMode {
        /// Heading-locked POV, camera re-centers every tick — the normal
        /// turn-by-turn state.
        case follow
        /// Whole route fit to bounds, free pan/pinch/rotate — the camera is
        /// left alone entirely so gestures aren't fighting an auto-recenter
        /// every second.
        case overview
    }

    private var customization: RideScreenCustomization { appModel.rideCustomization }
    private var largerControls: Bool {
        customization.largerControlsEnabled || customization.layoutMode == .largerControls
    }
    private var musicEnabled: Bool { appModel.riderProfile.appleMusicEnabled }

    var body: some View {
        ZStack {
            if let ride, let recorder {
                rideMap(ride)
                TabView(selection: $pageIndex) {
                    overlay(ride, recorder)
                        .tag(0)
                    ForEach(Array(customization.dataPages.enumerated()), id: \.element.id) { index, page in
                        RideDataPageView(
                            page: page,
                            recorder: recorder,
                            ride: ride,
                            onUpdate: { updated in
                                var c = customization
                                c.dataPages[index] = updated
                                appModel.updateCustomization(c)
                            },
                            onDeletePage: customization.dataPages.count > 1 ? {
                                var c = customization
                                c.dataPages.remove(at: index)
                                appModel.updateCustomization(c)
                                pageIndex = min(pageIndex, c.dataPages.count)
                            } : nil,
                            onAddPage: customization.dataPages.count < RideScreenCustomization.maxDataPages ? {
                                var c = customization
                                c.dataPages.append(RideDataPage(metrics: [.currentSpeed]))
                                appModel.updateCustomization(c)
                            } : nil
                        )
                        .tag(index + 1)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                .ignoresSafeArea(edges: .bottom)
                // `TabView` spans the full screen and is backed by a real
                // UIPageViewController, which — unlike plain SwiftUI empty
                // space — captures touches across its whole bounds
                // regardless of whether its current page has visible
                // content at that point. Sitting in front of the map (it
                // has to, for its own controls to be tappable), it was
                // silently absorbing every touch meant for the map below:
                // the mode-toggle button never received a tap, and map
                // pan/pinch/rotate in overview mode was very likely never
                // reaching the map either. Disabling it specifically while
                // in overview — the one mode where the rider actually wants
                // to gesture on the map instead of the ride controls — is
                // what makes both of those work.
                .allowsHitTesting(mapMode == .follow)

                mapModeToggle(ride)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, LaneLineDesign.Spacing.medium)
            } else {
                ProgressView()
            }
        }
        .preferredColorScheme(customization.highContrastEnabled ? .dark : nil)
        .sheet(isPresented: $showMusicSheet) {
            MusicNowPlayingView(
                music: services.musicService,
                lyrics: services.lyricsService,
                defaultPlaylistID: appModel.riderProfile.defaultRidePlaylistID,
                ride: ride
            )
        }
        .onAppear {
            let model = ActiveRideModel(
                route: route,
                profile: appModel.riderProfile,
                locationService: services.locationService,
                routingService: services.routingService,
                voiceGuide: RideVoiceGuide()
            )
            model.start()
            ride = model

            let rideRecorder = RideRecorder(
                profile: appModel.riderProfile,
                routeName: route.label.isEmpty ? "Ride" : route.label,
                startElevationMeters: route.segments.first?.geometry.first?.elevation,
                locationService: services.locationService,
                altimeter: AltimeterService(),
                store: services.rideStore,
                fallbackSample: { [weak model] in
                    guard let model else { return nil }
                    return RideRecorder.FallbackSample(
                        coordinate: model.currentCoordinate,
                        speedKmh: model.currentSpeedKmh,
                        altitudeMeters: model.currentElevationMeters
                    )
                }
            )
            rideRecorder.start()
            recorder = rideRecorder

            // A mounted phone must not lock mid-ride.
            UIApplication.shared.isIdleTimerDisabled = true

            if let destination = route.allCoordinates.last {
                Task {
                    destinationRacks = await services.bikeParkingService
                        .racks(near: destination, limit: 3)
                }
            }
            if musicEnabled && customization.musicTrayDefaultExpanded {
                showMusicSheet = true
            }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            if let recorder, recorder.isRecording { _ = recorder.finish() }
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
            // Bike parking near the destination, revealed on final approach.
            if ride.remainingMeters < 300 {
                ForEach(destinationRacks) { rack in
                    Annotation(rack.name, coordinate: rack.coordinate) {
                        Image(systemName: "parkingsign.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, LaneLineDesign.Colors.primary)
                            .shadow(radius: 2)
                    }
                }
            }
            // A plain SwiftUI `Annotation` stays screen-upright regardless
            // of the map's rotation (unlike geometry overlays, which rotate
            // with it) — since the camera below is already heading-locked,
            // "up on screen" already means "current direction of travel," so
            // a fixed north-pointing arrow here is already correctly
            // oriented with no extra rotation math needed.
            Annotation("", coordinate: ride.currentCoordinate) {
                ZStack {
                    Circle()
                        .fill(LaneLineDesign.Colors.primary)
                        .frame(width: 34, height: 34)
                    Circle()
                        .strokeBorder(.white, lineWidth: 3)
                        .frame(width: 34, height: 34)
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .ignoresSafeArea()
        .onChange(of: ride.progressMeters, initial: true) {
            guard mapMode == .follow else { return }
            // Duration runs a touch past the 1s tick interval so consecutive
            // camera animations always overlap slightly instead of settling
            // and re-starting each tick — that dead stop-start is what read
            // as choppy before. Ease in/out reads as far more fluid than
            // linear for the heading swing through a turn specifically.
            withAnimation(.easeInOut(duration: 1.1)) {
                camera = .camera(followCamera(ride))
            }
        }
    }

    private func followCamera(_ ride: ActiveRideModel) -> MapCamera {
        MapCamera(
            centerCoordinate: ride.currentCoordinate,
            distance: 900,
            heading: ride.displayHeading,
            pitch: 40
        )
    }

    /// North-up, whole route fit to bounds with generous padding — same
    /// bounding approach `RouteDetailView` uses for its preview map.
    private func overviewRegion(_ ride: ActiveRideModel) -> MKCoordinateRegion {
        let coordinates = ride.route.allCoordinates
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: ride.currentCoordinate,
                latitudinalMeters: 1500, longitudinalMeters: 1500
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
                latitudeDelta: max(0.01, (lats.max()! - lats.min()!) * 1.35),
                longitudeDelta: max(0.01, (lons.max()! - lons.min()!) * 1.35)
            )
        )
    }

    /// Explicit switch, not gesture-detection: tapping is the only way in
    /// or out of overview, so a mid-ride pinch to glance ahead doesn't
    /// accidentally strand the rider out of follow mode.
    private func mapModeToggle(_ ride: ActiveRideModel) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.4)) {
                switch mapMode {
                case .follow:
                    mapMode = .overview
                    camera = .region(overviewRegion(ride))
                case .overview:
                    mapMode = .follow
                    camera = .camera(followCamera(ride))
                }
            }
        } label: {
            Image(systemName: mapMode == .follow ? "map" : "location.north.line.fill")
                .font(.system(size: largerControls ? 22 : 18, weight: .semibold))
                .frame(
                    width: largerControls ? 52 : 44,
                    height: largerControls ? 52 : 44
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(LaneLineDesign.Colors.primary)
        .rideGlass(in: Circle(), interactive: true)
        .accessibilityLabel(mapMode == .follow ? "Show whole route" : "Resume turn-by-turn view")
    }

    // MARK: Overlay stack

    private func overlay(_ ride: ActiveRideModel, _ recorder: RideRecorder) -> some View {
        VStack(spacing: LaneLineDesign.Spacing.small) {
            RideGlassContainer {
                VStack(spacing: LaneLineDesign.Spacing.small) {
                    ManeuverBanner(ride: ride, largerControls: largerControls)
                    statusRow(ride)
                }
            }
            Spacer()

            RideGlassContainer {
                VStack(spacing: LaneLineDesign.Spacing.small) {
                    if customization.layoutMode != .standard || !customization.visibleSecondaryMetrics.isEmpty {
                        secondaryMetricsRow(ride, recorder)
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
            }
        }
        .padding(LaneLineDesign.Spacing.medium)
        .environment(\.prefersOpaqueRideSurfaces, customization.highContrastEnabled)
    }

    private func statusRow(_ ride: ActiveRideModel) -> some View {
        HStack(spacing: LaneLineDesign.Spacing.small) {
            if ride.isOffRoute {
                statusChip(text: "Off route", icon: "location.slash", tint: LaneLineDesign.Colors.warning)
            }
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
            .rideGlass(in: Capsule())
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
        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
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

    private func secondaryMetricsRow(_ ride: ActiveRideModel, _ recorder: RideRecorder) -> some View {
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
                    text: String(format: "%.0f km/h", recorder.currentSpeedKmh),
                    tint: .primary
                )
            }
            if customization.visibleSecondaryMetrics.contains(.averageSpeed) {
                secondaryChip(
                    icon: "gauge.medium",
                    text: recorder.movingSeconds > 10
                        ? String(format: "%.0f km/h", recorder.averageSpeedKmh) : "—",
                    tint: .primary
                )
            }
            Spacer()
        }
    }

    private func secondaryChip(icon: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .rideGlass(in: Capsule())
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
                recorder?.setPaused(ride.isPaused)
            }

            Button {
                ride.end()
                let record = recorder?.finish()
                appModel.finishRide(with: record)
            } label: {
                Label("End", systemImage: "xmark")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: largerControls
                        ? LaneLineDesign.HitTarget.large
                        : LaneLineDesign.HitTarget.comfortable)
            }
            .prominentRideButtonStyle(tint: LaneLineDesign.Colors.danger)
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
        .buttonStyle(.plain)
        .rideGlass(
            in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.medium),
            interactive: true
        )
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
                HStack(spacing: 4) {
                    Image(systemName: "location.fill")
                        .font(.caption2)
                    Text(ride.currentStreet ?? "Locating street…")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ride.currentStreet != nil ? LaneLineDesign.Colors.textSecondary : LaneLineDesign.Colors.textTertiary)
                .lineLimit(1)
            }
            Spacer()
        }
        .padding(LaneLineDesign.Spacing.medium)
        .rideGlass(in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large))
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    ActiveNavigationView(route: PreviewData.sampleCandidates[0])
        .serviceContainer(.preview())
        .environment(PreviewData.appModel())
}
