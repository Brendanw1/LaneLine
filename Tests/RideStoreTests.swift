import XCTest
@testable import LaneLine

final class RideStoreTests: XCTestCase {
    private var directory: URL!
    private var store: RideStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = RideStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeRecord(name: String = "Test ride", complete: Bool = true) -> RideRecord {
        let summary = RideSummary(
            id: UUID(), startedAt: .now, routeName: name,
            durationSeconds: 600, movingSeconds: 550, distanceMeters: 3000,
            averageSpeedKmh: 19.6, maxSpeedKmh: 32.1, ascentMeters: 45,
            descentMeters: 40, calories: 120, isComplete: complete
        )
        let samples = (0..<10).map {
            RideSample(t: Double($0), latitude: 37.76, longitude: -122.42,
                       altitudeMeters: 10, speedKmh: 18,
                       distanceMeters: Double($0) * 5, gradeDecimal: 0)
        }
        return RideRecord(summary: summary, samples: samples)
    }

    func testSaveAndLoadRoundTrip() async throws {
        let record = makeRecord()
        try await store.save(record)
        let loaded = await store.loadRecord(id: record.id)
        XCTAssertEqual(loaded, record)
    }

    func testSummariesIndexNewestFirst() async throws {
        var old = makeRecord(name: "Old")
        old.summary.startedAt = Date(timeIntervalSinceNow: -3600)
        let new = makeRecord(name: "New")
        try await store.save(old)
        try await store.save(new)
        let summaries = await store.loadSummaries()
        XCTAssertEqual(summaries.map(\.routeName), ["New", "Old"])
    }

    func testCheckpointThenFinalSaveKeepsOneEntry() async throws {
        var record = makeRecord(complete: false)
        await store.checkpoint(record)
        record.summary.isComplete = true
        try await store.save(record)
        let summaries = await store.loadSummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(summaries[0].isComplete)
    }

    func testDeleteRemovesRecordAndSummary() async throws {
        let record = makeRecord()
        try await store.save(record)
        await store.delete(id: record.id)
        let summaries = await store.loadSummaries()
        let loaded = await store.loadRecord(id: record.id)
        XCTAssertTrue(summaries.isEmpty)
        XCTAssertNil(loaded)
    }

    func testEmptyStoreListsNothing() async {
        let summaries = await store.loadSummaries()
        XCTAssertTrue(summaries.isEmpty)
    }
}
