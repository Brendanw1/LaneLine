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
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)"
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GeospatialDataError.badResponse(source: "Overpass")
        }
        return try JSONDecoder().decode(OverpassResponse.self, from: data).elements
    }
}
