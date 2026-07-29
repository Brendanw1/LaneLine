import XCTest
@testable import LaneLine

/// Unit tests for the edge cost function — the routing engine's core
/// behavioral contract.
final class RoutingCostModelTests: XCTestCase {
    private func edge(
        length: Double = 1000,
        grade: Double = 0,
        facility: BikeFacilityType = .mixedTraffic,
        protection: ProtectionLevel = .none,
        roadClass: RoadClass = .residential,
        surface: SurfaceType = .asphalt,
        stress: Double = 0.15,
        confidence: Double = 0.9,
        isWiggleCorridor: Bool = false
    ) -> RouteGraph.Edge {
        RouteGraph.Edge(
            id: 0, from: 0, to: 1,
            lengthMeters: length,
            grade: grade,
            estimatedSeconds: CyclingSpeedModel.neutralTraversalSeconds(
                lengthMeters: length, grade: grade
            ),
            facilityType: facility,
            protectionLevel: protection,
            roadClass: roadClass,
            surfaceType: surface,
            stressScore: stress,
            confidenceScore: confidence,
            streetName: nil,
            geometry: [],
            isWiggleCorridor: isWiggleCorridor
        )
    }

    private func model(
        _ bikeType: BikeType,
        strategy: RouteStrategyType = .balanced
    ) -> RoutingCostModel {
        RoutingCostModel(profile: .testProfile(bikeType: bikeType), strategy: strategy)
    }

    // MARK: Surface behavior

    func testRoadBikePenalizesGravelHarderThanGravelBike() {
        let gravelEdge = edge(surface: .gravel)
        let asphaltEdge = edge(surface: .asphalt)

        let roadBike = model(.roadBike)
        let gravelBike = model(.gravel)

        let roadPenaltyRatio = roadBike.cost(of: gravelEdge) / roadBike.cost(of: asphaltEdge)
        let gravelPenaltyRatio = gravelBike.cost(of: gravelEdge) / gravelBike.cost(of: asphaltEdge)

        XCTAssertGreaterThan(roadPenaltyRatio, 2.0, "Road bikes should heavily avoid gravel")
        XCTAssertLessThan(gravelPenaltyRatio, 1.1, "Gravel bikes should barely notice gravel")
    }

    func testUnknownSurfaceCostsMoreThanKnownAsphaltForRoadBike() {
        let roadBike = model(.roadBike)
        XCTAssertGreaterThan(
            roadBike.cost(of: edge(surface: .unknown)),
            roadBike.cost(of: edge(surface: .asphalt))
        )
    }

    // MARK: Grade behavior

    func testEBikeClimbPenaltyIsMuchLowerThanRoadBike() {
        let climb = edge(length: 500, grade: 0.07)
        let flat = edge(length: 500, grade: 0)

        let roadExtra = model(.roadBike).cost(of: climb) - model(.roadBike).cost(of: flat)
        let eBikeExtra = model(.eBike).cost(of: climb) - model(.eBike).cost(of: flat)

        XCTAssertGreaterThan(roadExtra, eBikeExtra * 2)
    }

    func testSteepSpikePenalizedBeyondThreshold() {
        let roadBike = model(.roadBike)
        // 9% exceeds the road-bike threshold (8%); 7% does not. The spike
        // penalty should make the cost jump disproportionately to the grade
        // increase alone.
        let below = roadBike.cost(of: edge(length: 300, grade: 0.07))
        let above = roadBike.cost(of: edge(length: 300, grade: 0.09))
        let flatStep = roadBike.cost(of: edge(length: 300, grade: 0.07))
            - roadBike.cost(of: edge(length: 300, grade: 0.05))

        XCTAssertGreaterThan(above - below, flatStep)
    }

    func testSteepDescentCostsMoreThanGentleDescent() {
        let roadBike = model(.roadBike)
        let gentle = roadBike.cost(of: edge(length: 500, grade: -0.04))
        let steep = roadBike.cost(of: edge(length: 500, grade: -0.12))
        // Steep descents should not be rewarded with proportionally lower
        // cost — caution braking eats the speed advantage.
        XCTAssertGreaterThan(steep, gentle * 0.8)
    }

    // MARK: Infrastructure behavior

    func testProtectedLaneBeatsIdenticalUnprotectedStreet() {
        let roadBike = model(.roadBike)
        let protected = edge(facility: .protectedBikeLane, protection: .fullyProtected, stress: 0.2)
        let bare = edge(facility: .mixedTraffic, protection: .none, stress: 0.2)
        XCTAssertLessThan(roadBike.cost(of: protected), roadBike.cost(of: bare))
    }

    func testHighStressEdgeCostsMore() {
        let cityBike = model(.cityBike)
        XCTAssertGreaterThan(
            cityBike.cost(of: edge(stress: 0.8)),
            cityBike.cost(of: edge(stress: 0.15))
        )
    }

    // MARK: Strategy behavior

    func testSaferStrategyWeighsStressHarderThanFaster() {
        let stressful = edge(stress: 0.8)
        let calm = edge(stress: 0.1)

        let safer = model(.roadBike, strategy: .safer)
        let faster = model(.roadBike, strategy: .faster)

        let saferRatio = safer.cost(of: stressful) / safer.cost(of: calm)
        let fasterRatio = faster.cost(of: stressful) / faster.cost(of: calm)

        XCTAssertGreaterThan(saferRatio, fasterRatio)
    }

    func testEasierClimbingStrategyRaisesClimbCost() {
        let climb = edge(length: 500, grade: 0.06)
        let balanced = model(.roadBike, strategy: .balanced)
        let easier = model(.roadBike, strategy: .easierClimbing)
        XCTAssertGreaterThan(easier.cost(of: climb), balanced.cost(of: climb))
    }

    // MARK: Confidence

    func testLowConfidenceEdgeLosesTies() {
        let roadBike = model(.roadBike)
        XCTAssertGreaterThan(
            roadBike.cost(of: edge(confidence: 0.3)),
            roadBike.cost(of: edge(confidence: 1.0))
        )
    }

    // MARK: Heuristic admissibility

    func testHeuristicNeverExceedsRealCost() {
        // The A* heuristic must underestimate: check against the cheapest
        // realistic edge (downhill, protected, calm).
        for bikeType in BikeType.allCases {
            let model = model(bikeType)
            let cheapEdge = edge(
                length: 1000, grade: -0.05,
                facility: .offStreetPath, protection: .fullyProtected,
                stress: 0.05, confidence: 1.0
            )
            XCTAssertLessThanOrEqual(
                model.heuristicCost(distanceMeters: 1000),
                model.cost(of: cheapEdge),
                "Heuristic overestimates for \(bikeType)"
            )
        }
    }
}
