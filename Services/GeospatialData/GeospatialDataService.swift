import Foundation

/// Where the currently served graph came from — surfaced in Settings so the
/// rider can see whether routing runs on live city data or the bundled sample.
enum NetworkSource: Equatable {
    case liveIngestion(Date)
    case diskCache(Date)
    case bundledSample

    var displayName: String {
        switch self {
        case .liveIngestion(let date):
            return "Live SF data (fetched \(date.formatted(date: .abbreviated, time: .shortened)))"
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

    /// Bump whenever a bundled source under `Resources/` changes in a way
    /// that should invalidate an already-persisted graph — otherwise a
    /// rider who already has a disk-cached graph from an older build never
    /// picks up the new data, since `loadCachedGraph` had no way to tell
    /// "this cache is stale" from "this cache is fine." Found the hard way:
    /// the elevation bundle went from a 6,789-point bikeway-only subset to
    /// full city coverage, but every device that had already built and
    /// cached a graph kept silently serving the old near-zero-grade one.
    private static let bundledDataVersion = 2
    private var versionURL: URL { cacheURL.deletingLastPathComponent().appending(path: "route-graph-version.txt") }

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
        // Elevation is deliberately cache-only here: the full city needs
        // ~395k node elevations and only ~22k (the rider's known commute
        // corridor) are pre-baked into the bundle. Live-fetching the rest
        // synchronously on first launch would mean hours of Open-Meteo
        // calls before a single route could be planned — exactly the stall
        // this whole local-data effort was meant to eliminate. Uncached
        // nodes just get nil elevation (flat-grade assumption) until an
        // explicit "Fetch live SF bike network" does a full live fetch.
        if let built = try? await buildFromBundledSources() {
            graph = built
            source = .liveIngestion(.now)
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
        do {
            rawEdges = builder.rawEdges(from: try await streetsTask, enrichedBy: bikeways)
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
        }
        guard !rawEdges.isEmpty else { throw GeospatialDataError.emptyNetwork }

        let built = try await builder.buildGraph(
            from: rawEdges,
            elevationProvider: elevationProvider,
            onProgress: onProgress
        )
        guard !built.isEmpty else { throw GeospatialDataError.emptyNetwork }

        graph = built
        source = .liveIngestion(.now)
        persistGraph(built)
        return built
    }

    // MARK: Disk cache

    private func loadCachedGraph() -> (graph: RouteGraph, date: Date)? {
        guard let storedVersion = try? String(contentsOf: versionURL, encoding: .utf8),
              Int(storedVersion.trimmingCharacters(in: .whitespacesAndNewlines)) == Self.bundledDataVersion,
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
        try? String(Self.bundledDataVersion).write(to: versionURL, atomically: true, encoding: .utf8)
    }
}
