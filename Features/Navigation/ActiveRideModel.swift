import Foundation
import CoreLocation
import Observation

/// Live state for an active ride. Progress comes from CoreLocation when the
/// rider has a fix near the route; a sustained fix far from the route flips
/// into off-route handling (freeze, announce, auto-reroute from the rider's
/// real position). Without any fix (simulator, demo) a simulation engine
/// advances along the geometry at bike-appropriate speeds. Turn-by-turn
/// voice guidance speaks through `RideVoiceGuiding`, ducking music.
@MainActor
@Observable
final class ActiveRideModel {
    // MARK: State

    private(set) var route: RouteCandidate
    private(set) var progressMeters: Double = 0
    private(set) var elapsedSeconds: Double = 0
    private(set) var isPaused = false
    private(set) var isRerouting = false
    private(set) var isOffRoute = false
    private(set) var rerouteFailed = false
    /// True while there is no usable position: permission denied/revoked,
    /// or authorized but still waiting on (or lost) the fix on a real
    /// device. Progress freezes and the ride screen must say so instead
    /// of simulating movement.
    private(set) var isLocationUnavailable = false
    var guidanceMuted = false {
        didSet {
            voiceGuide?.isMuted = guidanceMuted
        }
    }

    // MARK: Derived metrics

    var totalMeters: Double { flattened.last?.cumulative ?? 0 }
    var remainingMeters: Double { max(0, totalMeters - progressMeters) }
    var fractionComplete: Double { totalMeters > 0 ? progressMeters / totalMeters : 0 }
    /// An empty / zero-length route is not "complete" — it's degenerate
    /// and shouldn't auto-fire the arrival phrase. The route shouldn't
    /// reach the ride screen in this state in practice, but defending
    /// here means a malformed route gets the same treatment as an
    /// out-of-route stall rather than a premature "You've arrived" UI.
    var isComplete: Bool { totalMeters > 0 && remainingMeters < 10 }

    var currentCoordinate: CLLocationCoordinate2D {
        interpolatedPosition(at: progressMeters)?.coordinate
            ?? route.allCoordinates.first
            ?? CLLocationCoordinate2D(latitude: 37.7702, longitude: -122.4270)
    }

    /// Camera/marker heading — course-first while moving (real GPS travel
    /// direction, immune to the phone's compass being noisy on a bike
    /// mount), falling back to compass heading and finally route bearing
    /// only once course has genuinely gone stale. See
    /// `NavigationOrientationEngine` for the full fusion/smoothing policy;
    /// this just returns the smoothed result it produces.
    var displayHeading: Double { orientationEngine.displayBearing }

    /// Which signal is currently driving `displayHeading` — exposed for
    /// testing the tick-loop wiring end to end.
    var orientationSource: OrientationSource { orientationEngine.activeSource }

    private let orientationEngine = NavigationOrientationEngine(initialBearing: 0)

    private func refreshOrientation(deltaSeconds: Double) {
        let location = locationService.currentLocation
        orientationEngine.update(
            speedMetersPerSecond: location?.speed,
            course: location?.course,
            heading: locationService.currentHeading,
            headingAccuracy: locationService.currentHeadingAccuracy,
            routeBearing: routeBearingHeading,
            deltaSeconds: deltaSeconds
        )
    }

    private var routeBearingHeading: Double {
        guard let current = point(at: progressMeters),
              let ahead = point(at: progressMeters + 25),
              current.cumulative < ahead.cumulative else { return 0 }
        return GeoMath.bearingDegrees(
            from: current.coordinate.clCoordinate,
            to: ahead.coordinate.clCoordinate
        )
    }

    /// Route elevation at the current position — the demo/no-fix fallback
    /// altitude for ride recording.
    var currentElevationMeters: Double? {
        interpolatedPosition(at: progressMeters)?.elevation
    }

    var currentSegment: RouteSegment? {
        guard let index = currentSegmentIndex else { return nil }
        return route.segments[safe: index]
    }

    var nextSegment: RouteSegment? {
        guard let index = currentSegmentIndex else { return nil }
        return route.segments[safe: index + 1]
    }

    var currentGrade: Double { currentSegment?.averageGrade ?? 0 }

    /// Falls back to the nearest named segment behind or ahead when the
    /// current one has no name — the bundled city-wide OSM network (unlike
    /// the old hand-curated demo corridors) has plenty of short unnamed
    /// connectors and alleys, and "no street shown at all" while riding
    /// through one of those is worse than naming the street you're
    /// physically still on.
    var currentStreet: String? {
        guard let index = currentSegmentIndex else { return nil }
        if let name = route.segments[safe: index]?.streetName, !name.isEmpty { return name }
        for offset in 1...10 {
            if let name = route.segments[safe: index - offset]?.streetName, !name.isEmpty {
                return name
            }
            if let name = route.segments[safe: index + offset]?.streetName, !name.isEmpty {
                return name
            }
        }
        return nil
    }

    var distanceToNextTurnMeters: Double? {
        guard let index = currentSegmentIndex, index + 1 < route.segments.count else { return nil }
        let boundary = segmentBoundaries[safe: index + 1] ?? totalMeters
        return max(0, boundary - progressMeters)
    }

    /// Remaining climbing, from the untraveled part of the route.
    var climbRemainingMeters: Double {
        guard let index = currentSegmentIndex else { return 0 }
        var remaining = route.segments.dropFirst(index + 1)
            .reduce(0) { $0 + $1.elevationGainMeters }
        if let segment = currentSegment {
            let boundary = segmentBoundaries[safe: index] ?? 0
            let intoSegment = progressMeters - boundary
            // Clamp into [0, 1] so a snap that places progress before the
            // current segment's boundary (e.g. right after a reroute)
            // can't drive `fractionLeft` above 1 and over-report the
            // remaining climb on this segment.
            let fractionLeft = segment.lengthMeters > 0
                ? min(1, max(0, 1 - intoSegment / segment.lengthMeters))
                : 0
            remaining += segment.elevationGainMeters * fractionLeft
        }
        return remaining
    }

    var etaSeconds: Double {
        guard totalMeters > 0 else { return 0 }
        return route.etaSeconds * (remainingMeters / totalMeters)
    }

    var currentSpeedKmh: Double {
        isPaused ? 0 : CyclingSpeedModel.speedKmh(bikeType: bikeType, grade: currentGrade)
    }

    // MARK: Internals

    private struct FlattenedPoint {
        let coordinate: RouteCoordinate
        let cumulative: Double
        let segmentIndex: Int
    }

    private var flattened: [FlattenedPoint] = []
    private var segmentBoundaries: [Double] = []
    /// Cell index keyed by ~75 m of latitude (~0.00067°), so any location
    /// snap only walks the handful of route vertices that fall in the
    /// rider's cell and the 8 neighbours — O(1) instead of O(n) over the
    /// full flattened polyline at every tick. Rebuilt on every
    /// `rebuildGeometry()` since the route can change at start or reroute.
    private var flattenedGrid: [GridKey: [Int]] = [:]
    private let bikeType: BikeType
    private let profile: RiderProfile
    private var tickTask: Task<Void, Never>?

    private let locationService: any LocationServicing
    private let routingService: any RoutingServiceProtocol
    private let voiceGuide: (any RideVoiceGuiding)?
    private let liveActivity = RideLiveActivityController()

    /// Location fixes farther than this from the route count as off-route.
    private let liveTrackingToleranceMeters: Double = 150
    /// Sustained off-route time before an automatic re-plan (and between
    /// retries when re-planning keeps failing).
    private let offRouteRerouteAfterSeconds: Double = 10
    private var offRouteSeconds: Double = 0

    // Announcement bookkeeping, keyed by upcoming segment index.
    private var announcedApproach: Set<Int> = []
    private var announcedImminent: Set<Int> = []
    private var announcedStart = false
    private var announcedArrival = false
    /// Destination approach phrases fire once per threshold as the rider
    /// closes in on the endpoint — separate flags so a reroute near the
    /// destination re-fires both phrases (the rider clearly needs the
    /// reminder after their route changed), but the same ride doesn't
    /// re-fire them on every tick once the distance dips under 500m.
    private var announcedDestinationApproach500 = false
    private var announcedDestinationApproach100 = false
    /// The turnKey the most recently queued approach/imminent phrase was
    /// about. `AVSpeechSynthesizer.speak()` queues rather than interrupts,
    /// so on a route with short blocks a still-queued phrase for turn N can
    /// outlive the moment turn N+1 becomes current — it would then play out
    /// loud describing a turn that's no longer next, contradicting whatever
    /// the screen shows by then. Cancelling before announcing a *different*
    /// turnKey keeps only the freshest instruction ever audible.
    private var lastAnnouncedTurnKey: Int?

    init(
        route: RouteCandidate,
        profile: RiderProfile,
        locationService: any LocationServicing,
        routingService: any RoutingServiceProtocol,
        voiceGuide: (any RideVoiceGuiding)? = nil
    ) {
        self.route = route
        self.profile = profile
        self.bikeType = profile.bikeType
        self.locationService = locationService
        self.routingService = routingService
        self.voiceGuide = voiceGuide
        rebuildGeometry()
    }

    private func rebuildGeometry() {
        flattened = []
        segmentBoundaries = []
        flattenedGrid = [:]
        var cumulative: Double = 0

        for (segmentIndex, segment) in route.segments.enumerated() {
            segmentBoundaries.append(cumulative)
            let coordinates = segment.geometry
            for (index, coordinate) in coordinates.enumerated() {
                if index > 0 {
                    cumulative += GeoMath.distanceMeters(from: coordinates[index - 1], to: coordinate)
                }
                if flattened.isEmpty || index > 0 {
                    flattened.append(FlattenedPoint(
                        coordinate: coordinate,
                        cumulative: cumulative,
                        segmentIndex: segmentIndex
                    ))
                }
            }
        }
        rebuildGrid()
    }

    /// Populate the spatial cell index used by `snapToRoute`. Each
    /// vertex is added to its own cell; lookups walk the cell and the 8
    /// neighbours so a fix near a cell boundary still finds every nearby
    /// route vertex without scanning the full polyline.
    private func rebuildGrid() {
        for (index, point) in flattened.enumerated() {
            let key = Self.gridKey(for: point.coordinate.clCoordinate)
            flattenedGrid[key, default: []].append(index)
        }
    }

    private static let gridCellDegrees: Double = 0.00067  // ~75 m latitude
    private typealias GridKey = Int  // packed: (latCell << 16) | lonCell

    private static func gridKey(for coordinate: CLLocationCoordinate2D) -> GridKey {
        let latCell = Int((coordinate.latitude / gridCellDegrees).rounded())
        let lonCell = Int((coordinate.longitude / gridCellDegrees).rounded())
        return (latCell << 16) ^ lonCell
    }

    private var currentSegmentIndex: Int? {
        point(at: progressMeters)?.segmentIndex
    }

    private func point(at distance: Double) -> FlattenedPoint? {
        guard !flattened.isEmpty else { return nil }
        return flattened.last(where: { $0.cumulative <= distance }) ?? flattened.first
    }

    /// Position lerped between route vertices. Vertices in the sample
    /// network can sit hundreds of meters apart, so snapping to the last
    /// vertex would make the simulated position (and everything fed from
    /// it — the map dot, demo ride recording) advance in giant hops.
    private func interpolatedPosition(
        at distance: Double
    ) -> (coordinate: CLLocationCoordinate2D, elevation: Double?)? {
        guard let lower = point(at: distance) else { return nil }
        guard let upper = flattened.first(where: { $0.cumulative > distance }),
              upper.cumulative > lower.cumulative else {
            return (lower.coordinate.clCoordinate, lower.coordinate.elevation)
        }
        let fraction = (distance - lower.cumulative) / (upper.cumulative - lower.cumulative)
        let f = min(1, max(0, fraction))
        let coordinate = CLLocationCoordinate2D(
            latitude: lower.coordinate.latitude
                + (upper.coordinate.latitude - lower.coordinate.latitude) * f,
            longitude: lower.coordinate.longitude
                + (upper.coordinate.longitude - lower.coordinate.longitude) * f
        )
        let elevation: Double?
        if let a = lower.coordinate.elevation, let b = upper.coordinate.elevation {
            elevation = a + (b - a) * f
        } else {
            elevation = lower.coordinate.elevation
        }
        return (coordinate, elevation)
    }

    // MARK: Lifecycle

    func start() {
        guard tickTask == nil else { return }
        locationService.startUpdating()
        // Seed at the real starting direction rather than the engine's
        // default, so the first camera frame doesn't spin in from due north.
        orientationEngine.seed(bearing: locationService.currentHeading ?? routeBearingHeading)
        liveActivity.start(routeLabel: route.label, state: activityState())
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick(deltaSeconds: 1)
            }
        }
    }

    func togglePause() {
        isPaused.toggle()
    }

    func end() {
        tickTask?.cancel()
        tickTask = nil
        voiceGuide?.stopSpeaking()
        locationService.stopUpdating()
        liveActivity.end()
    }

    /// Real system Dynamic Island / Lock Screen content — mirrors exactly
    /// what `ManeuverBanner` shows on screen (same next-turn/distance/
    /// current-street source), so the two can never say different things.
    private func activityState() -> RideActivityAttributes.ContentState {
        if let next = nextSegment, let distance = distanceToNextTurnMeters {
            return RideActivityAttributes.ContentState(
                turnSystemImageName: next.turnType.systemImage,
                turnInstruction: "\(next.turnType.displayName) onto \(next.streetName ?? "next street")",
                distanceToTurnText: RideFormat.distance(distance),
                currentStreet: currentStreet ?? ""
            )
        }
        return RideActivityAttributes.ContentState(
            turnSystemImageName: "flag.checkered",
            turnInstruction: "Destination ahead",
            distanceToTurnText: RideFormat.distance(remainingMeters),
            currentStreet: currentStreet ?? ""
        )
    }

    /// Re-plan to the route's destination using the same strategy, from the
    /// rider's real position when there is a fix (they may have left the
    /// line), otherwise from the route position. Sets `rerouteFailed` when
    /// planning throws or returns nothing, so the ride screen can say so
    /// instead of dropping back to silence.
    func reroute() async {
        guard let destination = route.allCoordinates.last, !isRerouting else { return }
        isRerouting = true
        defer { isRerouting = false }

        let origin = locationService.currentLocation?.coordinate ?? currentCoordinate
        do {
            guard let fresh = try await routingService.generateRoutes(
                from: origin,
                to: destination,
                profile: profile,
                strategies: [route.strategyType]
            ).first else {
                rerouteFailed = true
                return
            }
            rerouteFailed = false
            // `AVSpeechSynthesizer.speak()` queues rather than interrupts, so
            // an "approach"/"imminent" announcement generated from the *old*
            // route can still be sitting queued here — if left alone, it
            // plays out loud after this reroute completes, describing a turn
            // that no longer exists while the screen already shows the new
            // route. Flushing it is the fix for "voice said a different turn
            // than the screen."
            voiceGuide?.stopSpeaking()
            route = fresh
            rebuildGeometry()
            // Snap progress to the rider's actual position on the new
            // route rather than resetting to 0 — the rider is physically
            // partway through their trip, and showing them at the *start*
            // of the new route would make the dot jump backwards and the
            // camera spin to the corridor's origin. If the snap lands
            // within tolerance, the rider is on the new route and we
            // resume tracking from their position. If not, we keep them
            // at the route's start (the closest the new route gets to
            // their current position) and mark off-route so the next tick
            // can decide whether to plan again — never silently resume
            // progress on a route the rider isn't actually on.
            if let snapped = snapToRoute(origin),
               snapped.distanceFromRoute <= liveTrackingToleranceMeters {
                progressMeters = snapped.progress
                isOffRoute = false
            } else {
                progressMeters = 0
                isOffRoute = true
                offRouteSeconds = 0
            }
            resetAnnouncements()
            voiceGuide?.announce(RideAnnouncements.rerouted)
        } catch {
            rerouteFailed = true
        }
    }

    // MARK: Progress

    /// One clock tick. Internal (not private) so tests can drive time
    /// deterministically without the wall-clock task.
    func tick(deltaSeconds: Double) {
        guard !isPaused, !isComplete else { return }
        elapsedSeconds += deltaSeconds

        if locationService.isAuthorized, let location = locationService.currentLocation {
            isLocationUnavailable = false
            // A real fix exists. snapToRoute returns nil when no route
            // vertex falls within the grid's walk window — i.e., the
            // rider is too far from the route to be considered on it,
            // not "no GPS." Treat that as off-route, not as the
            // simulation fallback (which only kicks in for genuinely
            // missing fixes).
            if let snapped = snapToRoute(location.coordinate) {
                if snapped.distanceFromRoute <= liveTrackingToleranceMeters {
                    isOffRoute = false
                    rerouteFailed = false
                    offRouteSeconds = 0
                    // Never move backwards on GPS jitter.
                    progressMeters = max(progressMeters, snapped.progress)
                } else {
                    // Real fix, far from the route: the rider left the line.
                    // Freeze progress and re-plan from where they actually are.
                    offRouteSeconds += deltaSeconds
                    if offRouteSeconds >= offRouteRerouteAfterSeconds, !isRerouting {
                        offRouteSeconds = 0
                        if !isOffRoute {
                            isOffRoute = true
                            voiceGuide?.announce(RideAnnouncements.offRoute)
                        }
                        Task { await reroute() }
                    }
                }
            } else {
                // Fix exists but no nearby vertex in the grid — treat as
                // off-route without forcing a long cell walk. The rider
                // is clearly not on the line; reroute logic still kicks
                // in after the sustained-off-route threshold.
                offRouteSeconds += deltaSeconds
                if offRouteSeconds >= offRouteRerouteAfterSeconds, !isRerouting {
                    offRouteSeconds = 0
                    if !isOffRoute {
                        isOffRoute = true
                        voiceGuide?.announce(RideAnnouncements.offRoute)
                    }
                    Task { await reroute() }
                }
            }
        } else if locationService.allowsSimulation {
            // No fix at all in a simulated source (simulator, demo):
            // advance along the geometry at bike-appropriate speeds so
            // the screen is fully exercisable.
            isLocationUnavailable = false
            let speedMs = CyclingSpeedModel.speedKmh(bikeType: bikeType, grade: currentGrade) / 3.6
            progressMeters = min(totalMeters, progressMeters + speedMs * deltaSeconds)
        } else {
            // Real device, no usable position: freeze progress and say
            // so. Never fabricate movement here.
            isLocationUnavailable = true
        }

        refreshOrientation(deltaSeconds: deltaSeconds)
        updateAnnouncements()
        liveActivity.update(activityState())
    }

    // MARK: Voice guidance triggers

    private func resetAnnouncements() {
        announcedApproach = []
        announcedImminent = []
        announcedArrival = false
        announcedDestinationApproach500 = false
        announcedDestinationApproach100 = false
        lastAnnouncedTurnKey = nil
    }

    private func updateAnnouncements() {
        guard let voiceGuide else { return }

        if !announcedStart {
            announcedStart = true
            voiceGuide.announce(RideAnnouncements.rideStart(
                street: currentStreet, totalMeters: totalMeters
            ))
        }

        if isComplete {
            if !announcedArrival {
                announcedArrival = true
                voiceGuide.announce(RideAnnouncements.arrival)
            }
            return
        }

        // Destination-approach phrases fire on the remaining distance
        // regardless of upcoming turns — once the rider is closing in on
        // the endpoint they need a countdown even if the next turn is
        // still hundreds of meters out. Skip if an imminent turn phrase
        // was just announced (within 60 m of a turn), to avoid queueing
        // two phrases back-to-back when the rider is on the literal
        // final turn into the destination. Approach phrases (>60 m to
        // next turn) don't conflict.
        if !announcedDestinationApproach500,
           remainingMeters <= 500, remainingMeters > 100,
           distanceToNextTurnMeters ?? .infinity > 60 {
            announcedDestinationApproach500 = true
            voiceGuide.announce(RideAnnouncements.destinationApproach(inMeters: remainingMeters))
        } else if !announcedDestinationApproach100,
                  remainingMeters <= 100,
                  distanceToNextTurnMeters ?? .infinity > 60 {
            announcedDestinationApproach100 = true
            voiceGuide.announce(RideAnnouncements.destinationApproach(inMeters: remainingMeters))
        }

        guard let next = nextSegment,
              let distance = distanceToNextTurnMeters,
              let index = currentSegmentIndex else { return }
        let turnKey = index + 1

        func announceForThisTurn(_ phrase: String) {
            if let lastAnnouncedTurnKey, lastAnnouncedTurnKey != turnKey {
                voiceGuide.stopSpeaking()
            }
            lastAnnouncedTurnKey = turnKey
            voiceGuide.announce(phrase)
        }

        if distance <= 60 {
            if !announcedImminent.contains(turnKey) {
                announcedImminent.insert(turnKey)
                announcedApproach.insert(turnKey)
                announceForThisTurn(RideAnnouncements.imminent(
                    turn: next.turnType, street: next.streetName
                ))
            }
        } else if distance <= 350, !announcedApproach.contains(turnKey) {
            announcedApproach.insert(turnKey)
            announceForThisTurn(RideAnnouncements.approach(
                turn: next.turnType, street: next.streetName, inMeters: distance
            ))
        }
    }

    private func snapToRoute(
        _ coordinate: CLLocationCoordinate2D
    ) -> (progress: Double, distanceFromRoute: Double)? {
        guard !flattened.isEmpty else { return nil }
        var best: (progress: Double, distance: Double)?
        // Walk the cell containing the fix plus the 8 neighbouring cells,
        // so a fix near a cell boundary still sees every nearby vertex
        // without scanning the full polyline. O(1) per tick instead of
        // O(n) — measurable on city-scale routes with 1k+ vertices.
        let centerLatCell = Int((coordinate.latitude / Self.gridCellDegrees).rounded())
        let centerLonCell = Int((coordinate.longitude / Self.gridCellDegrees).rounded())
        for dLat in -1...1 {
            for dLon in -1...1 {
                let key = ((centerLatCell + dLat) << 16) ^ (centerLonCell + dLon)
                guard let indices = flattenedGrid[key] else { continue }
                for index in indices {
                    let candidatePoint = flattened[index]
                    let distance = GeoMath.distanceMeters(
                        from: candidatePoint.coordinate.clCoordinate, to: coordinate
                    )
                    if distance < (best?.distance ?? .infinity) {
                        best = (candidatePoint.cumulative, distance)
                    }
                }
            }
        }
        guard let best else { return nil }
        return (best.progress, best.distance)
    }
}
