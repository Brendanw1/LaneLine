import XCTest
import CoreLocation
@testable import LaneLine

final class BikeParkingServiceTests: XCTestCase {
    private let csv = """
    "OBJECTID","ADDRESS","LOCATION","STREET","PLACEMENT","RACKS","SPACES","GLOBALID","INSTALL_YR","INSTALL_MO","LAT","LON","shape","data_as_of","data_loaded_at","analysis_neighborhood","supervisor_district"
    "1","100 Near St","Cafe, The Corner","NEAR","SIDEWALK","2","4",,"2017","1","37.7601","-122.4200","POINT (-122.42 37.7601)","x","x","Mission","9"
    "2","900 Far Ave",,"FAR","SIDEWALK","1","2",,"2020","5","37.8000","-122.4000","POINT (-122.4 37.8)","x","x","Marina","2"
    "3","500 Shape Only Rd","H&R block","SHAPE","SIDEWALK","3","6",,"2023","11",,,"POINT (-122.4210 37.7605)","x","x","Mission","9"
    "4","0 Bad Row","","BAD","SIDEWALK","1","2",,"2020","1",,,"","x","x","Nowhere","0"
    """

    private func makeService() throws -> BikeParkingService {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("racks-\(UUID().uuidString).csv")
        try csv.data(using: .utf8)!.write(to: url)
        return BikeParkingService(url: url)
    }

    func testNearestFirstWithShapeFallbackAndQuotedComma() async throws {
        let service = try makeService()
        let near = CLLocationCoordinate2D(latitude: 37.7600, longitude: -122.4200)
        let racks = await service.racks(near: near, limit: 10)

        // Row 4 has no coordinates at all and must be dropped.
        XCTAssertEqual(racks.count, 3)
        // Row 1 is nearest; row 3 (shape-only coordinates) is second.
        XCTAssertEqual(racks.map(\.id), ["1", "3", "2"])
        XCTAssertEqual(racks[0].name, "Cafe, The Corner")
        XCTAssertEqual(racks[0].spaces, 4)
        // LOCATION empty → falls back to ADDRESS.
        XCTAssertEqual(racks[2].name, "900 Far Ave")
        XCTAssertEqual(racks[1].latitude, 37.7605, accuracy: 0.0001)
    }

    func testLimitIsRespected() async throws {
        let service = try makeService()
        let racks = await service.racks(
            near: CLLocationCoordinate2D(latitude: 37.76, longitude: -122.42), limit: 1
        )
        XCTAssertEqual(racks.count, 1)
    }
}
