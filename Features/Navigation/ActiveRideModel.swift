import Foundation
import CoreLocation
import Observation

/// Live state for an active ride. Progress comes from CoreLocation when the
/// rider has a fix near the route; otherwise a simulation engine advances
/// along the geometry at bike-appropriate speeds so the ride screen is fully
/// exercisable in the simulator. Voice guidance is scaffolded (mute toggle,
/// maneuver stream) but not synthesized in v1.
@MainActor
@Observable
final class ActiveRideModel {
    // MARK: State

    private(set) var route: RouteCandidate
    private(set) var progressMeters: Double = 0
    private(set) var elapsedSeconds: Double = 0
    private(set) var isPaused = false
    private(set) var isRerouting = false
    var guidanceMuted = false

    // MARK: Derived metrics

    var totalMeters: Double { flattened.last?.cumulative ?? 0 }
    var remainingMeters: Double { max(0, totalMeters - progressMeters) }
    var fractionComplete: Double { totalMeters > 0 ? progressMeters / totalMeters : 0 }
    var isComplete: Bool { remainingMeters < 10 }

    var currentCoordinate: CLLocationCoordinate2D {
        point(at: progressMeters)?.coordinate.clCoordinate
            ?? route.allCoordinates.first
            ?? CLLocationCoordinate2D(latitude: 37.7702, longitude: -122.4270)
    }

    var currentHeading: Double {
        guard let current = point(at: progressMeters),
              let ahead = point(at: progressMeters + 25),
              current.cumulative < ahead.cumulative else { return 0 }
        return GeoMath.bearingDegrees(
            from: current.coordinate.clCoordinate,
            to: ahead.coordinate.clCoordinate
        )
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
    var currentStreet: String? { currentSegment?.streetName }

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

    /// Location fixes farther than this from the route fall back to
    /// simulation (GPS drift, indoor testing, simulator).
    private let liveTrackingToleranceMeters: Double = 150

    init(
        route: RouteCandidate,
        profile: RiderProfile,
        locationService: any LocationServicing,
        routingService: any RoutingServiceProtocol
    ) {
        self.route = route
        self.profile = profile
        self.bikeType = profile.bikeType
        self.locationService = locationService
        self.routingService = routingService
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

    // MARK: Lifecycle

    func start() {
        guard tickTask == nil else { return }
        locationService.startUpdating()
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
        locationService.stopUpdating()
    }

    /// Re-plan from the current position to the route's destination using the
    /// same strategy, and continue on the fresh route.
    func reroute() async {
        guard let destination = route.allCoordinates.last, !isRerouting else { return }
        isRerouting = true
        defer { isRerouting = false }

        if let fresh = try? await routingService.generateRoutes(
            from: currentCoordinate,
            to: destination,
            profile: profile,
            strategies: [route.strategyType]
        ).first {
            route = fresh
            progressMeters = 0
            rebuildGeometry()
        }
    }

    // MARK: Progress

    private func tick(deltaSeconds: Double) {
        guard !isPaused, !isComplete else { return }
        elapsedSeconds += deltaSeconds

        // Prefer real position when it's plausibly on this route.
        if let location = locationService.currentLocation,
           let snapped = snapToRoute(location.coordinate),
           snapped.distanceFromRoute <= liveTrackingToleranceMeters {
            // Never move backwards on GPS jitter.
            progressMeters = max(progressMeters, snapped.progress)
        } else {
            let speedMs = CyclingSpeedModel.speedKmh(bikeType: bikeType, grade: currentGrade) / 3.6
            progressMeters = min(totalMeters, progressMeters + speedMs * deltaSeconds)
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
