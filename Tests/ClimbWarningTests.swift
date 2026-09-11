import XCTest
import CoreLocation
@testable import LaneLine

/// The upcoming-climb warning contract: find the first qualifying steep run
/// within the lookahead window, show it on the chip from detection, and
/// chime + speak exactly once per climb once it's close enough. Terrain
/// shorter or gentler than the thresholds is noise, not a climb.
@MainActor
final class ClimbWarningTests: XCTestCase {
    // MARK: Pure detector

    private let vertices: [(cumulative: Double, elevation: Double?)] = [
        (0, 10), (60, 10), (150, 17.2), (240, 17.2),
    ]   // 60 m flat, then 90 m at 8%, then flat

    private func detect(
        _ vertices: [(cumulative: Double, elevation: Double?)],
        progress: Double,
        lookahead: Double = 300
    ) -> ActiveRideModel.UpcomingClimb? {
        ActiveRideModel.detectClimbAhead(
            vertices: vertices,
            progress: progress,
            lookaheadMeters: lookahead,
            gradeThreshold: 0.06,
            minRunMeters: 30
        )
    }

    func testDetectsQualifyingRunAhead() {
        let climb = detect(vertices, progress: 0)
        XCTAssertEqual(climb?.startMeters ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(climb?.distanceMeters ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(climb?.lengthMeters ?? 0, 90, accuracy: 0.01)
        XCTAssertEqual(climb?.maxGradeDecimal ?? 0, 0.08, accuracy: 0.001)
    }

    func testIgnoresSubThresholdSlope() {
        let gentle: [(cumulative: Double, elevation: Double?)] = [
            (0, 10), (60, 10), (150, 14.5), (240, 14.5),
        ]   // 5% — rideable, not worth a warning
        XCTAssertNil(detect(gentle, progress: 0))
    }

    func testIgnoresShortRamps() {
        let ramp: [(cumulative: Double, elevation: Double?)] = [
            (0, 10), (60, 10), (80, 11.6), (240, 11.6),
        ]   // 20 m at 8% — intersection crown, not a climb
        XCTAssertNil(detect(ramp, progress: 0))
    }

    func testIgnoresClimbsBeyondLookahead() {
        let far: [(cumulative: Double, elevation: Double?)] = [
            (0, 10), (400, 10), (490, 17.2), (580, 17.2),
        ]
        XCTAssertNil(detect(far, progress: 0, lookahead: 300))
        XCTAssertNotNil(detect(far, progress: 150, lookahead: 300), "Appears once inside the window")
    }

    func testReportsFirstQualifyingRun() {
        let two: [(cumulative: Double, elevation: Double?)] = [
            (0, 10), (60, 10), (150, 17.2), (240, 17.2), (330, 26.2),
        ]   // 8% run then a steeper 10% run
        let climb = detect(two, progress: 0)
        XCTAssertEqual(climb?.startMeters ?? 0, 60, accuracy: 0.01, "The first climb wins, not the steepest")
    }

    func testNilVerticesAndElevationGaps() {
        XCTAssertNil(detect([], progress: 0))
        XCTAssertNil(detect([(0, 10)], progress: 0))
        let gappy: [(cumulative: Double, elevation: Double?)] = [
            (0, 10), (60, nil), (150, 17.2), (240, 17.2),
        ]   // Missing elevation at the run base — no invented grades
        XCTAssertNil(detect(gappy, progress: 0))
    }

    // MARK: On-ride integration

    private final class RecordingVoiceGuide: RideVoiceGuiding {
        var isMuted = false
        private(set) var phrases: [String] = []
        private(set) var alertCount = 0

        func announce(_ phrase: String) { phrases.append(phrase) }
        func stopSpeaking() {}
        func playAlertSound() { alertCount += 1 }
    }

    /// Flat 60 m → 8% for 90 m → flat, along one line, built through the
    /// real graph → routing pipeline so the route's segment geometry and
    /// elevations match production shape.
    private func makeClimbRouteModel() async throws -> (ActiveRideModel, RecordingVoiceGuide) {
        func point(_ meters: Double, _ elevation: Double) -> RouteCoordinate {
            TestGraphs.coordinate(37.7500 + meters / 111_320, -122.4200, elevation)
        }
        let graph = try await TestGraphs.build([
            TestGraphs.rawEdge(from: point(0, 10), to: point(60, 10), street: "Flat St"),
            TestGraphs.rawEdge(
                from: point(60, 10), to: point(150, 17.2), street: "Steep St",
                roadClass: .residential
            ),
            TestGraphs.rawEdge(from: point(150, 17.2), to: point(240, 17.2), street: "Top St"),
        ])
        let routing = RoutingService(geospatialService: StubGeospatialService(graph: graph))
        let routes = try await routing.generateRoutes(
            from: point(0, 10).clCoordinate,
            to: point(240, 17.2).clCoordinate,
            profile: .testProfile(bikeType: .roadBike),
            strategies: [.balanced]
        )
        let candidate = try XCTUnwrap(routes.first, "Route over the climb profile should plan")
        let voice = RecordingVoiceGuide()
        let model = ActiveRideModel(
            route: candidate,
            profile: .testProfile(bikeType: .roadBike),
            locationService: MockLocationService(coordinate: nil),
            routingService: routing,
            voiceGuide: voice
        )
        return (model, voice)
    }

    @MainActor
    func testRideAnnouncesClimbOnceAndClearsChipAfterwards() async throws {
        let (model, voice) = try await makeClimbRouteModel()
        var sawClimbChip = false

        // Fix-less mock → the simulation advances the ride; drive until the
        // route completes (240 m at simulation speed).
        var ticks = 0
        while !model.isComplete, ticks < 120 {
            model.tick(deltaSeconds: 1)
            if model.upcomingClimb != nil { sawClimbChip = true }
            ticks += 1
        }
        XCTAssertTrue(sawClimbChip, "Climb chip should show while the climb is ahead")
        XCTAssertFalse(model.isComplete == false && model.upcomingClimb == nil && ticks < 5,
                       "Sanity: detection should fire early, not after the ride")

        let climbPhrases = voice.phrases.filter { $0.contains("climb") }
        XCTAssertEqual(climbPhrases.count, 1, "Chime phrase fires exactly once per climb: \(voice.phrases)")
        XCTAssertEqual(voice.alertCount, 1, "Alert chime fires exactly once per climb")
        XCTAssertEqual(model.upcomingClimb, nil, "Chip clears once the climb is behind")
    }
}
