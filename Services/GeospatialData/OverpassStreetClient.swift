import Foundation

/// Source of OSM-derived street geometry and attributes (road class, surface,
/// cycleway tags, one-way rules).
protocol StreetNetworkProviding: Sendable {
    func fetchStreets(in bounds: BoundingBox) async throws -> [OverpassElement]
}

/// Live client for the Overpass API. Queries every rideable way in the
/// bounding box with its geometry and the tags the graph builder consumes.
struct OverpassStreetClient: StreetNetworkProviding {
    struct Configuration: Sendable {
        var endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
        var timeoutSeconds: Int = 60
    }

    var configuration = Configuration()
    var session: URLSession = .shared

    func fetchStreets(in bounds: BoundingBox) async throws -> [OverpassElement] {
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

        return try await fetchWithRetry(request: request)
    }

    /// overpass-api.de is a shared public instance — under load it returns
    /// 429/502/503/504 transiently even for well-formed requests. One retry
    /// after a short backoff clears most of these without masking a real
    /// failure (a second consecutive failure still throws).
    private func fetchWithRetry(request: URLRequest, attempt: Int = 1) async throws -> [OverpassElement] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeospatialDataError.badResponse(source: "Overpass")
        }
        if (200..<300).contains(http.statusCode) {
            return try JSONDecoder().decode(OverpassResponse.self, from: data).elements
        }
        let transient = [429, 502, 503, 504].contains(http.statusCode)
        if transient, attempt < 2 {
            try await Task.sleep(for: .seconds(3))
            return try await fetchWithRetry(request: request, attempt: attempt + 1)
        }
        throw GeospatialDataError.badResponse(source: "Overpass")
    }
}
