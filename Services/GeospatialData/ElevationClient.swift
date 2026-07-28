import Foundation
import CoreLocation

/// Source of terrain elevation for graph nodes. Grade and climb metrics are
/// derived from these values, so the provider must be deterministic for a
/// given coordinate.
protocol ElevationProviding: Sendable {
    /// Elevation in meters above sea level, or nil when unknown.
    func elevationMeters(at coordinate: CLLocationCoordinate2D) async throws -> Double?

    /// Batch lookup, index-aligned with the input. City-scale ingestion
    /// (tens of thousands of nodes) is only practical through this path.
    func elevationsMeters(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double?]
}

/// Returns nil for everything, instantly, with no network call. Wrapped by
/// a `CachingElevationProvider` to get a "cache-only, never fetch live"
/// elevation source — used when building a city-scale graph automatically
/// (first launch, no explicit user wait) where a live fetch for every
/// uncached node would take far too long to be reasonable.
struct NoOpElevationProvider: ElevationProviding {
    func elevationMeters(at coordinate: CLLocationCoordinate2D) async throws -> Double? { nil }
    func elevationsMeters(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double?] {
        Array(repeating: nil, count: coordinates.count)
    }
}

extension ElevationProviding {
    /// Point-only providers fall back to sequential lookups.
    func elevationsMeters(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double?] {
        var results: [Double?] = []
        results.reserveCapacity(coordinates.count)
        for coordinate in coordinates {
            results.append(try await elevationMeters(at: coordinate))
        }
        return results
    }
}

/// Live client for the Open-Meteo elevation API (Copernicus GLO-90 DEM).
/// Accepts up to 100 coordinates per request, which makes it the only
/// workable primary source for whole-city graph builds on a phone.
struct OpenMeteoElevationClient: ElevationProviding {
    var endpoint = URL(string: "https://api.open-meteo.com/v1/elevation")!
    var session: URLSession = .shared
    /// API maximum per request.
    static let batchLimit = 100

    private struct Response: Decodable {
        let elevation: [Double]
    }

    func elevationMeters(at coordinate: CLLocationCoordinate2D) async throws -> Double? {
        try await elevationsMeters(at: [coordinate]).first ?? nil
    }

    /// Batches run concurrently (bounded) rather than one-at-a-time — a
    /// cold-cache citywide ingestion can be dozens of 100-coordinate
    /// batches, and sequential round-trips made that the dominant cost.
    private static let maxConcurrentBatches = 6

    func elevationsMeters(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double?] {
        guard !coordinates.isEmpty else { return [] }

        let batches: [(start: Int, chunk: [CLLocationCoordinate2D])] = stride(
            from: 0, to: coordinates.count, by: Self.batchLimit
        ).map { start in
            (start, Array(coordinates[start..<min(start + Self.batchLimit, coordinates.count)]))
        }

        var results = [Double?](repeating: nil, count: coordinates.count)

        try await withThrowingTaskGroup(of: (Int, [Double?]).self) { group in
            var nextIndex = 0
            func submitNext() {
                guard nextIndex < batches.count else { return }
                let batch = batches[nextIndex]
                nextIndex += 1
                group.addTask {
                    (batch.start, try await self.fetchBatch(batch.chunk))
                }
            }
            for _ in 0..<min(Self.maxConcurrentBatches, batches.count) { submitNext() }

            while let (start, values) = try await group.next() {
                for (offset, value) in values.enumerated() {
                    results[start + offset] = value
                }
                submitNext()
            }
        }
        return results
    }

    /// A single batch failing (transient status *or* a dropped connection)
    /// used to throw the whole `withThrowingTaskGroup` call in
    /// `elevationsMeters`, which `CompositeElevationClient` then treated as
    /// "the batch source is down" and fell back to sequential single-point
    /// USGS queries for *every* coordinate in the caller's chunk (up to 300
    /// here) — not just the one that failed. Retrying here keeps a
    /// transient hiccup from cascading into thousands of one-at-a-time
    /// fallback requests.
    private func fetchBatch(_ chunk: [CLLocationCoordinate2D]) async throws -> [Double?] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(
                name: "latitude",
                value: chunk.map { String(format: "%.5f", $0.latitude) }.joined(separator: ",")
            ),
            URLQueryItem(
                name: "longitude",
                value: chunk.map { String(format: "%.5f", $0.longitude) }.joined(separator: ",")
            ),
        ]

        let request = URLRequest(url: components.url!)
        let data = try await fetchWithTransientRetry(
            request, session: session, source: "Open-Meteo elevation"
        )
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard decoded.elevation.count == chunk.count else {
                throw GeospatialDataError.badResponse(source: "Open-Meteo elevation")
            }
            return decoded.elevation.map { $0 }
        } catch {
            // A 200 with a body that isn't the expected JSON shape —
            // surface which service failed instead of Swift's generic
            // decoding error text ("data couldn't be read...").
            throw GeospatialDataError.badResponse(source: "Open-Meteo elevation")
        }
    }
}

/// Live client for the USGS 3DEP Elevation Point Query Service. Higher
/// resolution than the DEM behind Open-Meteo but strictly one point per
/// request — kept as the fallback when the batch source is unreachable.
struct USGSElevationClient: ElevationProviding {
    var endpoint = URL(string: "https://epqs.nationalmap.gov/v1/json")!
    var session: URLSession = .shared

    func elevationMeters(at coordinate: CLLocationCoordinate2D) async throws -> Double? {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "x", value: String(coordinate.longitude)),
            URLQueryItem(name: "y", value: String(coordinate.latitude)),
            URLQueryItem(name: "units", value: "Meters"),
            URLQueryItem(name: "wkid", value: "4326"),
        ]

        let request = URLRequest(url: components.url!)
        let data = try await fetchWithTransientRetry(request, session: session, source: "USGS EPQS")
        do {
            return try JSONDecoder().decode(EPQSResponse.self, from: data).value
        } catch {
            throw GeospatialDataError.badResponse(source: "USGS EPQS")
        }
    }
}

/// Batch-first source with a point-query fallback: Open-Meteo for bulk graph
/// builds, USGS when the batch service is down.
struct CompositeElevationClient: ElevationProviding {
    var primary: any ElevationProviding = OpenMeteoElevationClient()
    var fallback: any ElevationProviding = USGSElevationClient()

    func elevationMeters(at coordinate: CLLocationCoordinate2D) async throws -> Double? {
        do { return try await primary.elevationMeters(at: coordinate) }
        catch { return try await fallback.elevationMeters(at: coordinate) }
    }

    func elevationsMeters(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double?] {
        do { return try await primary.elevationsMeters(at: coordinates) }
        catch { return try await fallback.elevationsMeters(at: coordinates) }
    }
}

/// Disk-persisted elevation cache keyed by ~11 m grid cells. SF terrain does
/// not change; cache entries never expire. Seeded at init from a bundled
/// pre-fetched lookup covering the local bikeway network, so that network
/// (the one that's actually reliable — see `LocalBikewayDataSource`) needs
/// zero live elevation calls on a fresh install. Live fetches for anything
/// outside that set (e.g. a full OSM-derived graph, when Overpass
/// cooperates) still work exactly as before and merge into the same cache.
actor CachingElevationProvider: ElevationProviding {
    private let upstream: any ElevationProviding
    private var cache: [String: Double]
    private let cacheURL: URL

    init(upstream: any ElevationProviding, cacheDirectory: URL? = nil, bundle: Bundle = .main) {
        self.upstream = upstream
        let directory = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheURL = directory.appending(path: "elevation-cache.json")

        var seeded: [String: Double] = [:]
        if let bundledURL = bundle.url(forResource: "SFBikewayElevations", withExtension: "json"),
           let bundledCache = try? JSONDecoder().decode(
               [String: Double].self, from: Data(contentsOf: bundledURL)
           ) {
            seeded = bundledCache
        }
        let disk = (try? JSONDecoder().decode(
            [String: Double].self,
            from: Data(contentsOf: cacheURL)
        )) ?? [:]
        seeded.merge(disk) { _, fromDisk in fromDisk }
        self.cache = seeded
    }

    func elevationMeters(at coordinate: CLLocationCoordinate2D) async throws -> Double? {
        let key = Self.cacheKey(for: coordinate)
        if let cached = cache[key] { return cached }

        guard let value = try await upstream.elevationMeters(at: coordinate) else { return nil }
        cache[key] = value
        persist()
        return value
    }

    func elevationsMeters(at coordinates: [CLLocationCoordinate2D]) async throws -> [Double?] {
        var results: [Double?] = Array(repeating: nil, count: coordinates.count)
        var missIndices: [Int] = []
        var missCoordinates: [CLLocationCoordinate2D] = []

        for (index, coordinate) in coordinates.enumerated() {
            if let cached = cache[Self.cacheKey(for: coordinate)] {
                results[index] = cached
            } else {
                missIndices.append(index)
                missCoordinates.append(coordinate)
            }
        }
        guard !missCoordinates.isEmpty else { return results }

        let fetched = try await upstream.elevationsMeters(at: missCoordinates)
        for (offset, value) in fetched.enumerated() {
            results[missIndices[offset]] = value
            if let value {
                cache[Self.cacheKey(for: missCoordinates[offset])] = value
            }
        }
        persist()
        return results
    }

    static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
