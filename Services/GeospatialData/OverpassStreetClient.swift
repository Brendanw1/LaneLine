import Foundation

/// Source of OSM-derived street geometry and attributes (road class, surface,
/// cycleway tags, one-way rules).
protocol StreetNetworkProviding: Sendable {
    /// `onTileProgress(completed, total)` fires on a background context as
    /// each sub-area finishes — hop to the main actor before touching UI.
    func fetchStreets(
        in bounds: BoundingBox,
        onTileProgress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [OverpassElement]
}

/// Live client for the Overpass API. Queries every rideable way in the
/// bounding box with its geometry and the tags the graph builder consumes.
///
/// A single whole-city query was unreliable on the free public instance —
/// large enough to occasionally 504 at the server's own gateway regardless
/// of anything the client does. Splitting the bounds into a grid of smaller
/// tiles and fetching them with bounded concurrency keeps each individual
/// request small and fast, and lets a slow/failed tile retry (or eventually
/// fail) without taking the whole fetch down with it.
struct OverpassStreetClient: StreetNetworkProviding {
    struct Configuration: Sendable {
        var endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
        var timeoutSeconds: Int = 60
        /// Splits the requested bounds into `gridRows * gridColumns` tiles.
        var gridRows: Int = 3
        var gridColumns: Int = 3
        var maxConcurrentTiles: Int = 3
        /// Tiles overlapping this box are fetched before any others, so a
        /// rider's known commute corridor is covered first. Defaults to a
        /// band covering Inner Richmond, the Geary corridor, and the
        /// Financial District.
        var priorityBounds: BoundingBox? = BoundingBox(
            minLat: 37.775, minLon: -122.47, maxLat: 37.80, maxLon: -122.395
        )
    }

    var configuration = Configuration()
    var session: URLSession = .shared

    /// One consistently-failing tile (the free public server occasionally
    /// tarpits or 504s even a single small tile under load) no longer takes
    /// the whole fetch down — tiles are fetched independently and a failure
    /// is tolerated as long as at least one tile came back with data. Since
    /// priority-corridor tiles are dispatched first, a rider's actual route
    /// is the part most likely to have already succeeded by the time a
    /// later tile fails.
    func fetchStreets(
        in bounds: BoundingBox,
        onTileProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [OverpassElement] {
        let tiles = orderedTiles(splitting: bounds)
        var merged: [Int64: OverpassElement] = [:]
        var completed = 0
        var lastError: Error?
        onTileProgress(0, tiles.count)

        await withTaskGroup(of: Result<[OverpassElement], Error>.self) { group in
            var nextIndex = 0
            func submitNext() {
                guard nextIndex < tiles.count else { return }
                let tile = tiles[nextIndex]
                nextIndex += 1
                group.addTask {
                    do { return .success(try await fetchTile(tile)) }
                    catch { return .failure(error) }
                }
            }
            for _ in 0..<min(configuration.maxConcurrentTiles, tiles.count) { submitNext() }

            while let result = await group.next() {
                switch result {
                case .success(let elements):
                    for element in elements where merged[element.id] == nil {
                        merged[element.id] = element
                    }
                case .failure(let error):
                    lastError = error
                }
                completed += 1
                onTileProgress(completed, tiles.count)
                submitNext()
            }
        }

        if merged.isEmpty, let lastError {
            throw lastError
        }
        return Array(merged.values)
    }

    /// Tiles overlapping `priorityBounds` first (the rider's known commute
    /// corridor), so if anything is slow or fails, the area someone is
    /// actually testing against is the part most likely to have already
    /// succeeded.
    private func orderedTiles(splitting bounds: BoundingBox) -> [BoundingBox] {
        let latStep = (bounds.maxLat - bounds.minLat) / Double(configuration.gridRows)
        let lonStep = (bounds.maxLon - bounds.minLon) / Double(configuration.gridColumns)

        var tiles: [BoundingBox] = []
        for row in 0..<configuration.gridRows {
            for column in 0..<configuration.gridColumns {
                tiles.append(BoundingBox(
                    minLat: bounds.minLat + Double(row) * latStep,
                    minLon: bounds.minLon + Double(column) * lonStep,
                    maxLat: bounds.minLat + Double(row + 1) * latStep,
                    maxLon: bounds.minLon + Double(column + 1) * lonStep
                ))
            }
        }

        guard let priority = configuration.priorityBounds else { return tiles }
        let (high, low) = tiles.reduce(into: ([BoundingBox](), [BoundingBox]())) { split, tile in
            if tile.intersects(priority) { split.0.append(tile) } else { split.1.append(tile) }
        }
        return high + low
    }

    private func fetchTile(_ bounds: BoundingBox) async throws -> [OverpassElement] {
        let bbox = "\(bounds.minLat),\(bounds.minLon),\(bounds.maxLat),\(bounds.maxLon)"
        // Rideable ways only: excludes motorways (bikes prohibited) and
        // non-traversable pseudo-highways.
        let query = """
        [out:json][timeout:\(configuration.timeoutSeconds)];
        way["highway"]
           ["highway"!~"motorway|motorway_link|steps|corridor|construction|proposed|raceway"]
           ["bicycle"!~"no|private"]
           (\(bbox));
        out tags geom;
        """

        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // overpass-api.de's front end 406s requests with no Accept header,
        // and appears to filter on User-Agent too — URLRequest sends neither
        // by default, unlike curl/browsers. Confirmed by reproducing the
        // exact request outside the app: missing either header reliably
        // 406s; a plain custom User-Agent plus Accept: */* reliably 200s.
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("LaneLine/1.1 (iOS bike routing app)", forHTTPHeaderField: "User-Agent")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)"
            .data(using: .utf8)

        let data = try await fetchWithTransientRetry(request, session: session, source: "Overpass")
        do {
            return try JSONDecoder().decode(OverpassResponse.self, from: data).elements
        } catch {
            // A 200 with a body that isn't the expected JSON shape
            // (truncated response, HTML error page, query-timeout remark) —
            // surface which service failed instead of Swift's generic
            // decoding error text.
            throw GeospatialDataError.badResponse(source: "Overpass")
        }
    }
}

private extension BoundingBox {
    func intersects(_ other: BoundingBox) -> Bool {
        minLat <= other.maxLat && maxLat >= other.minLat
            && minLon <= other.maxLon && maxLon >= other.minLon
    }
}
