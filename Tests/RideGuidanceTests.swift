import XCTest
import CoreLocation
@testable import LaneLine

// MARK: - Test doubles

@MainActor
private final class VoiceRecorder: RideVoiceGuiding {
    var isMuted = false
    var phrases: [String] = []
    var stopped = false

    func announce(_ phrase: String) {
        guard !isMuted else { return }
        phrases.append(phrase)
    }

    func stopSpeaking() { stopped = true }
}

private actor StubRoutingService: RoutingServiceProtocol {
    let canned: RouteCandidate
    private(set) var requestedOrigins: [CLLocationCoordinate2D] = []

    init(canned: RouteCandidate) { self.canned = canned }

    func generateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: RiderProfile
    ) async throws -> [RouteCandidate] {
        try await generateRoutes(
            from: origin, to: destination, profile: profile, strategies: [.balanced]
        )
    }

    func generateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: RiderProfile,
        strategies: [RouteStrategyType]
    ) async throws -> [RouteCandidate] {
        requestedOrigins.append(origin)
        return [canned]
    }

    func scoreRoute(
        _ route: RouteCandidate, profile: RiderProfile
    ) async throws -> RouteScoreBreakdown {
        route.scoreBreakdown ?? RouteScoreBreakdown(
            travelTimeScore: 0, climbPenalty: 0, maxGradePenalty: 0,
            protectedLaneBonus: 0, bikeLaneBonus: 0, offStreetBonus: 0,
            arterialPenalty: 0, roughSurfacePenalty: 0, crossingPenalty: 0,
            detourPenalty: 0, descentPenalty: 0
        )
    }
}

// MARK: - Tests

/// Voice phrase construction plus the ride model's guidance and off-route
/// behavior, driven by deterministic ticks instead of the wall clock.
@MainActor
final class RideGuidanceTests: XCTestCase {

    private func plannedCandidate() async throws -> RouteCandidate {
        let planner = RoutingService(
            geospatialService: StubGeospatialService(graph: try await TestGraphs.stressTradeoffGraph())
        )
        let routes = try await planner.generateRoutes(
            from: TestGraphs.stressOrigin,
            to: TestGraphs.stressDestination,
            profile: .testProfile(bikeType: .hybridFitness),
            strategies: [.balanced]
        )
        return try XCTUnwrap(routes.first)
    }

    /// Two-street L: ~440 m east on Bay St, left turn, ~556 m north on
    /// Cross Ave — the smallest route with a real maneuver to announce.
    private func twoStreetCandidate() async throws -> RouteCandidate {
        let o = TestGraphs.coordinate(37.7600, -122.4200, 10)
        let n = TestGraphs.coordinate(37.7600, -122.4150, 10)
        let d = TestGraphs.coordinate(37.7650, -122.4150, 10)
        let graph = try await TestGraphs.build([
            TestGraphs.rawEdge(from: o, to: n, street: "Bay St"),
            TestGraphs.rawEdge(from: n, to: d, street: "Cross Ave"),
        ])
        let planner = RoutingService(geospatialService: StubGeospatialService(graph: graph))
        let routes = try await planner.generateRoutes(
            from: o.clCoordinate,
            to: d.clCoordinate,
            profile: .testProfile(bikeType: .hybridFitness),
            strategies: [.balanced]
        )
        return try XCTUnwrap(routes.first)
    }

    // MARK: Phrases

    func testSpokenDistancePhrasing() {
        XCTAssertEqual(RideAnnouncements.spokenDistance(310), "300 meters")
        XCTAssertEqual(RideAnnouncements.spokenDistance(20), "50 meters")
        XCTAssertEqual(RideAnnouncements.spokenDistance(1000), "1 kilometer")
        XCTAssertEqual(RideAnnouncements.spokenDistance(2260), "2.3 kilometers")
    }

    func testTurnPhrases() {
        XCTAssertEqual(
            RideAnnouncements.imminent(turn: .left, street: "Market St"),
            "Turn left onto Market St."
        )
        XCTAssertEqual(
            RideAnnouncements.approach(turn: .slightRight, street: "The Wiggle", inMeters: 240),
            "In 250 meters, bear right onto The Wiggle."
        )
    }

    // MARK: Off-route

    func testSustainedOffRouteFreezesProgressAndAnnounces() async throws {
        let candidate = try await plannedCandidate()
        let recorder = VoiceRecorder()
        // ~1.1 km south of every point on the synthetic route.
        let farAway = CLLocationCoordinate2D(latitude: 37.7500, longitude: -122.4100)

        let model = ActiveRideModel(
            route: candidate,
            profile: .testProfile(bikeType: .hybridFitness),
            locationService: MockLocationService(coordinate: farAway),
            routingService: StubRoutingService(canned: candidate),
            voiceGuide: recorder
        )

        for _ in 0..<10 { model.tick(deltaSeconds: 1) }

        XCTAssertTrue(model.isOffRoute)
        XCTAssertEqual(model.progressMeters, 0, "Progress must freeze while off route")
        XCTAssertTrue(recorder.phrases.contains(RideAnnouncements.offRoute))
    }

    func testRerouteReplansFromRiderLocationAndAnnounces() async throws {
        let candidate = try await plannedCandidate()
        let recorder = VoiceRecorder()
        let riderPosition = CLLocationCoordinate2D(latitude: 37.7500, longitude: -122.4100)
        let stub = StubRoutingService(canned: candidate)

        let model = ActiveRideModel(
            route: candidate,
            profile: .testProfile(bikeType: .hybridFitness),
            locationService: MockLocationService(coordinate: riderPosition),
            routingService: stub,
            voiceGuide: recorder
        )

        await model.reroute()

        let origins = await stub.requestedOrigins
        let origin = try XCTUnwrap(origins.first)
        XCTAssertEqual(origin.latitude, riderPosition.latitude, accuracy: 1e-9,
                       "Reroute must start from the rider's real position")
        XCTAssertFalse(model.isOffRoute)
        XCTAssertTrue(recorder.phrases.contains(RideAnnouncements.rerouted))
    }

    // MARK: Simulated ride guidance

    func testSimulatedRideAnnouncesStartTurnAndArrival() async throws {
        let candidate = try await twoStreetCandidate()
        let recorder = VoiceRecorder()

        let model = ActiveRideModel(
            route: candidate,
            profile: .testProfile(bikeType: .hybridFitness),
            locationService: MockLocationService(coordinate: nil),
            routingService: StubRoutingService(canned: candidate),
            voiceGuide: recorder
        )

        var ticks = 0
        while !model.isComplete && ticks < 2000 {
            model.tick(deltaSeconds: 1)
            ticks += 1
        }

        XCTAssertTrue(model.isComplete, "Simulation should reach the destination")
        let first = try XCTUnwrap(recorder.phrases.first)
        XCTAssertTrue(first.hasPrefix("Starting ride"), "First phrase was: \(first)")
        XCTAssertTrue(
            recorder.phrases.contains { $0.hasPrefix("In ") },
            "Should announce an upcoming turn; got: \(recorder.phrases)"
        )
        XCTAssertEqual(recorder.phrases.last, RideAnnouncements.arrival)
    }

    func testMuteSuppressesAnnouncements() async throws {
        let candidate = try await plannedCandidate()
        let recorder = VoiceRecorder()

        let model = ActiveRideModel(
            route: candidate,
            profile: .testProfile(bikeType: .hybridFitness),
            locationService: MockLocationService(coordinate: nil),
            routingService: StubRoutingService(canned: candidate),
            voiceGuide: recorder
        )

        model.guidanceMuted = true
        XCTAssertTrue(recorder.isMuted, "Mute toggle must reach the voice guide")
        model.tick(deltaSeconds: 1)
        XCTAssertTrue(recorder.phrases.isEmpty)
    }
}
