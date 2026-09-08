import XCTest
import CoreLocation
@testable import LaneLine

/// Behavioral probes of routing quality on the real bundled city graph.
/// These tests document current behavior on real SF terrain and guard
/// against regressions in grade/speed modeling. Failures here signal a
/// real product-quality regression, not a fixture problem.
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

    /// Sanity check on real SF terrain: a short urban hop should produce at
    /// least two meaningfully different candidates across strategies. If
    /// this drops to one, every strategy is converging on the same
    /// corridor — the user's "different route options" UX promise is broken.
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
        XCTAssertGreaterThanOrEqual(
            candidates.count, 2,
            "A real SF trip should produce multiple distinct candidates, not one consensus route"
        )
    }

    /// The bundled BBBike street extract doesn't include the Presidio; this
    /// trip exists as a placeholder for when coverage is extended.
    func testEmbarcaderoToCrissyPresidioCoverage() async throws {
        throw XCTSkip("Bundled street network does not cover the Presidio; revisit after coverage extension")
    }
}
