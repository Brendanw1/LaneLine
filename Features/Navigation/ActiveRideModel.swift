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
    var guidanceMuted = false {
        didSet {
            voiceGuide?.isMuted = guidanceMuted
        }
    }

    // MARK: Derived metrics

    var totalMeters: Double { flattened.last?.cumulative ?? 0 }
    var remainingMeters: Double { max(0, totalMeters - progressMeters) }
    var fractionComplete: Double { totalMeters > 0 ? progressMeters / totalMeters : 0 }
    var isComplete: Bool { remainingMeters < 10 }

    var currentCoordinate: CLLocationCoordinate2D {
        interpolatedPosition(at: progressMeters)?.coordinate
            ?? route.allCoordinates.first
            ?? CLLocationCoordinate2D(latitude: 37.7702, longitude: -122.4270)
    }

    /// Camera/marker heading, preferring the phone's real compass so the
    /// map turns with however the rider is actually holding/facing it —
    /// route-bearing alone assumes you're pointed exactly along the road,
    /// which isn't true the moment you glance sideways, walk the bike, or
    /// drift off-line. Falls back to route bearing when there's no real
    /// heading (simulator/demo mode, or momentarily poor compass accuracy).
    ///
    /// This is the *smoothed* value — raw magnetometer readings genuinely
    /// jitter several degrees moment to moment, especially bike-mounted
    /// (vibration, nearby metal), and feeding that straight into the camera
    /// every tick reads as a constant small wobble rather than a settled
    /// direction. `refreshHeading()` (called once per tick) low-pass
    /// filters it; this just returns the filtered result.
    private(set) var displayHeading: Double = 0

    /// Exponential blend factor toward the latest raw reading — low enough
    /// to damp jitter, high enough to still catch up to a real turn within
    /// a couple of ticks rather than lagging behind it.
    private let headingSmoothingFactor: Double = 0.35

    private func refreshHeading() {
        let raw = locationService.currentHeading ?? routeBearingHeading
        let delta = Self.shortestAngleDelta(from: displayHeading, to: raw)
        displayHeading = Self.normalizedDegrees(displayHeading + delta * headingSmoothingFactor)
    }

    private static func shortestAngleDelta(from: Double, to: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        return delta
    }

    private static func normalizedDegrees(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
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
            let fractionLeft = segment.lengthMeters > 0
                ? max(0, 1 - intoSegment / segment.lengthMeters) : 0
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
        // Seed at the real starting direction rather than 0, so the first
        // camera frame doesn't spin in from due north.
        displayHeading = locationService.currentHeading ?? routeBearingHeading
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
    /// line), otherwise from the route position.
    func reroute() async {
        guard let destination = route.allCoordinates.last, !isRerouting else { return }
        isRerouting = true
        defer { isRerouting = false }

        let origin = locationService.currentLocation?.coordinate ?? currentCoordinate
        if let fresh = try? await routingService.generateRoutes(
            from: origin,
            to: destination,
            profile: profile,
            strategies: [route.strategyType]
        ).first {
            // `AVSpeechSynthesizer.speak()` queues rather than interrupts, so
            // an "approach"/"imminent" announcement generated from the *old*
            // route can still be sitting queued here — if left alone, it
            // plays out loud after this reroute completes, describing a turn
            // that no longer exists while the screen already shows the new
            // route. Flushing it is the fix for "voice said a different turn
            // than the screen."
            voiceGuide?.stopSpeaking()
            route = fresh
            progressMeters = 0
            isOffRoute = false
            offRouteSeconds = 0
            resetAnnouncements()
            rebuildGeometry()
            voiceGuide?.announce(RideAnnouncements.rerouted)
        }
    }

    // MARK: Progress

    /// One clock tick. Internal (not private) so tests can drive time
    /// deterministically without the wall-clock task.
    func tick(deltaSeconds: Double) {
        guard !isPaused, !isComplete else { return }
        elapsedSeconds += deltaSeconds

        if let location = locationService.currentLocation,
           let snapped = snapToRoute(location.coordinate) {
            if snapped.distanceFromRoute <= liveTrackingToleranceMeters {
                isOffRoute = false
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
            // No fix at all (simulator, demo): advance along the geometry at
            // bike-appropriate speeds so the screen is fully exercisable.
            let speedMs = CyclingSpeedModel.speedKmh(bikeType: bikeType, grade: currentGrade) / 3.6
            progressMeters = min(totalMeters, progressMeters + speedMs * deltaSeconds)
        }

        refreshHeading()
        updateAnnouncements()
        liveActivity.update(activityState())
    }

    // MARK: Voice guidance triggers

    private func resetAnnouncements() {
        announcedApproach = []
        announcedImminent = []
        announcedArrival = false
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
        for candidatePoint in flattened {
            let distance = GeoMath.distanceMeters(
                from: candidatePoint.coordinate.clCoordinate, to: coordinate
            )
            if distance < (best?.distance ?? .infinity) {
                best = (candidatePoint.cumulative, distance)
            }
        }
        guard let best else { return nil }
        return (best.progress, best.distance)
    }
}
