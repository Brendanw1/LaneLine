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
    /// USGS elevation), cache the result to disk, and serve it thereafter.
    func ingestLiveNetwork(in bounds: BoundingBox) async throws -> RouteGraph

    var currentSource: NetworkSource { get async }
}

/// Orchestrates the ingestion pipeline:
///
///     DataSF bikeways ─┐
///     OSM streets ─────┼─> NetworkGraphBuilder ─> RouteGraph ─> disk cache
///     USGS elevation ──┘
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

    var currentSource: NetworkSource { source }

    init(
        bikewayProvider: any BikewayNetworkProviding = DataSFBikewayClient(),
        streetProvider: any StreetNetworkProviding = OverpassStreetClient(),
        elevationProvider: (any ElevationProviding)? = nil,
        sampleLoader: SampleNetworkLoader = SampleNetworkLoader(),
        builder: NetworkGraphBuilder = NetworkGraphBuilder(),
        cacheDirectory: URL? = nil
    ) {
        self.bikewayProvider = bikewayProvider
        self.streetProvider = streetProvider
        self.elevationProvider = elevationProvider
            ?? CachingElevationProvider(upstream: USGSElevationClient())
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

        let sample = try await sampleLoader.loadGraph()
        graph = sample
        source = .bundledSample
        return sample
    }

    func ingestLiveNetwork(in bounds: BoundingBox) async throws -> RouteGraph {
        async let bikeways = bikewayProvider.fetchBikewayNetwork(in: bounds)
        async let streets = streetProvider.fetchStreets(in: bounds)

        let rawEdges = builder.rawEdges(from: try await streets, enrichedBy: try await bikeways)
        guard !rawEdges.isEmpty else { throw GeospatialDataError.emptyNetwork }

        let built = try await builder.buildGraph(
            from: rawEdges,
            elevationProvider: elevationProvider
        )
        guard !built.isEmpty else { throw GeospatialDataError.emptyNetwork }

        graph = built
        source = .liveIngestion(.now)
        persistGraph(built)
        return built
    }

    // MARK: Disk cache

    private func loadCachedGraph() -> (graph: RouteGraph, date: Date)? {
        guard let data = try? Data(contentsOf: cacheURL),
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
    }
}
