import Foundation
import CoreLocation

/// Street network parsed from a bundled OpenStreetMap extract (BBBike.org
/// San Francisco export, filtered to rideable ways — same criteria as the
/// live Overpass query: excludes motorways/steps/construction and
/// bicycle=no/private) instead of a live query. This is the default source
/// specifically because live Overpass has proven unreliable enough this
/// session — occasional total connection failures from multiple different
/// networks, not just load-related slowness — that routing needs a path
/// that doesn't depend on it being reachable at all.
///
/// The bundled file is stored in exactly the shape `OverpassResponse`
/// decodes (`{"elements": [{type, id, tags, geometry}]}`), so this is just
/// a file load — no separate parsing logic to keep in sync with the live
/// client's.
struct LocalStreetDataSource: StreetNetworkProviding {
    var bundle: Bundle = .main
    var resourceName = "SFStreetNetwork"

    func fetchStreets(
        in bounds: BoundingBox,
        onTileProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [OverpassElement] {
        onTileProgress(0, 1)
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            onTileProgress(1, 1)
            return []
        }
        let data = try Data(contentsOf: url)
        let elements = try JSONDecoder().decode(OverpassResponse.self, from: data).elements
        let inBounds = elements.filter { element in
            (element.geometry ?? []).contains {
                bounds.contains(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon))
            }
        }
        onTileProgress(1, 1)
        return inBounds
    }
}
