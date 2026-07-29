import XCTest
import CoreLocation
@testable import LaneLine

/// End-to-end check that ActiveRideModel's tick loop actually wires the new
/// course-first fusion through to `displayHeading` — the unit-level engine
/// tests (NavigationOrientationEngineTests) cover the state machine in
/// isolation; this proves the real LocationServicing -> ActiveRideModel
/// plumbing matches it.
@MainActor
final class ActiveRideModelOrientationTests: XCTestCase {
    private func northRoute() async throws -> (candidate: RouteCandidate, routing: RoutingService) {
        let o = TestGraphs.coordinate(37.7600, -122.4200, 10)
        let n = TestGraphs.coordinate(37.7700, -122.4200, 10)
        let graph = try await TestGraphs.build([
            TestGraphs.rawEdge(from: o, to: n, street: "North St"),
        ])
        let routing = RoutingService(geospatialService: StubGeospatialService(graph: graph))
        let routes = try await routing.generateRoutes(
            from: o.clCoordinate, to: n.clCoordinate,
            profile: .testProfile(bikeType: .hybridFitness), strategies: [.balanced]
        )
        let candidate = try XCTUnwrap(routes.first)
        return (candidate, routing)
    }

    func testDisplayHeadingPrefersCourseThenFreezesThenFallsBackToHeadingThenResumesCourse() async throws {
        let (candidate, routing) = try await northRoute()
        let origin = try XCTUnwrap(candidate.allCoordinates.first)
        let location = MockLocationService(coordinate: origin)

        let model = ActiveRideModel(
            route: candidate,
            profile: .testProfile(bikeType: .hybridFitness),
            locationService: location,
            routingService: routing
        )

        XCTAssertEqual(model.orientationSource, .routeBearing)

        // Moving east at a real bike speed with a good course: converges on
        // the course, not the route's own (north) bearing.
        for _ in 0..<15 {
            location.setLocation(origin, course: 90, speed: 5)
            model.tick(deltaSeconds: 1)
        }
        XCTAssertEqual(model.orientationSource, .course)
        XCTAssertLessThan(
            abs(GeoMath.turnAngleDegrees(fromBearing: model.displayHeading, toBearing: 90)), 2,
            "Should have converged on the moving course, not stayed near the route's own bearing"
        )

        // Slow down (below the trust threshold) but stay within the
        // freeze-grace window: still course, not yet drifting to heading.
        let headingAtSlowdown = model.displayHeading
        for _ in 0..<3 {
            location.setLocation(origin, heading: 45, headingAccuracy: 10, course: 90, speed: 0.2)
            model.tick(deltaSeconds: 1)
        }
        XCTAssertEqual(model.orientationSource, .course, "Should still be frozen on the last good course")
        XCTAssertLessThan(
            abs(GeoMath.turnAngleDegrees(fromBearing: headingAtSlowdown, toBearing: model.displayHeading)), 1,
            "Frozen course should not drift toward heading during the grace window"
        )

        // Past the grace window: falls back to the (different) compass
        // heading.
        for _ in 0..<10 {
            location.setLocation(origin, heading: 45, headingAccuracy: 10, course: 90, speed: 0.2)
            model.tick(deltaSeconds: 1)
        }
        XCTAssertEqual(model.orientationSource, .heading)
        XCTAssertLessThan(
            abs(GeoMath.turnAngleDegrees(fromBearing: model.displayHeading, toBearing: 45)), 2,
            "Should have converged on the compass heading once course went stale"
        )

        // Resuming real movement snaps straight back to course, with no
        // extra grace period on the way up.
        location.setLocation(origin, heading: 45, headingAccuracy: 10, course: 90, speed: 5)
        model.tick(deltaSeconds: 1)
        XCTAssertEqual(model.orientationSource, .course, "Resuming speed should switch back to course immediately")
    }
}
