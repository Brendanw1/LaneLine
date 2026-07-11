import XCTest
import CoreLocation
@testable import LaneLine

/// End-to-end routing over the bundled SF sample network — the same data the
/// app ships for demo mode, loaded through the production builder pipeline.
final class SampleNetworkRoutingTests: XCTestCase {
    private static let mission24th = CLLocationCoordinate2D(latitude: 37.75215, longitude: -122.42060)
    private static let ferryBuilding = CLLocationCoordinate2D(latitude: 37.79550, longitude: -122.39370)
    private static let goldenGatePark = CLLocationCoordinate2D(latitude: 37.77250, longitude: -122.46030)

    private func loadPlanner() async throws -> RoutingService {
        // Resolve the resource from the repo checkout so this works whether
        // or not the test bundle embeds app resources.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appending(path: "Resources/SFSampleNetwork.json")
        let graph = try await SampleNetworkLoader().loadGraph(from: url)
        XCTAssertFalse(graph.isEmpty)
        return RoutingService(geospatialService: StubGeospatialService(graph: graph))
    }

    func testMissionToFerryProducesDistinctCandidates() async throws {
        let planner = try await loadPlanner()
        let routes = try await planner.generateRoutes(
            from: Self.mission24th,
            to: Self.ferryBuilding,
            profile: .testProfile(bikeType: .roadBike)
        )

        XCTAssertGreaterThanOrEqual(routes.count, 2)
        for route in routes {
            // Mission → Ferry Building is ~5.5 km by street; sanity-band it.
            XCTAssertGreaterThan(route.totalDistanceMeters, 4000)
            XCTAssertLessThan(route.totalDistanceMeters, 10000)
            XCTAssertGreaterThan(route.bikeFacilityPercent, 0.3)
            XCTAssertFalse(route.segments.isEmpty)
            XCTAssertFalse(route.recommendationReason.isEmpty)
        }
    }

    func testRoadBikeAvoidsCastroDuboceHillToThePark() async throws {
        let planner = try await loadPlanner()
        let routes = try await planner.generateRoutes(
            from: Self.mission24th,
            to: Self.goldenGatePark,
            profile: .testProfile(bikeType: .roadBike),
            strategies: [.balanced]
        )
        let route = try XCTUnwrap(routes.first)
        // The Castro St hill peaks around 10%; a road-bike balanced route
        // should stay under punchy-spike territory via the Wiggle.
        XCTAssertLessThan(route.maxGrade, 0.09, "Road bike route should avoid the steep Castro/Duboce climb")
    }

    func testSaferRouteHasMoreProtectionThanFaster() async throws {
        let planner = try await loadPlanner()
        let routes = try await planner.generateRoutes(
            from: Self.mission24th,
            to: Self.ferryBuilding,
            profile: .testProfile(bikeType: .cityBike),
            strategies: [.safer, .faster]
        )
        guard routes.count == 2 else {
            // Safer and faster may legitimately converge on one path when it
            // dominates on both axes; nothing to compare then.
            return
        }
        let safer = try XCTUnwrap(routes.first { $0.strategyType == .safer })
        let faster = try XCTUnwrap(routes.first { $0.strategyType == .faster })
        XCTAssertGreaterThanOrEqual(
            safer.protectedLanePercent + 0.001,
            faster.protectedLanePercent
        )
    }

    func testGraphSurvivesCodableRoundTrip() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/SFSampleNetwork.json")
        let graph = try await SampleNetworkLoader().loadGraph(from: url)

        let data = try JSONEncoder().encode(graph)
        let decoded = try JSONDecoder().decode(RouteGraph.self, from: data)

        XCTAssertEqual(decoded.nodes.count, graph.nodes.count)
        XCTAssertEqual(decoded.edges.count, graph.edges.count)
        // Adjacency must be rebuilt on decode.
        let node = try XCTUnwrap(graph.nodes.first)
        XCTAssertEqual(
            decoded.outgoingEdges(from: node.id).count,
            graph.outgoingEdges(from: node.id).count
        )
    }
}
