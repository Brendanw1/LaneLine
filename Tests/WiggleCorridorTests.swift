import XCTest
import CoreLocation
@testable import LaneLine

final class WiggleCorridorMatchingTests: XCTestCase {
    private func coordinate(_ lat: Double, _ lon: Double) -> RouteCoordinate {
        RouteCoordinate(latitude: lat, longitude: lon)
    }

    func testMatchesRealWiggleStreetsInsideTheCorridor() {
        XCTAssertTrue(WiggleCorridor.matches(
            streetName: "Duboce Avenue", coordinates: [coordinate(37.7701, -122.4270)]
        ))
        XCTAssertTrue(WiggleCorridor.matches(
            streetName: "Steiner St", coordinates: [coordinate(37.7696, -122.4316)]
        ))
        XCTAssertTrue(WiggleCorridor.matches(
            streetName: "Waller Street", coordinates: [coordinate(37.7713, -122.4294)]
        ))
    }

    func testRejectsSameNamedStreetOutsideTheCorridor() {
        // A real "Waller Avenue" exists clear across the city (Bayview);
        // the name alone must not be enough to match.
        XCTAssertFalse(WiggleCorridor.matches(
            streetName: "Waller Avenue", coordinates: [coordinate(37.9287, -122.3357)]
        ))
        // Steiner Street continues for miles north of the actual Wiggle.
        XCTAssertFalse(WiggleCorridor.matches(
            streetName: "Steiner Street", coordinates: [coordinate(37.8003, -122.4378)]
        ))
    }

    func testRejectsUnrelatedStreetNames() {
        XCTAssertFalse(WiggleCorridor.matches(
            streetName: "Prescott Court", coordinates: [coordinate(37.7699, -122.4351)]
        ))
        XCTAssertFalse(WiggleCorridor.matches(
            streetName: nil, coordinates: [coordinate(37.7699, -122.4351)]
        ))
    }
}

/// Verifies the "Prefer the Wiggle" toggle against the real bundled graph.
final class WiggleRoutingTests: XCTestCase {
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

    /// Market/Church (east of the hills) to Cole/Parnassus (west of them),
    /// on the Faster strategy — which de-emphasizes climb/stress avoidance,
    /// so unlike Balanced it doesn't already commit tightly to the Wiggle
    /// on its own. Both paths pass near enough to touch it incidentally,
    /// but only the preferred one commits to riding it end to end instead
    /// of wandering through Scott/Oak/Baker/Page/Central/Masonic first.
    func testPreferWiggleFindsAMoreDirectPathThroughTheRealCorridor() async throws {
        let service = try makeService()
        let routing = RoutingService(geospatialService: service)

        let origin = CLLocationCoordinate2D(latitude: 37.7688, longitude: -122.4292)
        let destination = CLLocationCoordinate2D(latitude: 37.7639, longitude: -122.4498)
        let profile = RiderProfile(bikeType: .hybridFitness)

        let withWiggle = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.faster], preferWiggle: true
        )
        let withoutWiggle = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.faster], preferWiggle: false
        )

        guard let preferred = withWiggle.first, let plain = withoutWiggle.first else {
            return XCTFail("expected a route for both requests")
        }

        print("[wiggle] preferWiggle=true  dist=\(Int(preferred.totalDistanceMeters))m " +
              "usedWiggleCorridor=\(preferred.usedWiggleCorridor)")
        print("[wiggle] preferWiggle=false dist=\(Int(plain.totalDistanceMeters))m " +
              "usedWiggleCorridor=\(plain.usedWiggleCorridor)")

        XCTAssertTrue(
            preferred.usedWiggleCorridor,
            "Preferring the Wiggle on a real east-west crossing should actually route through it"
        )
        XCTAssertLessThan(
            preferred.totalDistanceMeters, plain.totalDistanceMeters,
            "Preferring the Wiggle should commit to a more direct path through it, not just touch it incidentally"
        )
    }
}
