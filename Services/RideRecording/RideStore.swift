import Foundation

// MARK: - Ride Store Protocol

protocol RideStoring: Sendable {
    func save(_ record: RideRecord) async throws
    /// Crash-safety write of an in-progress ride; failures are swallowed —
    /// a checkpoint must never interrupt a ride.
    func checkpoint(_ record: RideRecord) async
    /// Newest first.
    func loadSummaries() async -> [RideSummary]
    func loadRecord(id: UUID) async -> RideRecord?
    func delete(id: UUID) async
}

// MARK: - File-backed implementation

/// One JSON file per ride plus a summaries index for fast history listing.
/// Sample logs grow far beyond what UserDefaults should hold, so rides live
/// in Application Support/Rides; tests inject a temp directory.
actor RideStore: RideStoring {
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rides", isDirectory: true)
    }

    func save(_ record: RideRecord) async throws {
        try ensureDirectory()
        let data = try encoder.encode(record)
        try data.write(to: recordURL(record.id), options: .atomic)
        var summaries = await loadSummaries().filter { $0.id != record.id }
        summaries.append(record.summary)
        summaries.sort { $0.startedAt > $1.startedAt }
        try writeIndex(summaries)
    }

    func checkpoint(_ record: RideRecord) async {
        try? await save(record)
    }

    func loadSummaries() async -> [RideSummary] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? decoder.decode([RideSummary].self, from: data)) ?? []
    }

    func loadRecord(id: UUID) async -> RideRecord? {
        guard let data = try? Data(contentsOf: recordURL(id)) else { return nil }
        return try? decoder.decode(RideRecord.self, from: data)
    }

    func delete(id: UUID) async {
        try? FileManager.default.removeItem(at: recordURL(id))
        let remaining = await loadSummaries().filter { $0.id != id }
        try? writeIndex(remaining)
    }

    // MARK: Internals

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private var indexURL: URL {
        directory.appendingPathComponent("summaries.json")
    }

    private func writeIndex(_ summaries: [RideSummary]) throws {
        try ensureDirectory()
        try encoder.encode(summaries).write(to: indexURL, options: .atomic)
    }
}
