import CoreLocation

/// San Francisco's real "Wiggle": a zigzag sequence of streets — Duboce,
/// Steiner, Waller, Pierce, Haight, Scott — that finds the flattest
/// connection between the eastern flats (Market/Mission) and the western
/// neighborhoods (Haight/Richmond/Sunset), threading between the steep
/// Buena Vista/Corona Heights hills instead of climbing over them. A real,
/// signed route riders already use — not a routing invention.
///
/// Matched by street name within a tight bounding box around the actual
/// corridor, not a hand-curated turn-by-turn segment list: several of these
/// names recur elsewhere in the city (a same-named street clear across
/// town, cross streets a few blocks north), so name alone over-matches and
/// the box alone under-specifies. Within this specific box, though, each
/// name only appears as part of the real Wiggle.
enum WiggleCorridor {
    private static let streetNames: Set<String> = [
        "duboce avenue", "steiner street", "waller street",
        "pierce street", "haight street", "scott street",
    ]

    /// Duboce Triangle / Lower Haight, generous enough to hold every block
    /// of the six streets above that's actually part of the route.
    private static let bounds = (
        minLat: 37.766, minLon: -122.446,
        maxLat: 37.774, maxLon: -122.418
    )

    static func matches(streetName: String?, coordinates: [RouteCoordinate]) -> Bool {
        guard let streetName, let normalized = normalize(streetName),
              streetNames.contains(normalized) else { return false }
        return coordinates.contains { coordinate in
            coordinate.latitude >= bounds.minLat && coordinate.latitude <= bounds.maxLat
                && coordinate.longitude >= bounds.minLon && coordinate.longitude <= bounds.maxLon
        }
    }

    private static func normalize(_ name: String) -> String? {
        var n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return nil }
        let suffixes: [(String, String)] = [(" st", " street"), (" ave", " avenue")]
        for (abbreviation, spelledOut) in suffixes where n.hasSuffix(abbreviation) {
            n = String(n.dropLast(abbreviation.count)) + spelledOut
        }
        return n
    }
}
