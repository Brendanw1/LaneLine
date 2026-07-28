import Foundation
import CoreLocation

/// Bikeway network parsed from bundled SFMTA CSV exports (manual DataSF
/// portal downloads) instead of a live API call. Reliable and instant —
/// this is the default bikeway source specifically because the live
/// Overpass street network has proven unreliable enough this session that
/// routing needs a path that doesn't depend on any external service being
/// up. Loads both the broad MTA Bike Network export and the narrower, more
/// detailed Protected Bike Lanes export and returns every valid row from
/// both — CNN is a street-block identifier, not a unique row key (SFMTA
/// records multiple treatments per block), so rows are concatenated rather
/// than merged by CNN. A block appearing in both files just becomes two
/// overlapping graph edges, which the router treats as parallel options —
/// harmless, unlike silently dropping real segments would be.
struct LocalBikewayDataSource: BikewayNetworkProviding {
    var bundle: Bundle = .main
    var baseResourceName = "MTA_Bike_Network_Linear_Features"
    var protectedResourceName = "Protected_Bike_Lanes"

    func fetchBikewayNetwork(in bounds: BoundingBox) async throws -> BikewayNetwork {
        let segments = loadSegments(resourceName: baseResourceName)
            + loadSegments(resourceName: protectedResourceName)

        let inBounds = segments.filter { segment in
            segment.geometry.contains { bounds.contains($0.clCoordinate) }
        }

        return BikewayNetwork(
            segments: inBounds,
            metadata: BikewayMetadata(
                source: "Local SFMTA bikeway export (bundled)",
                lastUpdated: .now,
                totalSegments: inBounds.count
            )
        )
    }

    // MARK: Loading

    private func loadSegments(resourceName: String) -> [BikewaySegment] {
        guard let url = bundle.url(forResource: resourceName, withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        var segments: [BikewaySegment] = []
        for (index, row) in Self.parseCSV(text).enumerated() {
            guard let shape = row["shape"] else { continue }
            let geometry = Self.parseLineString(shape)
            guard geometry.count >= 2 else { continue }

            let (facility, protection) = Self.mappedFacility(
                facilityT: row["FACILITY_T"],
                raised: row["RAISED"],
                buffered: row["BUFFERED"],
                sharrow: row["SHARROW"]
            )
            // OBJECTID is the true unique row key; CNN (also present) is
            // shared across multiple rows for the same street block.
            let rowID = row["OBJECTID"] ?? "\(resourceName)-\(index)"
            segments.append(BikewaySegment(
                id: "\(resourceName)-\(rowID)",
                geometry: geometry,
                facilityType: facility,
                protectionLevel: protection,
                streetName: row["STREETNAME"],
                oneWay: row["DIRECT"]?.uppercased() == "1W",
                widthMeters: nil,
                sourceDate: nil
            ))
        }
        return segments
    }

    // MARK: Facility mapping

    /// Mirrors `DataSFBikewayRecord.mappedFacility` — same SFMTA schema,
    /// same facility-class semantics, just sourced from a bundled CSV
    /// instead of the live JSON API.
    static func mappedFacility(
        facilityT: String?, raised: String?, buffered: String?, sharrow: String?
    ) -> (BikeFacilityType, ProtectionLevel) {
        switch facilityT?.uppercased() {
        case "CLASS I":
            return (.offStreetPath, .fullyProtected)
        case "CLASS IV":
            return (.protectedBikeLane, .fullyProtected)
        case "CLASS II":
            if raised?.uppercased() == "YES" { return (.protectedBikeLane, .fullyProtected) }
            if buffered?.uppercased() == "YES" { return (.bikeLane, .buffered) }
            return (.bikeLane, .standard)
        case "CLASS III":
            if sharrow == "1" { return (.sharedLane, .sharrows) }
            return (.bikeRoute, .none)
        default:
            return (.unknown, .unknown)
        }
    }

    // MARK: WKT geometry

    /// Parses a WKT `LINESTRING (lon lat, lon lat, ...)` string as exported
    /// by the DataSF portal's CSV download (GeoJSON order: longitude first).
    static func parseLineString(_ wkt: String) -> [RouteCoordinate] {
        guard let openParen = wkt.firstIndex(of: "("),
              let closeParen = wkt.lastIndex(of: ")")
        else { return [] }
        let inner = wkt[wkt.index(after: openParen)..<closeParen]
        return inner.split(separator: ",").compactMap { pair in
            let parts = pair.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]) else {
                return nil
            }
            return RouteCoordinate(latitude: lat, longitude: lon)
        }
    }

    // MARK: CSV parsing

    /// Minimal RFC-4180-ish CSV parser: handles quoted fields (including
    /// commas inside the WKT `shape` column) but not escaped `""` quotes —
    /// not present in this data. Returns each row as a header-keyed
    /// dictionary.
    static func parseCSV(_ text: String) -> [[String: String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false

        for char in text {
            if insideQuotes {
                if char == "\"" {
                    insideQuotes = false
                } else {
                    currentField.append(char)
                }
                continue
            }
            switch char {
            case "\"":
                insideQuotes = true
            case ",":
                currentRow.append(currentField)
                currentField = ""
            case "\n":
                currentRow.append(currentField)
                rows.append(currentRow)
                currentRow = []
                currentField = ""
            case "\r":
                continue
            default:
                currentField.append(char)
            }
        }
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }

        guard let header = rows.first else { return [] }
        return rows.dropFirst().map { row in
            Dictionary(uniqueKeysWithValues: zip(header, row))
        }
    }
}
