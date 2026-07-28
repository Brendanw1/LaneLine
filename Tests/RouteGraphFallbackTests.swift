import XCTest
import CoreLocation
@testable import LaneLine

/// Regression coverage for a real bug: on a fresh install (no disk cache,
/// no prior "Fetch live SF bike network" tap), `routeGraph(covering:)` was
/// falling back to the tiny 6-corridor demo network, so any real address
/// outside those corridors (e.g. Inner Richmond) hit "outside the routable
/// network" even though the bundled full-city data existed on disk.
final class RouteGraphFallbackTests: XCTestCase {
    func testFreshInstallRouteGraphCoversInnerRichmond() async throws {
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
        defer { try? FileManager.default.removeItem(at: tempCacheDir) }

        let service = GeospatialDataService(
            bikewayProvider: LocalBikewayDataSource(bundle: resourcesBundle),
            streetProvider: LocalStreetDataSource(bundle: resourcesBundle),
            elevationProvider: CachingElevationProvider(
                upstream: NoOpElevationProvider(),
                cacheDirectory: tempCacheDir,
                bundle: resourcesBundle
            ),
            cacheDirectory: tempCacheDir
        )

        // No prior ingestion, no disk cache — this exercises the exact
        // fresh-install path.
        let innerRichmond = CLLocationCoordinate2D(latitude: 37.7805, longitude: -122.4644)
        let bounds = GeoMath.boundingBox(containing: innerRichmond, innerRichmond, paddingMeters: 1500)
        let graph = try await service.routeGraph(covering: bounds)

        XCTAssertFalse(graph.isEmpty)
        let nearest = graph.nearestNode(to: innerRichmond)
        XCTAssertNotNil(nearest, "expected a routable node near Inner Richmond on first launch")
        if let nearest {
            let distance = GeoMath.distanceMeters(from: nearest.coordinate.clCoordinate, to: innerRichmond)
            XCTAssertLessThan(distance, 800, "nearest node must be within the routing snap distance")
        }

        // Confirms this went through the bundled-source path, not the tiny
        // demo network.
        let source = await service.currentSource
        if case .liveIngestion = source {
            // expected
        } else {
            XCTFail("expected .liveIngestion (built from bundled sources), got \(source)")
        }
    }
}
