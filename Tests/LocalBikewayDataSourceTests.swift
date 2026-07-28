import XCTest
@testable import LaneLine

final class LocalBikewayDataSourceTests: XCTestCase {
    func testParseCSVHandlesQuotedFieldWithEmbeddedCommas() {
        let text = """
        OBJECTID,CNN,STREETNAME,shape
        72,10553000,POLK ST,"LINESTRING (-122.4189 37.7817, -122.4190 37.7822)"
        721,8752202,MARKET ST,"LINESTRING (-122.4159 37.7778, -122.4163 37.7775)"
        """
        let rows = LocalBikewayDataSource.parseCSV(text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["CNN"], "10553000")
        XCTAssertEqual(rows[0]["STREETNAME"], "POLK ST")
        XCTAssertEqual(rows[0]["shape"], "LINESTRING (-122.4189 37.7817, -122.4190 37.7822)")
        XCTAssertEqual(rows[1]["STREETNAME"], "MARKET ST")
    }

    func testParseLineStringExtractsCoordinatesInLatLonOrder() {
        let wkt = "LINESTRING (-122.48245296 37.778262885, -122.483525398 37.778214306)"
        let coordinates = LocalBikewayDataSource.parseLineString(wkt)
        XCTAssertEqual(coordinates.count, 2)
        XCTAssertEqual(coordinates[0].longitude, -122.48245296, accuracy: 1e-6)
        XCTAssertEqual(coordinates[0].latitude, 37.778262885, accuracy: 1e-6)
        XCTAssertEqual(coordinates[1].longitude, -122.483525398, accuracy: 1e-6)
    }

    func testParseLineStringReturnsEmptyForMalformedInput() {
        XCTAssertEqual(LocalBikewayDataSource.parseLineString("").count, 0)
        XCTAssertEqual(LocalBikewayDataSource.parseLineString("LINESTRING ()").count, 0)
    }

    func testMappedFacilityMatchesDataSFRecordMapping() {
        let (classIFacility, classIProtection) = LocalBikewayDataSource.mappedFacility(
            facilityT: "CLASS I", raised: nil, buffered: nil, sharrow: nil
        )
        XCTAssertEqual(classIFacility, .offStreetPath)
        XCTAssertEqual(classIProtection, .fullyProtected)

        let (classIVFacility, classIVProtection) = LocalBikewayDataSource.mappedFacility(
            facilityT: "CLASS IV", raised: nil, buffered: nil, sharrow: nil
        )
        XCTAssertEqual(classIVFacility, .protectedBikeLane)
        XCTAssertEqual(classIVProtection, .fullyProtected)

        let (bufferedFacility, bufferedProtection) = LocalBikewayDataSource.mappedFacility(
            facilityT: "CLASS II", raised: "NO", buffered: "YES", sharrow: nil
        )
        XCTAssertEqual(bufferedFacility, .bikeLane)
        XCTAssertEqual(bufferedProtection, .buffered)

        let (sharrowFacility, sharrowProtection) = LocalBikewayDataSource.mappedFacility(
            facilityT: "CLASS III", raised: nil, buffered: nil, sharrow: "1"
        )
        XCTAssertEqual(sharrowFacility, .sharedLane)
        XCTAssertEqual(sharrowProtection, .sharrows)
    }

    /// Loads the real bundled CSVs end to end — this is the path the app now
    /// depends on whenever Overpass is unreachable, so it's worth verifying
    /// against the actual shipped files, not just synthetic rows.
    func testLoadsRealBundledBikewayFiles() async throws {
        let bundle = Bundle(for: Self.self)
        // Test target doesn't copy the app's Resources — locate the repo's
        // Resources directory directly instead.
        let resourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")

        guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
            throw XCTSkip("Resources directory not found relative to test file")
        }

        let baseText = try String(
            contentsOf: resourcesURL.appendingPathComponent("MTA_Bike_Network_Linear_Features.csv"),
            encoding: .utf8
        )
        let rows = LocalBikewayDataSource.parseCSV(baseText)
        XCTAssertGreaterThan(rows.count, 5000, "expected roughly 5458 data rows")

        var validGeometryCount = 0
        for row in rows.prefix(200) {
            guard let shape = row["shape"] else { continue }
            if LocalBikewayDataSource.parseLineString(shape).count >= 2 {
                validGeometryCount += 1
            }
        }
        XCTAssertGreaterThan(validGeometryCount, 150, "most sampled rows should have valid geometry")
        _ = bundle
    }
}
