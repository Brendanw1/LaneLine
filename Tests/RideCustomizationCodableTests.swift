import XCTest
@testable import LaneLine

final class RideCustomizationCodableTests: XCTestCase {
    // Blobs saved before dataPages existed must decode and gain the default page.
    func testLegacyBlobGainsDefaultPage() throws {
        let legacy = """
        {"layoutMode":"standard","largerControlsEnabled":true,
         "highContrastEnabled":false,"metricsPriority":"climb",
         "musicTrayDefaultExpanded":false,
         "visibleSecondaryMetrics":["currentGrade"]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RideScreenCustomization.self, from: legacy)
        XCTAssertTrue(decoded.largerControlsEnabled)
        XCTAssertEqual(decoded.metricsPriority, .climb)
        XCTAssertEqual(decoded.dataPages.count, 1)
        XCTAssertEqual(decoded.dataPages[0].metrics, RideDataPage.defaultPage().metrics)
    }

    func testDataPagesRoundTrip() throws {
        var customization = RideScreenCustomization.default
        customization.dataPages = [
            RideDataPage(metrics: [.currentSpeed, .grade]),
            RideDataPage(metrics: [.calories]),
        ]
        let data = try JSONEncoder().encode(customization)
        let decoded = try JSONDecoder().decode(RideScreenCustomization.self, from: data)
        XCTAssertEqual(decoded.dataPages, customization.dataPages)
    }
}
