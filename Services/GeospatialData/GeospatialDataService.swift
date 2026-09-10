import Foundation
import CryptoKit

/// Where the currently served graph came from — surfaced in Settings so the
/// rider can see whether routing runs on live city data or the bundled sample.
enum NetworkSource: Equatable {
    case liveIngestion(Date)
    case liveBikewaysOnly(Date)
    case bundledCity(Date)
    case diskCache(Date)
    case bundledSample

    var displayName: String {
        switch self {
        case .liveIngestion(let date):
            return "Live SF data (fetched \(date.formatted(date: .abbreviated, time: .shortened)))"
        case .liveBikewaysOnly(let date):
            return "Live bikeways only (streets unavailable \(date.formatted(date: .abbreviated, time: .shortened)))"
        case .bundledCity(let date):
            return "Bundled SF data (built \(date.formatted(date: .abbreviated, time: .shortened)))"
        case .diskCache(let date):
            return "Cached SF data (\(date.formatted(date: .abbreviated, time: .shortened)))"
        case .bundledSample:
            return "Bundled sample network"
        }
    }
}

protocol GeospatialDataServiceProtocol: Sendable {
    /// Routable graph covering `bounds`. Resolution order: in-memory graph,
    /// disk-cached ingestion result, bundled sample network.
    func routeGraph(covering bounds: BoundingBox) async throws -> RouteGraph

    /// Run the full live ingestion pipeline (DataSF bikeways + OSM streets +
    /// batched elevation), cache the result to disk, and serve it thereafter.
    /// `onProgress` fires on a background context — hop to the main actor
    /// before touching UI state.
    func ingestLiveNetwork(
        in bounds: BoundingBox,
        onProgress: @escaping @Sendable (NetworkIngestionPhase) -> Void
    ) async throws -> RouteGraph

    var currentSource: NetworkSource { get async }
}

/// Coarse phase of live ingestion, for progress UI. Not a fraction-complete
/// progress bar — the pipeline's cost is dominated by a handful of large
/// network calls rather than many small steps, so a phase label is more
/// honest than a fabricated percentage.
enum NetworkIngestionPhase: Equatable, Sendable {
    case fetchingBikeways
    case fetchingStreets(tilesCompleted: Int, tilesTotal: Int)
    case computingElevation(completed: Int, total: Int)
    case buildingGraph
}

/// Orchestrates the ingestion pipeline:
///
///     DataSF bikeways ─────────────────┐
///     OSM streets ─────────────────────┼─> NetworkGraphBuilder ─> RouteGraph ─> disk cache
///     Elevation (Open-Meteo ⇢ USGS) ───┘
///
/// The bundled sample network flows through the identical builder, so route
/// scoring behaves the same in demo and live modes.
actor GeospatialDataService: GeospatialDataServiceProtocol {
    private let bikewayProvider: any BikewayNetworkProviding
    private let streetProvider: any StreetNetworkProviding
    private let elevationProvider: any ElevationProviding
    private let sampleLoader: SampleNetworkLoader
    private let builder: NetworkGraphBuilder
    private let cacheURL: URL

    private var graph: RouteGraph?
    private var source: NetworkSource = .bundledSample

    /// Hash of every bundled source file that affects the resulting graph.
    /// Computed on demand and cached alongside the graph so a stale cache
    /// from an older build is detected automatically — the previous manual
    /// `bundledDataVersion` constant got forgotten at least once, leaving
    /// devices silently serving a pre-fix graph after a bundle update.
    /// First-call cost is ~100 ms for SHA-256 over ~40 MB of bundled
    /// resources; subsequent reads hit `cachedBundleFingerprint` and pay
    /// nothing.
    private var cachedBundleFingerprint: String?
    private var versionURL: URL { cacheURL.deletingLastPathComponent().appending(path: "route-graph-fingerprint.txt") }

    var currentSource: NetworkSource { source }

    init(
        // Bundled sources (CSV export, BBBike OSM extract) instead of the
        // live DataSF/Overpass APIs — reliable and instant. Overpass in
        // particular has proven unreliable enough this session (repeated
        // total connection failures, not just slowness) that routing needs
        // a path that doesn't depend on it being reachable.
        bikewayProvider: any BikewayNetworkProviding = LocalBikewayDataSource(),
        streetProvider: any StreetNetworkProviding = LocalStreetDataSource(),
        elevationProvider: (any ElevationProviding)? = nil,
        sampleLoader: SampleNetworkLoader = SampleNetworkLoader(),
        builder: NetworkGraphBuilder = NetworkGraphBuilder(),
        cacheDirectory: URL? = nil
    ) {
        self.bikewayProvider = bikewayProvider
        self.streetProvider = streetProvider
        self.elevationProvider = elevationProvider
            ?? CachingElevationProvider(upstream: CompositeElevationClient())
        self.sampleLoader = sampleLoader
        self.builder = builder
        let directory = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheURL = directory.appending(path: "route-graph.json")
    }

    func routeGraph(covering bounds: BoundingBox) async throws -> RouteGraph {
        if let graph, !graph.isEmpty { return graph }

        if let cached = loadCachedGraph() {
            graph = cached.graph
            source = .diskCache(cached.date)
            return cached.graph
        }

        // Build from the bundled sources (BBBike street extract + local
        // bikeway CSVs) before falling back to the small demo network —
        // this is what makes the whole city routable on first launch,
        // without anyone having to visit Settings and tap "Fetch live SF
        // bike network" first. Both providers default to local/bundled data
        // now, so this doesn't touch the network for streets/bikeways.
        //
        // Elevation is deliberately cache-only here: live-fetching every
        // uncached node synchronously on first launch would stall routing
        // behind thousands of elevation calls — exactly the stall this
        // whole local-data effort was meant to eliminate. The bundled
        // cache carries city-wide coverage, so uncached nodes are the
        // exception, not the rule; they get nil elevation (flat-grade
        // assumption) until an explicit "Fetch live SF bike network"
        // does a full live fetch.
        if let built = try? await buildFromBundledSources() {
            graph = built
            source = .bundledCity(.now)
            persistGraph(built)
            return built
        }

        let sample = try await sampleLoader.loadGraph()
        graph = sample
        source = .bundledSample
        return sample
    }

    private func buildFromBundledSources() async throws -> RouteGraph {
        async let bikewaysTask = bikewayProvider.fetchBikewayNetwork(in: .sanFrancisco)
        async let streetsTask = streetProvider.fetchStreets(in: .sanFrancisco) { _, _ in }

        let rawEdges = builder.rawEdges(from: try await streetsTask, enrichedBy: try await bikewaysTask)
        guard !rawEdges.isEmpty else { throw GeospatialDataError.emptyNetwork }

        let cacheOnlyElevation = CachingElevationProvider(upstream: NoOpElevationProvider())
        let built = try await builder.buildGraph(from: rawEdges, elevationProvider: cacheOnlyElevation)
        guard !built.isEmpty else { throw GeospatialDataError.emptyNetwork }
        return built
    }

    func ingestLiveNetwork(
        in bounds: BoundingBox,
        onProgress: @escaping @Sendable (NetworkIngestionPhase) -> Void = { _ in }
    ) async throws -> RouteGraph {
        onProgress(.fetchingBikeways)
        async let bikewaysTask = bikewayProvider.fetchBikewayNetwork(in: bounds)
        async let streetsTask = streetProvider.fetchStreets(in: bounds) { completed, total in
            onProgress(.fetchingStreets(tilesCompleted: completed, tilesTotal: total))
        }

        let bikeways = try await bikewaysTask
        let rawEdges: [RawNetworkEdge]
        /// True when the street fetch failed and routing falls back to
        /// bikeways alone — the source label must say so.
        let streetsUnavailable: Bool
        do {
            rawEdges = builder.rawEdges(from: try await streetsTask, enrichedBy: bikeways)
            streetsUnavailable = false
        } catch {
            // OSM/Overpass is a free public service with no uptime
            // guarantee, and it can be unreachable for stretches at a time.
            // Rather than fail the whole fetch, fall back to routing over
            // the official bikeway network alone — real coverage (bike
            // lanes, paths, official routes), just without general street
            // connectivity between them.
            let bikewaysOnly = builder.rawEdges(fromBikewaysOnly: bikeways)
            guard !bikewaysOnly.isEmpty else { throw error }
            rawEdges = bikewaysOnly
            streetsUnavailable = true
        }
        guard !rawEdges.isEmpty else { throw GeospatialDataError.emptyNetwork }

        let built = try await builder.buildGraph(
            from: rawEdges,
            elevationProvider: elevationProvider,
            onProgress: onProgress
        )
        guard !built.isEmpty else { throw GeospatialDataError.emptyNetwork }

        graph = built
        source = streetsUnavailable ? .liveBikewaysOnly(.now) : .liveIngestion(.now)
        persistGraph(built)
        return built
    }

    // MARK: Disk cache

    private func loadCachedGraph() -> (graph: RouteGraph, date: Date)? {
        guard let fingerprint = bundledSourceFingerprint(),
              let storedFingerprint = try? String(contentsOf: versionURL, encoding: .utf8),
              storedFingerprint.trimmingCharacters(in: .whitespacesAndNewlines) == fingerprint,
              let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(RouteGraph.self, from: data),
              !cached.isEmpty,
              let modified = try? FileManager.default
                  .attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date
        else { return nil }
        return (cached, modified)
    }

    private func persistGraph(_ graph: RouteGraph) {
        guard let data = try? JSONEncoder().encode(graph) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        if let fingerprint = bundledSourceFingerprint() {
            try? fingerprint.write(to: versionURL, atomically: true, encoding: .utf8)
        }
    }

    /// SHA-256 of every bundled source whose contents feed the resulting
    /// graph. Any change to these files invalidates the on-disk cache
    /// automatically, so a developer who edits `SFCityElevations.json`
    /// doesn't need to remember to bump a version constant — the next
    /// launch detects the mismatch and rebuilds. Tests build the graph
    /// in-memory and don't write the cache file, so a missing bundle
    /// resource (the test target doesn't copy Resources) is treated as a
    /// valid empty-contribution fingerprint rather than an error.
    private func bundledSourceFingerprint() -> String? {
        if let cached = cachedBundleFingerprint { return cached }
        var hasher = SHA256()
        // Schema version for everything the file hashes can't see: the
        // builder, cost model, stress model, and scoring logic that shape
        // the graph just as much as the data does. Bump this whenever one
        // of those changes, or devices keep serving a pre-fix graph.
        hasher.update(data: Data(Self.graphSchemaVersion.utf8))
        var contributed = false
        for resource in Self.bundledSourceNames {
            guard let url = Bundle.main.url(forResource: resource, withExtension: nil) else { continue }
            contributed = true
            // Mix the resource name into the hash so a renamed file doesn't
            // silently match a stale cache entry.
            hasher.update(data: Data(resource.utf8))
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int {
                var sizeBE = size.bigEndian
                withUnsafeBytes(of: &sizeBE) { hasher.update(bufferPointer: $0) }
            }
            if let chunk = try? Data(contentsOf: url, options: .mappedIfSafe) {
                hasher.update(data: chunk)
            }
        }
        guard contributed else { return nil }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        cachedBundleFingerprint = hex
        return hex
    }

    /// Names of the bundled source files whose contents feed the graph.
    /// Add to this list whenever a new bundled resource is incorporated.
    private static let bundledSourceNames: [String] = [
        "SFStreetNetwork",
        "MTA_Bike_Network_Linear_Features",
        "Protected_Bike_Lanes",
        "SFCityElevations",
    ]

    /// Version of the graph-building logic itself (builder, cost model,
    /// stress model). Mixed into the cache fingerprint because file hashes
    /// can't see code: bump on any logic change that would alter the
    /// built graph, or devices keep serving the pre-change cache.
    private static let graphSchemaVersion = "3"
}
