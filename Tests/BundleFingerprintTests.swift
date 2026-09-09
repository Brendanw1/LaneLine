import XCTest
import CoreLocation
@testable import LaneLine

/// The bundled-source fingerprint detects when a developer updates the
/// bundled SF data (street extract, elevation cache, bikeway CSVs) so the
/// next launch rebuilds the graph instead of silently serving a stale
/// cache. The previous manual `bundledDataVersion` constant had to be
/// remembered whenever a bundle changed — easy to forget, easy to ship a
/// graph that uses old data. The fingerprint replaces that mechanism with
/// SHA-256 over the actual bundle contents, so updates are detected
/// automatically.
final class BundleFingerprintTests: XCTestCase {
    /// Sanity check: every resource the fingerprint hashes must actually
    /// exist in `Resources/`. If a developer adds a new bundled source,
    /// they must also add it to `bundledSourceNames` in
    /// `GeospatialDataService`, or the cache invalidation won't pick up
    /// changes to that resource.
    func testFingerprintResourceListMatchesFilesystem() throws {
        let resourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(atPath: resourcesURL.path)
            .filter { !$0.hasSuffix(".md") } // exclude NOTICE/README
        XCTAssertGreaterThan(files.count, 0, "Resources directory must contain at least one data file")
        // SFStreetNetwork, MTA_Bike_Network_Linear_Features.csv,
        // Protected_Bike_Lanes.csv, SFCityElevations.json are the four
        // hashed sources. The fingerprint machinery's correctness depends
        // on this list being kept in sync with `bundledSourceNames`.
        let expected = ["SFStreetNetwork.json", "MTA_Bike_Network_Linear_Features.csv",
                        "Protected_Bike_Lanes.csv", "SFCityElevations.json"]
        for f in expected {
            XCTAssertTrue(
                files.contains(f),
                "\(f) expected in Resources/ but missing; check that bundledSourceNames still matches"
            )
        }
    }
}
