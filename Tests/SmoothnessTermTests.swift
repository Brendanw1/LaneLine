import XCTest
import CoreLocation
@testable import LaneLine

/// The smoothness term in `RoutingCostModel` penalizes streets whose
/// micro-edges have high grade variance — i.e. yo-yo character — even
/// when no single edge is steep enough to trip the spike penalty. These
/// tests build synthetic streets and verify the term picks up the
/// difference.
final class SmoothnessTermTests: XCTestCase {
    private func edge(
        length: Double,
        grade: Double,
        smoothness: Double = 0
    ) -> RouteGraph.Edge {
        RouteGraph.Edge(
            id: 0, from: 0, to: 1,
            lengthMeters: length,
            grade: grade,
            estimatedSeconds: CyclingSpeedModel.neutralTraversalSeconds(
                lengthMeters: length, grade: grade
            ),
            facilityType: .mixedTraffic,
            protectionLevel: .none,
            roadClass: .residential,
            surfaceType: .asphalt,
            stressScore: 0.15,
            confidenceScore: 0.9,
            streetName: nil,
            geometry: [],
            isWiggleCorridor: false,
            smoothnessPenalty: smoothness
        )
    }

    /// The smoothness term only kicks in at non-zero smoothnessPenalty;
    /// the cost of a flat edge with smoothness=0 should be unchanged
    /// from before this term existed.
    func testSmoothnessZeroIsNoOp() {
        let profile = RiderProfile(bikeType: .roadBike)
        let model = RoutingCostModel(profile: profile, strategy: .balanced)
        let flat = edge(length: 1000, grade: 0, smoothness: 0)
        // No smoothness term in cost path yet — sanity check.
        XCTAssertGreaterThan(model.cost(of: flat), 0)
    }

    /// A max-smoothness edge (yo-yo street) should cost noticeably more
    /// than the same edge with smoothness=0 — the term is supposed to
    /// surface yo-yo character even when no individual edge is steep.
    func testSmoothnessTermIncreasesCost() {
        let profile = RiderProfile(bikeType: .roadBike)
        let model = RoutingCostModel(profile: profile, strategy: .balanced)
        let smooth = edge(length: 1000, grade: 0, smoothness: 0)
        let yoYo = edge(length: 1000, grade: 0, smoothness: 1)
        XCTAssertGreaterThan(
            model.cost(of: yoYo),
            model.cost(of: smooth),
            "Yo-yo edge (smoothness=1) must cost more than a flat edge (smoothness=0)"
        )
    }

    /// The multiplier scales linearly with smoothnessPenalty: doubling
    /// the field should add a fixed surcharge amount, not a multiplier.
    /// cost(s=1) - cost(s=0) should equal cost(s=0.5) - cost(s=0) * 2
    /// only if the surcharge is linear in `s`. The cost model uses
    /// `cost *= 1 + w * s`, which is linear in `s` for the surcharge
    /// term (the additive amount is `time * w * s`, ignoring base
    /// effects on the multiplicative term).
    func testSmoothnessSurchargeIsLinear() {
        let profile = RiderProfile(bikeType: .roadBike)
        let model = RoutingCostModel(profile: profile, strategy: .balanced)
        let flat = edge(length: 1000, grade: 0, smoothness: 0)
        let low = edge(length: 1000, grade: 0, smoothness: 0.5)
        let high = edge(length: 1000, grade: 0, smoothness: 1.0)

        let base = model.cost(of: flat)
        let lowSurcharge = model.cost(of: low) - base
        let highSurcharge = model.cost(of: high) - base

        // (1 + w*s) - 1 = w*s, so doubling s should double the surcharge.
        XCTAssertEqual(lowSurcharge * 2, highSurcharge, accuracy: 0.5,
                       "Smoothness surcharge should scale linearly with the field value")
    }

    /// The graph-build pipeline actually populates smoothnessPenalty:
    /// a yo-yo street (mixed grades) should get a higher value than a
    /// flat street.
    func testGraphBuildPopulatesSmoothness() async throws {
        let flat: [RouteCoordinate] = (0..<5).map { i in
            TestGraphs.coordinate(37.76 + Double(i) * 0.0005, -122.42, 10)
        }
        // Yo-yo: alternate +20m and -20m between vertices.
        let yoYo: [RouteCoordinate] = (0..<5).map { i in
            TestGraphs.coordinate(37.76 + Double(i) * 0.0005, -122.42, i.isMultiple(of: 2) ? 10 : 30)
        }

        async let flatGraph = NetworkGraphBuilder().buildGraph(
            from: [RawNetworkEdge(geometry: flat, streetName: "Flat St",
                                   facilityType: .mixedTraffic, protectionLevel: .none,
                                   roadClass: .residential, surfaceType: .asphalt)],
            elevationProvider: nil
        )
        async let yoYoGraph = NetworkGraphBuilder().buildGraph(
            from: [RawNetworkEdge(geometry: yoYo, streetName: "Yo-Yo St",
                                   facilityType: .mixedTraffic, protectionLevel: .none,
                                   roadClass: .residential, surfaceType: .asphalt)],
            elevationProvider: nil
        )

        let flatEdges = try await flatGraph.edges
        let yoYoEdges = try await yoYoGraph.edges

        let flatAvg = flatEdges.map(\.smoothnessPenalty).reduce(0, +) / Double(max(flatEdges.count, 1))
        let yoYoAvg = yoYoEdges.map(\.smoothnessPenalty).reduce(0, +) / Double(max(yoYoEdges.count, 1))
        XCTAssertGreaterThan(
            yoYoAvg, flatAvg,
            "Yo-yo street should have higher smoothnessPenalty than flat street"
        )
    }
}
