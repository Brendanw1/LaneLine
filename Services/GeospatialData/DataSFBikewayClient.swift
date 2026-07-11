import Foundation

/// Source of the official SFMTA bikeway network.
protocol BikewayNetworkProviding: Sendable {
    func fetchBikewayNetwork(in bounds: BoundingBox) async throws -> BikewayNetwork
}

/// Live client for the DataSF Socrata dataset **"MTA Bike Network Linear
/// Features"** (`ygmz-vaxd`) — the SFMTA-published bikeway network.
///
/// Endpoint and field schema verified against live responses. An app token is
/// optional but raises Socrata's rate limits; provide one via `Configuration`.
struct DataSFBikewayClient: BikewayNetworkProviding {
    struct Configuration: Sendable {
        var datasetID: String = "ygmz-vaxd"
        var baseURL = URL(string: "https://data.sfgov.org/resource")!
        /// Socrata `X-App-Token`. Load from Secrets.xcconfig in production.
        var appToken: String?
        var pageSize: Int = 5000
    }

    var configuration = Configuration()
    var session: URLSession = .shared

    func fetchBikewayNetwork(in bounds: BoundingBox) async throws -> BikewayNetwork {
        var records: [DataSFBikewayRecord] = []
        var offset = 0

        // Socrata's within_box takes (column, NW lat, NW lon, SE lat, SE lon).
        let whereClause = "within_box(shape, \(bounds.maxLat), \(bounds.minLon), \(bounds.minLat), \(bounds.maxLon))"

        repeat {
            let page = try await fetchPage(where: whereClause, offset: offset)
            records.append(contentsOf: page)
            if page.count < configuration.pageSize { break }
            offset += configuration.pageSize
        } while true

        let segments = records.compactMap(\.bikewaySegment)
        return BikewayNetwork(
            segments: segments,
            metadata: BikewayMetadata(
                source: "DataSF SFMTA Bikeway Network (\(configuration.datasetID))",
                lastUpdated: .now,
                totalSegments: segments.count
            )
        )
    }

    private func fetchPage(where whereClause: String, offset: Int) async throws -> [DataSFBikewayRecord] {
        var components = URLComponents(
            url: configuration.baseURL.appending(path: "\(configuration.datasetID).json"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "$where", value: whereClause),
            URLQueryItem(name: "$limit", value: String(configuration.pageSize)),
            URLQueryItem(name: "$offset", value: String(offset)),
        ]

        var request = URLRequest(url: components.url!)
        if let token = configuration.appToken {
            request.setValue(token, forHTTPHeaderField: "X-App-Token")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GeospatialDataError.badResponse(source: "DataSF")
        }
        return try JSONDecoder().decode([DataSFBikewayRecord].self, from: data)
    }
}

enum GeospatialDataError: Error, LocalizedError {
    case badResponse(source: String)
    case emptyNetwork
    case sampleDataMissing

    var errorDescription: String? {
        switch self {
        case .badResponse(let source):
            return "\(source) returned an unexpected response."
        case .emptyNetwork:
            return "No street network is available for this area yet."
        case .sampleDataMissing:
            return "Bundled sample network is missing from the app bundle."
        }
    }
}
