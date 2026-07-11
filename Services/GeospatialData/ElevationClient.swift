import Foundation
import CoreLocation

/// Source of terrain elevation for graph nodes. Grade and climb metrics are
/// derived from these values, so the provider must be deterministic for a
/// given coordinate.
protocol ElevationProviding: Sendable {
    /// Elevation in meters above sea level, or nil when unknown.
    func elevationMeters(at coordinate: CLLocationCoordinate2D) async throws -> Double?
}

/// Live client for the USGS 3DEP Elevation Point Query Service.
/// One request per point; always wrap in `CachingElevationProvider` so
/// repeated graph builds don't re-query the same intersections.
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

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GeospatialDataError.badResponse(source: "USGS EPQS")
        }
        return try JSONDecoder().decode(EPQSResponse.self, from: data).value
    }
}

/// Disk-persisted elevation cache keyed by ~11 m grid cells. SF terrain does
/// not change; cache entries never expire.
actor CachingElevationProvider: ElevationProviding {
    private let upstream: any ElevationProviding
    private var cache: [String: Double]
    private let cacheURL: URL

    init(upstream: any ElevationProviding, cacheDirectory: URL? = nil) {
        self.upstream = upstream
        let directory = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheURL = directory.appending(path: "elevation-cache.json")
        self.cache = (try? JSONDecoder().decode(
            [String: Double].self,
            from: Data(contentsOf: cacheURL)
        )) ?? [:]
    }

    func elevationMeters(at coordinate: CLLocationCoordinate2D) async throws -> Double? {
        let key = Self.cacheKey(for: coordinate)
        if let cached = cache[key] { return cached }

        guard let value = try await upstream.elevationMeters(at: coordinate) else { return nil }
        cache[key] = value
        persist()
        return value
    }

    static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}
