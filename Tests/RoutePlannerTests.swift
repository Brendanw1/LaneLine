import XCTest
import CoreLocation
@testable import LaneLine

/// Behavioral tests for the A* planner over synthetic graphs built through
/// the production pipeline.
final class RoutePlannerTests: XCTestCase {
    private func service(_ graph: RouteGraph) -> RoutingService {
        RoutingService(geospatialService: StubGeospatialService(graph: graph))
    }

    // MARK: Stress tradeoff

    func testSaferStrategyTakesProtectedDetour() async throws {
        let planner = service(try await TestGraphs.stressTradeoffGraph())
        let routes = try await planner.generateRoutes(
            from: TestGraphs.stressOrigin,
            to: TestGraphs.stressDestination,
            profile: .testProfile(bikeType: .roadBike),
            strategies: [.safer]
        )
        let safer = try XCTUnwrap(routes.first)
        XCTAssertTrue(safer.streetNames.contains("Calm Way"), "Safer route should detour via the protected lane")
        XCTAssertFalse(safer.streetNames.contains("Direct St"))
    }

    func testFasterStrategyTakesDirectArterial() async throws {
        let planner = service(try await TestGraphs.stressTradeoffGraph())
        let routes = try await planner.generateRoutes(
            from: TestGraphs.stressOrigin,
            to: TestGraphs.stressDestination,
            profile: .testProfile(bikeType: .roadBike),
            strategies: [.faster]
        )
        let faster = try XCTUnwrap(routes.first)
        XCTAssertTrue(faster.streetNames.contains("Direct St"), "Faster route should take the direct arterial")
    }

    func testCandidatesAreDistinctAndAnnotated() async throws {
        let planner = service(try await TestGraphs.stressTradeoffGraph())
        let routes = try await planner.generateRoutes(
            from: TestGraphs.stressOrigin,
            to: TestGraphs.stressDestination,
            profile: .testProfile(bikeType: .roadBike)
        )
        XCTAssertGreaterThanOrEqual(routes.count, 2, "Should surface both tradeoff profiles")
        XCTAssertLessThanOrEqual(routes.count, 3)
        for route in routes {
            XCTAssertFalse(route.recommendationReason.isEmpty)
            XCTAssertNotNil(route.scoreBreakdown)
            XCTAssertGreaterThan(route.totalDistanceMeters, 0)
            XCTAssertGreaterThan(route.etaSeconds, 0)
            XCTAssertTrue((0...1).contains(route.routeStressScore))
            XCTAssertTrue((0...1).contains(route.confidenceScore))
        }

        let saferRoute = routes.first { $0.strategyType == .safer }
        let fasterRoute = routes.first { $0.strategyType == .faster }
        if let saferRoute, let fasterRoute {
            XCTAssertGreaterThan(
                saferRoute.protectedLanePercent,
                fasterRoute.protectedLanePercent
            )
        }
    }

    // MARK: Hill tradeoff by bike type

    func testRoadBikeDetoursAroundSteepHill() async throws {
        let planner = service(try await TestGraphs.hillTradeoffGraph())
        let routes = try await planner.generateRoutes(
            from: TestGraphs.hillOrigin,
            to: TestGraphs.hillDestination,
            profile: .testProfile(bikeType: .roadBike),
            strategies: [.balanced]
        )
        let route = try XCTUnwrap(routes.first)
        XCTAssertTrue(route.streetNames.contains("Flat Ave"), "Road bike should avoid the 10% hill")
        XCTAssertFalse(route.streetNames.contains("Hill St"))
    }

    func testEBikeTakesTheHillShortcut() async throws {
        let planner = service(try await TestGraphs.hillTradeoffGraph())
        let routes = try await planner.generateRoutes(
            from: TestGraphs.hillOrigin,
            to: TestGraphs.hillDestination,
            profile: .testProfile(bikeType: .eBike),
            strategies: [.balanced]
        )
        let route = try XCTUnwrap(routes.first)
        XCTAssertTrue(route.streetNames.contains("Hill St"), "E-bike should take the direct hill")
    }

    // MARK: One-way handling

    func testOneWayStreetIsNotTraversedBackwards() async throws {
        let planner = service(try await TestGraphs.oneWayGraph())
        let routes = try await planner.generateRoutes(
            from: TestGraphs.oneWayB,
            to: TestGraphs.oneWayA,
            profile: .testProfile(bikeType: .hybridFitness),
            strategies: [.faster]
        )
        let route = try XCTUnwrap(routes.first)
        XCTAssertFalse(
            route.streetNames.contains("OneWay St"),
            "Reverse direction must loop around, not ride the one-way backwards"
        )
        XCTAssertTrue(route.streetNames.contains("Loop Rd"))
    }

    // MARK: Failure modes

    func testOffNetworkOriginThrows() async throws {
        let planner = service(try await TestGraphs.stressTradeoffGraph())
        // Lake Merced is ~7 km from the synthetic graph.
        let farAway = CLLocationCoordinate2D(latitude: 37.7080, longitude: -122.4930)
        do {
            _ = try await planner.generateRoutes(
                from: farAway,
                to: TestGraphs.stressDestination,
                profile: .testProfile(bikeType: .roadBike)
            )
            XCTFail("Expected originOffNetwork")
        } catch let error as RoutingError {
            XCTAssertEqual(String(describing: error), String(describing: RoutingError.originOffNetwork))
        }
    }
}
