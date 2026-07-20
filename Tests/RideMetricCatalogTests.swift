import XCTest
import CoreLocation
@testable import LaneLine

@MainActor
final class RideMetricCatalogTests: XCTestCase {
    func testFormatters() {
        XCTAssertEqual(RideFormat.speedValue(18.44), "18.4")
        XCTAssertEqual(RideFormat.speedValue(-2), "0.0")
        XCTAssertEqual(RideFormat.stopwatch(65), "1:05")
        XCTAssertEqual(RideFormat.stopwatch(3725), "1:02:05")
        XCTAssertEqual(RideFormat.wholeNumber(411.6), "412")
    }

    func testDefaultPageFillsTheGrid() {
        let page = RideDataPage.defaultPage()
        XCTAssertEqual(page.metrics.count, RideDataPage.maxMetrics)
        XCTAssertEqual(Set(page.metrics).count, page.metrics.count, "no duplicate metrics")
    }

    func testEveryMetricProducesADisplay() async throws {
        let graph = try await TestGraphs.stressTradeoffGraph()
        let routing = RoutingService(
            geospatialService: StubGeospatialService(graph: graph),
            scoringService: RouteScoringService()
        )
        let ride = ActiveRideModel(
            route: PreviewData.sampleCandidates[0],
            profile: .testProfile(bikeType: .roadBike),
            locationService: MockLocationService(),
            routingService: routing,
            voiceGuide: nil
        )
        let recorder = RideRecorder(
            profile: .testProfile(bikeType: .roadBike),
            routeName: "Test",
            startElevationMeters: 10,
            locationService: MockLocationService(),
            altimeter: MockAltimeter(),
            store: nil
        )
        for id in RideMetricID.allCases {
            let display = RideMetricCatalog.display(id, recorder: recorder, ride: ride)
            XCTAssertFalse(display.title.isEmpty, "\(id) needs a title")
            XCTAssertFalse(display.value.isEmpty, "\(id) needs a value")
        }
    }
}
