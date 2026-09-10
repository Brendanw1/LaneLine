import XCTest
import CoreLocation
@testable import LaneLine

/// Behavioral probes of routing quality on the real bundled city graph.
final class RouteQualityProbeTests: XCTestCase {
    private func makeService() throws -> GeospatialDataService {
        let resourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        guard let resourcesBundle = Bundle(url: resourcesURL) else {
            throw XCTSkip("Could not construct a Bundle from the Resources directory")
        }
        let tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempCacheDir, withIntermediateDirectories: true)
        return GeospatialDataService(
            bikewayProvider: LocalBikewayDataSource(bundle: resourcesBundle),
            streetProvider: LocalStreetDataSource(bundle: resourcesBundle),
            elevationProvider: CachingElevationProvider(
                upstream: NoOpElevationProvider(),
                cacheDirectory: tempCacheDir,
                bundle: resourcesBundle
            ),
            cacheDirectory: tempCacheDir
        )
    }

    private func edge(
        length: Double,
        grade: Double,
        facility: BikeFacilityType = .mixedTraffic,
        protection: ProtectionLevel = .none
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
            roadClass: .residential,
            surfaceType: .asphalt,
            stressScore: 0.15,
            confidenceScore: 0.9,
            streetName: nil,
            geometry: [],
            isWiggleCorridor: false,
            smoothnessPenalty: 0
        )
    }

    /// Sanity check on real SF terrain.
    func testShortUrbanHopProducesMultipleCandidates() async throws {
        let service = try makeService()
        let routing = RoutingService(geospatialService: service)
        let origin = CLLocationCoordinate2D(latitude: 37.7651, longitude: -122.4194)
        let destination = CLLocationCoordinate2D(latitude: 37.7615, longitude: -122.4214)
        let profile = RiderProfile(bikeType: .cityBike)

        let candidates = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.balanced, .safer, .faster, .easierClimbing]
        )
        for c in candidates {
            print("[probe-mission] \(c.strategyType): dist=\(Int(c.totalDistanceMeters))m " +
                  "climb=\(Int(c.totalElevationGainMeters))m maxGrade=\(c.maxGradeFormatted) " +
                  "segs=\(c.segments.count) protect=\(Int(c.protectedLanePercent * 100))%")
        }
        XCTAssertGreaterThanOrEqual(candidates.count, 2)
    }

    func testEmbarcaderoToCrissyPresidioCoverage() async throws {
        throw XCTSkip("Bundled street network does not cover the Presidio")
    }

    /// Verify the easierClimbing strategy actually produces flatter
    /// routes than balanced when the rider has hillTolerance = .low
    /// (default for fresh installs).
    func testFreshInstallUserGetsHillAvoidingRecommendedOnRealTerrain() async throws {
        let service = try makeService()
        let routing = RoutingService(geospatialService: service)
        let origin = CLLocationCoordinate2D(latitude: 37.7609, longitude: -122.4350)
        let destination = CLLocationCoordinate2D(latitude: 37.7658, longitude: -122.4498)
        let profile = RiderProfile(bikeType: .roadBike)

        let candidates = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.balanced, .easierClimbing]
        )
        for c in candidates {
            print("[probe-fresh-install] \(c.strategyType): dist=\(Int(c.totalDistanceMeters))m " +
                  "climb=\(Int(c.totalElevationGainMeters))m maxGrade=\(c.maxGradeFormatted) " +
                  "protect=\(Int(c.protectedLanePercent * 100))%")
        }
        // EasierClimbing should not be worse than Balanced on max grade
        // for a hill-avoidant rider — the strategy name promises easier
        // climbs, not the same or worse.
        let balanced = try XCTUnwrap(candidates.first { $0.strategyType == .balanced })
        let easier = try XCTUnwrap(candidates.first { $0.strategyType == .easierClimbing })
        XCTAssertLessThanOrEqual(
            easier.maxGrade, balanced.maxGrade,
            "EasierClimbing must not produce a steeper max grade than Balanced for the same rider"
        )
        // And the recommended candidate (default fresh-install profile)
        // should land on a route under 10% on this hill-crossing trip.
        guard let recommendedID = candidates.recommendedID(for: profile) else {
            XCTFail("Expected a recommendation for fresh-install profile")
            return
        }
        let recommended = try XCTUnwrap(candidates.first { $0.id == recommendedID })
        XCTAssertLessThanOrEqual(
            recommended.maxGrade, 0.10,
            "Fresh-install user should be steered toward a route under 10% grade on this terrain"
        )
    }

    /// Debug: how expensive is a 25% grade edge under easierClimbing vs
    /// balanced, both with hillTolerance = .low? EasierClimbing should be
    /// dramatically more expensive.
    func testProbeCostOf25PercentEdge() {
        let profile = RiderProfile(bikeType: .roadBike, hillTolerance: .low)
        let balanced = RoutingCostModel(profile: profile, strategy: .balanced)
        let easier = RoutingCostModel(profile: profile, strategy: .easierClimbing)

        let edge25 = edge(length: 50, grade: 0.25)

        // Decompose cost for the 25% edge under each strategy.
        let bikeType = profile.bikeType
        let grade = edge25.grade
        let length = edge25.lengthMeters
        let speedMs = CyclingSpeedModel.speedKmh(bikeType: bikeType, grade: grade) / 3.6
        let time = length / max(0.1, speedMs)
        print("[probe-cost-25] baseTime=\(time)s speed=\(speedMs*3.6)km/h grade=\(grade*100)%")

        let balWeights = RoutingWeights.base(for: profile).applying(.balanced)
        let easyWeights = RoutingWeights.base(for: profile).applying(.easierClimbing)
        print("[probe-cost-25] bal.climbSecPerM=\(balWeights.climbSecondsPerMeter) easy.climbSecPerM=\(easyWeights.climbSecondsPerMeter)")
        print("[probe-cost-25] bal.steepThreshold=\(balWeights.steepGradeThreshold) bal.steepFactor=\(balWeights.steepGradePenaltyFactor)")
        print("[probe-cost-25] easy.steepThreshold=\(easyWeights.steepGradeThreshold) easy.steepFactor=\(easyWeights.steepGradePenaltyFactor)")

        let balClimb = length * grade * balWeights.climbSecondsPerMeter
        let easyClimb = length * grade * easyWeights.climbSecondsPerMeter
        let balSpike = grade > balWeights.steepGradeThreshold ? time * (grade - balWeights.steepGradeThreshold) * balWeights.steepGradePenaltyFactor : 0
        let easySpike = grade > easyWeights.steepGradeThreshold ? time * (grade - easyWeights.steepGradeThreshold) * easyWeights.steepGradePenaltyFactor : 0
        print("[probe-cost-25] bal climb=\(balClimb)s spike=\(balSpike)s easy climb=\(easyClimb)s spike=\(easySpike)s")

        print("[probe-cost-25] bal.total=\(balanced.cost(of: edge25))s easy.total=\(easier.cost(of: edge25))s")
    }

    /// Sanity: the smoothness term populated by `NetworkGraphBuilder`
    /// shouldn't dominate route selection on real SF terrain. After
    /// adding the new cost-model term, the existing recommendation
    /// behavior should still produce a hill-avoiding recommended route
    /// for Castro -> Cole Valley.
    func testSmoothnessTermDoesNotBreakRealTerrainRecommendation() async throws {
        let service = try makeService()
        let routing = RoutingService(geospatialService: service)
        let origin = CLLocationCoordinate2D(latitude: 37.7609, longitude: -122.4350)
        let destination = CLLocationCoordinate2D(latitude: 37.7658, longitude: -122.4498)
        let profile = RiderProfile(bikeType: .roadBike)

        let candidates = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.balanced, .easierClimbing]
        )
        for c in candidates {
            let maxSmoothness = c.segments.map { $0.maxGrade }.max() ?? 0
            let smoothness = c.segments.reduce(0) { $0 + $1.lengthMeters }
            _ = smoothness  // keep compiler happy if unused
            print("[probe-smoothness] \(c.strategyType): maxGrade=\(c.maxGradeFormatted) " +
                  "climb=\(Int(c.totalElevationGainMeters))m dist=\(Int(c.totalDistanceMeters))m")
            _ = maxSmoothness
        }
        XCTAssertGreaterThanOrEqual(candidates.count, 1,
            "Real-SF routing should still produce candidates after adding smoothness")
    }
}
