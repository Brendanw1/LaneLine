import Foundation
import CoreLocation

// MARK: - Model

/// One SFMTA bike rack installation (DataSF "Bicycle Parking Racks").
struct BikeParkingRack: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let address: String
    let placement: String?
    let racks: Int
    let spaces: Int
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Protocol

protocol BikeParkingServicing: Sendable {
    /// Nearest racks first. Empty when the dataset is missing or unparsable.
    func racks(near coordinate: CLLocationCoordinate2D, limit: Int) async -> [BikeParkingRack]
}

// MARK: - CSV-backed implementation

/// Parses the bundled SFMTA racks CSV once, lazily, then serves proximity
/// queries from memory (~6k rows).
actor BikeParkingService: BikeParkingServicing {
    private let url: URL?
    private var cache: [BikeParkingRack]?

    /// Pass a URL for tests; nil reads the bundled dataset.
    init(url: URL? = nil) {
        self.url = url
    }

    func racks(near coordinate: CLLocationCoordinate2D, limit: Int) async -> [BikeParkingRack] {
        loadIfNeeded()
            .sorted {
                GeoMath.distanceMeters(from: $0.coordinate, to: coordinate)
                    < GeoMath.distanceMeters(from: $1.coordinate, to: coordinate)
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Parsing

    private func loadIfNeeded() -> [BikeParkingRack] {
        if let cache { return cache }
        let resolved = url ?? Bundle.main.url(forResource: "SFBikeParkingRacks", withExtension: "csv")
        guard let resolved, let text = try? String(contentsOf: resolved, encoding: .utf8) else {
            cache = []
            return []
        }
        let parsed = Self.parse(csv: text)
        cache = parsed
        return parsed
    }

    static func parse(csv text: String) -> [BikeParkingRack] {
        let rows = csvRows(text)
        guard let header = rows.first else { return [] }
        func column(_ name: String) -> Int? {
            header.firstIndex { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        guard let idCol = column("OBJECTID"),
              let addressCol = column("ADDRESS"),
              let latCol = column("LAT"),
              let lonCol = column("LON") else { return [] }
        let locationCol = column("LOCATION")
        let placementCol = column("PLACEMENT")
        let racksCol = column("RACKS")
        let spacesCol = column("SPACES")
        let shapeCol = column("shape")

        return rows.dropFirst().compactMap { row in
            func field(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }
            // LAT/LON when present; some rows only carry the WKT POINT.
            var latitude = Double(field(latCol))
            var longitude = Double(field(lonCol))
            if latitude == nil || longitude == nil,
               let point = parseWKTPoint(field(shapeCol)) {
                latitude = point.latitude
                longitude = point.longitude
            }
            guard let latitude, let longitude,
                  latitude != 0, longitude != 0 else { return nil }

            let address = field(addressCol)
            let location = field(locationCol)
            return BikeParkingRack(
                id: field(idCol),
                name: location.isEmpty ? address : location,
                address: address,
                placement: field(placementCol).isEmpty ? nil : field(placementCol).capitalized,
                racks: Int(field(racksCol)) ?? 0,
                spaces: Int(field(spacesCol)) ?? 0,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    /// "POINT (-122.40 37.79)" → coordinate.
    private static func parseWKTPoint(_ wkt: String) -> CLLocationCoordinate2D? {
        guard let open = wkt.firstIndex(of: "("), let close = wkt.firstIndex(of: ")") else { return nil }
        let parts = wkt[wkt.index(after: open)..<close]
            .split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2,
              let lon = Double(parts[0]), let lat = Double(parts[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// Minimal RFC-4180 scanner: quoted fields may contain commas, doubled
    /// quotes, and newlines.
    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let c = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": endField()
                case "\n": endRow()
                case "\r": break
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
