import XCTest
@testable import LaneLine

final class LocalStreetDataSourceTests: XCTestCase {
    /// Loads the real bundled BBBike extract end to end — this is the path
    /// the app now depends on for basic street connectivity, so it's worth
    /// verifying against the actual shipped file, not synthetic rows.
    func testLoadsRealBundledStreetNetwork() async throws {
        let resourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
            throw XCTSkip("Resources directory not found relative to test file")
        }

        let data = try Data(
            contentsOf: resourcesURL.appendingPathComponent("SFStreetNetwork.json")
        )
        let elements = try JSONDecoder().decode(OverpassResponse.self, from: data).elements
        XCTAssertGreaterThan(elements.count, 50_000, "expected roughly 102k rideable ways")

        // Exclusion filters should have actually applied during bake — no
        // motorways, and only elements with real geometry.
        for element in elements.prefix(2000) {
            XCTAssertNotEqual(element.tags?["highway"], "motorway")
            XCTAssertNotEqual(element.tags?["bicycle"], "no")
            XCTAssertGreaterThanOrEqual((element.geometry ?? []).count, 2)
        }
    }

    func testLocalStreetDataSourceFiltersToBounds() async throws {
        let bundle = Bundle(for: Self.self)
        _ = bundle // not used directly — LocalStreetDataSource loads via its own `bundle` param
        let resourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        guard let testBundle = Bundle(url: resourcesURL) else {
            throw XCTSkip("Could not construct a Bundle from the Resources directory")
        }

        let source = LocalStreetDataSource(bundle: testBundle)
        // A tight box around a single known intersection area, well inside
        // the full extract, to keep this test fast.
        let tinyBounds = BoundingBox(minLat: 37.779, minLon: -122.42, maxLat: 37.781, maxLon: -122.418)
        let elements = try await source.fetchStreets(in: tinyBounds) { _, _ in }
        XCTAssertFalse(elements.isEmpty, "expected at least some ways in a populated downtown block")
        XCTAssertLessThan(elements.count, 500, "a small bbox shouldn't return a city-scale result")
    }
}
