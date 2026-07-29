import XCTest
import CoreLocation
@testable import LaneLine

final class CachingElevationProviderTests: XCTestCase {
    private struct FailingUpstream: ElevationProviding {
        func elevationMeters(at coordinate: CLLocationCoordinate2D) async throws -> Double? {
            throw GeospatialDataError.connectionFailed(source: "test upstream")
        }
        func elevationsMeters(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double?] {
            throw GeospatialDataError.connectionFailed(source: "test upstream")
        }
    }

    func testSeedsCacheFromBundledLookupAndAvoidsUpstreamCall() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let seedKey = "37.7805,-122.4644" // Inner Richmond, matches cacheKey format
        let seedData = try JSONEncoder().encode([seedKey: 42.0])
        try seedData.write(to: tempDir.appendingPathComponent("SFCityElevations.json"))

        guard let bundle = Bundle(url: tempDir) else {
            throw XCTSkip("Could not construct a Bundle from a plain directory on this platform")
        }
        XCTAssertNotNil(
            bundle.url(forResource: "SFCityElevations", withExtension: "json"),
            "sanity check: the seed file must actually be resolvable through Bundle lookup for this test to mean anything"
        )

        let provider = CachingElevationProvider(
            upstream: FailingUpstream(),
            cacheDirectory: tempDir.appendingPathComponent("cache-dir"),
            bundle: bundle
        )

        // The seeded coordinate should resolve without ever touching the
        // (deliberately failing) upstream.
        let seeded = try await provider.elevationMeters(
            at: CLLocationCoordinate2D(latitude: 37.7805, longitude: -122.4644)
        )
        XCTAssertEqual(seeded, 42.0)

        // An unseeded coordinate still has to go to upstream, and upstream
        // fails — proving the cache isn't just returning stale/wrong data
        // for everything.
        do {
            _ = try await provider.elevationMeters(
                at: CLLocationCoordinate2D(latitude: 10.0, longitude: 10.0)
            )
            XCTFail("expected upstream failure for an unseeded coordinate")
        } catch {
            // expected
        }
    }
}
