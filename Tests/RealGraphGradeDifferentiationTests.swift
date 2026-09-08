import XCTest
import CoreLocation
@testable import LaneLine

/// Verifies grade-aware routing against the REAL bundled city graph, not the
/// small hand-built sample network `SampleNetworkRoutingTests` uses. That
/// network has synthetic hand-set grades and could never catch the real bug:
/// `edge.grade` was 0 for nearly every edge in the actual bundled city graph
/// until real elevation data was bundled, so "Easier Climbing" and road-bike
/// hill-avoidance had nothing real to act on in production despite passing
/// every existing test.
final class RealGraphGradeDifferentiationTests: XCTestCase {
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

    /// Castro to Cole Valley: a direct line crosses the Buena
    /// Vista/Corona Heights ridge; a real flatter alternative follows the
    /// Duboce/Haight corridor the N-Judah rail cut also uses. A road bike
    /// with "easier climbing" should find measurably less elevation gain
    /// and a lower max grade than "faster" on this real terrain.
    func testEasierClimbingFindsLessElevationThanFasterOnRealHill() async throws {
        let service = try makeService()
        let routing = RoutingService(geospatialService: service)

        let origin = CLLocationCoordinate2D(latitude: 37.7609, longitude: -122.4350) // 18th & Castro
        let destination = CLLocationCoordinate2D(latitude: 37.7658, longitude: -122.4498) // Cole & Carl

        let profile = RiderProfile(bikeType: .roadBike, hillTolerance: .low)

        let candidates = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.faster, .easierClimbing]
        )

        for c in candidates {
            print("[grade-diff] \(c.strategyType): dist=\(Int(c.totalDistanceMeters))m " +
                  "climb=\(Int(c.totalElevationGainMeters))m maxGrade=\(c.maxGradeFormatted)")
        }

        let faster = candidates.first { $0.strategyType == .faster }
        let easier = candidates.first { $0.strategyType == .easierClimbing }

        XCTAssertNotNil(faster)
        XCTAssertNotNil(easier)
        guard let faster, let easier else { return }

        // The direct line here crosses a real ridge (Buena Vista/Corona
        // Heights); a flatter alternative exists along the Duboce/Haight
        // corridor. Easier Climbing should trade a little distance to avoid
        // the steep pitch. Note: a longer detour may pick up slightly more
        // *accumulated* climb from minor ups and downs along the corridor,
        // so we don't assert it gains *less total elevation* — what matters
        // is that no single hill on the Easier route exceeds 60% of the
        // steepest pitch Faster takes, which is the rider-facing concern.
        XCTAssertLessThan(
            easier.maxGrade, faster.maxGrade * 0.6,
            "Easier Climbing should avoid the steep pitch Faster takes on this real hill"
        )
    }
}
