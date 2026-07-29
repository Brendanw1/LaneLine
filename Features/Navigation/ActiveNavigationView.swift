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
    @State private var isFollowSuspended = false
    @State private var lastCommandedCamera: MapCamera?

    /// Beyond any of these, a settled camera that doesn't match what we
    /// last commanded ourselves is treated as a user gesture, not our own
    /// animation completing.
    private static let followSuspendDistanceEpsilonMeters: Double = 15
    private static let followSuspendHeadingEpsilonDegrees: Double = 8
    private static let followSuspendZoomEpsilonMeters: Double = 200
    @State private var recorder: RideRecorder?
    @State private var pageIndex = 0
    @State private var destinationRacks: [BikeParkingRack] = []
    @State private var showOverviewSheet = false

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

                trailingMapControls(ride)
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
                defaultPlaylistID: appModel.riderProfile.defaultRidePlaylistID
            )
        }
        .sheet(isPresented: $showOverviewSheet) {
            if let ride, let recorder {
                RouteOverviewSheet(
                    ride: ride,
                    recorder: recorder,
                    largerControls: largerControls,
                    onEndRide: { record in appModel.finishRide(with: record) }
                )
            }
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
            guard !isFollowSuspended else { return }
            // Duration runs a touch past the 1s tick interval so consecutive
            // camera animations always overlap slightly instead of settling
            // and re-starting each tick — that dead stop-start is what read
            // as choppy before. Ease in/out reads as far more fluid than
            // linear for the heading swing through a turn specifically.
            commitFollowCamera(ride, animation: .easeInOut(duration: 1.1))
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            guard let lastCommandedCamera else { return }
            let driftMeters = GeoMath.distanceMeters(
                from: context.camera.centerCoordinate, to: lastCommandedCamera.centerCoordinate
            )
            let headingDriftDegrees = abs(GeoMath.turnAngleDegrees(
                fromBearing: lastCommandedCamera.heading, toBearing: context.camera.heading
            ))
            let zoomDriftMeters = abs(context.camera.distance - lastCommandedCamera.distance)
            if driftMeters > Self.followSuspendDistanceEpsilonMeters
                || headingDriftDegrees > Self.followSuspendHeadingEpsilonDegrees
                || zoomDriftMeters > Self.followSuspendZoomEpsilonMeters {
                isFollowSuspended = true
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

    /// Every programmatic camera write goes through here so
    /// `onMapCameraChange` always has a ground truth to diff a settled
    /// camera against — the only way a discrepancy can appear is a user
    /// gesture, since nothing else ever touches `camera` directly.
    private func commitFollowCamera(_ ride: ActiveRideModel, animation: Animation) {
        let target = followCamera(ride)
        lastCommandedCamera = target
        withAnimation(animation) {
            camera = .camera(target)
        }
    }

    /// Opens the route overview as a separate modal sheet rather than
    /// toggling this same Map's mode in place. That in-place toggle was
    /// rebuilt three times this session (disabling TabView's hit-testing,
    /// not rendering TabView at all, forcing the Map's camera controller to
    /// reset) and something about sharing one Map/camera binding between
    /// follow and overview kept breaking the return trip regardless. A
    /// sheet sidesteps the whole question: it gets its own Map with no
    /// shared camera state, and dismissal (drag down or the button inside)
    /// is SwiftUI's own well-tested mechanism rather than custom toggle
    /// logic — the ride screen underneath never changes mode at all.
    private var mapModeToggle: some View {
        Button {
            showOverviewSheet = true
        } label: {
            Image(systemName: "map")
                .font(.system(size: largerControls ? 22 : 18, weight: .semibold))
                .frame(
                    width: largerControls ? 52 : 44,
                    height: largerControls ? 52 : 44
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(LaneLineDesign.Colors.primary)
        .rideGlass(in: Circle(), interactive: true)
        .accessibilityLabel("Show whole route")
    }

    private func trailingMapControls(_ ride: ActiveRideModel) -> some View {
        VStack(spacing: LaneLineDesign.Spacing.small) {
            if isFollowSuspended {
                recenterButton(ride)
            }
            mapModeToggle
        }
    }

    /// Appears only while a manual pan/rotate/pinch has suspended auto-
    /// follow (see `onMapCameraChange` on `rideMap`). Tapping it resumes
    /// follow and snaps the camera back onto the rider.
    private func recenterButton(_ ride: ActiveRideModel) -> some View {
        Button {
            isFollowSuspended = false
            commitFollowCamera(ride, animation: .easeInOut(duration: 0.6))
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: largerControls ? 22 : 18, weight: .semibold))
                .frame(
                    width: largerControls ? 52 : 44,
                    height: largerControls ? 52 : 44
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(LaneLineDesign.Colors.primary, in: Circle())
        .accessibilityLabel("Recenter map on your position")
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

// MARK: - Route Overview Sheet

/// The whole-route view, presented modally. A separate `Map` instance with
/// its own camera state — no bindings shared with the turn-by-turn map
/// underneath — so panning and pinching here can never affect, or get
/// affected by, the live ride screen. Dismissal (drag down, or "Resume
/// Navigation") is plain `dismiss()`; the ride screen was never touched
/// while this was up, so there's nothing to restore.
private struct RouteOverviewSheet: View {
    let ride: ActiveRideModel
    let recorder: RideRecorder
    let largerControls: Bool
    let onEndRide: (RideRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition

    init(ride: ActiveRideModel, recorder: RideRecorder, largerControls: Bool, onEndRide: @escaping (RideRecord) -> Void) {
        self.ride = ride
        self.recorder = recorder
        self.largerControls = largerControls
        self.onEndRide = onEndRide
        _camera = State(initialValue: .region(Self.region(fittingRoute: ride.route, fallbackCenter: ride.currentCoordinate)))
    }

    var body: some View {
        ZStack {
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
                        Circle().fill(LaneLineDesign.Colors.primary).frame(width: 30, height: 30)
                        Circle().strokeBorder(.white, lineWidth: 3).frame(width: 30, height: 30)
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .ignoresSafeArea()

            VStack {
                Spacer()
                VStack(spacing: LaneLineDesign.Spacing.small) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Resume Navigation", systemImage: "location.north.line.fill")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: largerControls
                                ? LaneLineDesign.HitTarget.large
                                : LaneLineDesign.HitTarget.comfortable)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(
                        LaneLineDesign.Colors.primary,
                        in: RoundedRectangle(cornerRadius: LaneLineDesign.CornerRadius.large)
                    )

                    Button {
                        ride.end()
                        let record = recorder.finish()
                        dismiss()
                        onEndRide(record)
                    } label: {
                        Label("End Ride", systemImage: "xmark")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(height: largerControls
                                ? LaneLineDesign.HitTarget.large
                                : LaneLineDesign.HitTarget.comfortable)
                    }
                    .prominentRideButtonStyle(tint: LaneLineDesign.Colors.danger)
                }
                .padding(LaneLineDesign.Spacing.medium)
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// North-up, whole route fit to bounds with generous padding — same
    /// bounding approach `RouteDetailView` uses for its preview map.
    private static func region(
        fittingRoute route: RouteCandidate, fallbackCenter: CLLocationCoordinate2D
    ) -> MKCoordinateRegion {
        let coordinates = route.allCoordinates
        guard !coordinates.isEmpty else {
            return MKCoordinateRegion(
                center: fallbackCenter,
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
