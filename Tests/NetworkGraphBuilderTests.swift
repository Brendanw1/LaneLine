import XCTest
@testable import LaneLine

/// Tests for the ingestion fusion pipeline: node snapping, directed edge
/// expansion, grade derivation, and DataSF facility mapping.
final class NetworkGraphBuilderTests: XCTestCase {

    func testSharedEndpointsSnapToOneNode() async throws {
        let shared = TestGraphs.coordinate(37.7700, -122.4200, 10)
        let graph = try await TestGraphs.build([
            TestGraphs.rawEdge(
                from: TestGraphs.coordinate(37.7690, -122.4200, 12),
                to: shared, street: "A St"
            ),
            TestGraphs.rawEdge(
                from: shared,
                to: TestGraphs.coordinate(37.7710, -122.4200, 8),
                street: "B St"
            ),
        ])
        // Three unique intersections, not four.
        XCTAssertEqual(graph.nodes.count, 3)
    }

    func testTwoWayEdgeBecomesTwoDirectedEdges() async throws {
        let graph = try await TestGraphs.build([
            TestGraphs.rawEdge(
                from: TestGraphs.coordinate(37.7700, -122.4200, 10),
                to: TestGraphs.coordinate(37.7710, -122.4200, 10),
                street: "Two Way"
            ),
        ])
        XCTAssertEqual(graph.edges.count, 2)
    }

    func testOneWayEdgeStaysSingleDirected() async throws {
        let graph = try await TestGraphs.build([
            TestGraphs.rawEdge(
                from: TestGraphs.coordinate(37.7700, -122.4200, 10),
                to: TestGraphs.coordinate(37.7710, -122.4200, 10),
                street: "One Way", oneWay: true
            ),
        ])
        XCTAssertEqual(graph.edges.count, 1)
    }

    func testGradeIsSignedAndMirrored() async throws {
        // ~111 m long with 8 m of climb → about +7% one way, −7% back.
        let graph = try await TestGraphs.build([
            TestGraphs.rawEdge(
                from: TestGraphs.coordinate(37.7700, -122.4200, 10),
                to: TestGraphs.coordinate(37.7710, -122.4200, 18),
                street: "Hill"
            ),
        ])
        let grades = graph.edges.map(\.grade).sorted()
        XCTAssertEqual(grades.count, 2)
        XCTAssertEqual(grades[0], -grades[1], accuracy: 0.001)
        XCTAssertEqual(abs(grades[1]), 0.072, accuracy: 0.01)
    }

    func testDataSFFacilityMapping() {
        func record(
            facility: String,
            buffered: String = "NO",
            raised: String = "NO",
            sharrow: String = "0"
        ) -> DataSFBikewayRecord {
            let json = """
            {
                "objectid": "1", "facility_t": "\(facility)",
                "buffered": "\(buffered)", "raised": "\(raised)",
                "sharrow": "\(sharrow)"
            }
            """
            return try! JSONDecoder().decode(
                DataSFBikewayRecord.self, from: json.data(using: .utf8)!
            )
        }

        XCTAssertEqual(record(facility: "CLASS I").mappedFacility.0, .offStreetPath)
        XCTAssertEqual(record(facility: "CLASS IV").mappedFacility.1, .fullyProtected)
        XCTAssertEqual(record(facility: "CLASS II").mappedFacility, (.bikeLane, .standard))
        XCTAssertEqual(
            record(facility: "CLASS II", buffered: "YES").mappedFacility.1, .buffered
        )
        XCTAssertEqual(
            record(facility: "CLASS II", raised: "YES").mappedFacility.1, .fullyProtected
        )
        XCTAssertEqual(
            record(facility: "CLASS III", sharrow: "1").mappedFacility.0, .sharedLane
        )
        XCTAssertEqual(record(facility: "CLASS III").mappedFacility.0, .bikeRoute)
    }

    func testUnknownSurfaceLowersConfidence() async throws {
        let known = try await TestGraphs.build([
            TestGraphs.rawEdge(
                from: TestGraphs.coordinate(37.7700, -122.4200, 10),
                to: TestGraphs.coordinate(37.7710, -122.4200, 10),
                street: "Known", surface: .asphalt
            ),
        ])
        let unknown = try await TestGraphs.build([
            TestGraphs.rawEdge(
                from: TestGraphs.coordinate(37.7700, -122.4200, 10),
                to: TestGraphs.coordinate(37.7710, -122.4200, 10),
                street: "Unknown", surface: .unknown
            ),
        ])
        XCTAssertGreaterThan(
            known.edges[0].confidenceScore,
            unknown.edges[0].confidenceScore
        )
    }
}

// Tuple comparison helper for the facility-mapping assertions.
private func XCTAssertEqual(
    _ actual: (BikeFacilityType, ProtectionLevel),
    _ expected: (BikeFacilityType, ProtectionLevel),
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(actual.0, expected.0, file: file, line: line)
    XCTAssertEqual(actual.1, expected.1, file: file, line: line)
}
