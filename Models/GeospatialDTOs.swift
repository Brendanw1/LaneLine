import Foundation

// DTOs mirror the wire formats of the three real data sources exactly, and
// nothing downstream of the mapping extensions ever sees them. Field names
// were verified against live responses (see README, "Data sources").

// MARK: - DataSF / SFMTA Bikeway Network (Socrata dataset ygmz-vaxd)

/// One record from `https://data.sfgov.org/resource/ygmz-vaxd.json`.
/// Socrata serves most scalar fields as strings.
struct DataSFBikewayRecord: Decodable {
    let objectid: String?
    let cnn: String?
    let streetname: String?
    let fromSt: String?
    let toSt: String?
    /// SFMTA facility class: "CLASS I" (off-street path), "CLASS II" (bike
    /// lane), "CLASS III" (signed route / sharrows), "CLASS IV" (separated
    /// bikeway).
    let facilityT: String?
    /// "2W" for two-way, "1W" for one-way segments.
    let direct: String?
    /// Legibly-cased street name, e.g. "Valencia Street".
    let street: String?
    /// Segment length in miles (stringified).
    let length: String?
    let symbology: String?
    let sharrow: String?
    let buffered: String?
    let raised: String?
    let contraflow: String?
    let dataAsOf: String?
    let shape: GeoJSONLineString?

    enum CodingKeys: String, CodingKey {
        case objectid, cnn, streetname, direct, length, symbology
        case sharrow, buffered, raised, contraflow, shape
        case fromSt = "from_st"
        case toSt = "to_st"
        case facilityT = "facility_t"
        case street = "street_"
        case dataAsOf = "data_as_of"
    }
}

/// Minimal GeoJSON LineString as embedded in Socrata `shape` columns.
struct GeoJSONLineString: Decodable {
    let type: String
    /// GeoJSON order: [longitude, latitude]
    let coordinates: [[Double]]

    var routeCoordinates: [RouteCoordinate] {
        coordinates.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return RouteCoordinate(latitude: pair[1], longitude: pair[0])
        }
    }
}

extension DataSFBikewayRecord {
    /// Map SFMTA facility class + treatment flags onto LaneLine's facility
    /// and protection model.
    var mappedFacility: (BikeFacilityType, ProtectionLevel) {
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

    var isOneWay: Bool { direct?.uppercased() == "1W" }

    var bikewaySegment: BikewaySegment? {
        guard let shape, shape.coordinates.count >= 2 else { return nil }
        let (facility, protection) = mappedFacility
        let dateFormatter = ISO8601DateFormatter()
        return BikewaySegment(
            id: cnn ?? objectid ?? UUID().uuidString,
            geometry: shape.routeCoordinates,
            facilityType: facility,
            protectionLevel: protection,
            streetName: street ?? streetname,
            oneWay: isOneWay,
            widthMeters: nil,
            sourceDate: dataAsOf.flatMap { dateFormatter.date(from: $0 + "Z") }
        )
    }
}

// MARK: - OpenStreetMap via Overpass API

/// Top-level Overpass JSON response (`[out:json]` + `out geom`).
struct OverpassResponse: Decodable {
    let elements: [OverpassElement]
}

struct OverpassElement: Decodable {
    let type: String
    let id: Int64
    let tags: [String: String]?
    let geometry: [OverpassPoint]?
}

struct OverpassPoint: Decodable {
    let lat: Double
    let lon: Double
}

extension OverpassElement {
    var routeCoordinates: [RouteCoordinate] {
        (geometry ?? []).map { RouteCoordinate(latitude: $0.lat, longitude: $0.lon) }
    }

    var mappedRoadClass: RoadClass {
        switch tags?["highway"] {
        case "residential", "living_street", "service":
            return .residential
        case "tertiary", "tertiary_link", "unclassified":
            return .tertiary
        case "secondary", "secondary_link":
            return .secondary
        case "primary", "primary_link":
            return .primary
        case "trunk", "trunk_link":
            return .arterial
        case "motorway", "motorway_link":
            return .highway
        case "cycleway", "path", "footway", "pedestrian", "track":
            return .residential
        default:
            return .unknown
        }
    }

    var mappedSurface: SurfaceType {
        switch tags?["surface"] {
        case "asphalt": return .asphalt
        case "concrete", "concrete:plates", "paving_stones": return .concrete
        case "paved": return .paved
        case "gravel", "fine_gravel", "compacted", "pebblestone": return .gravel
        case "dirt", "ground", "earth", "grass", "sand": return .dirt
        case "cobblestone", "sett", "unhewn_cobblestone": return .cobblestone
        case nil: return .unknown
        default: return .unknown
        }
    }

    var hasBikeInfrastructure: Bool {
        guard let tags else { return false }
        if tags["highway"] == "cycleway" { return true }
        return ["cycleway", "cycleway:left", "cycleway:right", "cycleway:both"]
            .contains { key in
                if let value = tags[key] { return value != "no" }
                return false
            }
    }

    /// OSM `maxspeed` is either "25 mph" or a plain km/h number.
    var speedLimitKmh: Double? {
        guard let raw = tags?["maxspeed"] else { return nil }
        if raw.hasSuffix("mph") {
            let digits = raw.replacingOccurrences(of: "mph", with: "")
                .trimmingCharacters(in: .whitespaces)
            return Double(digits).map { $0 * 1.609 }
        }
        return Double(raw)
    }

    var streetAttribute: StreetAttribute {
        StreetAttribute(
            id: "osm-way-\(id)",
            roadClass: mappedRoadClass,
            surfaceType: mappedSurface,
            speedLimitKmh: speedLimitKmh,
            laneCount: tags?["lanes"].flatMap { Int($0) },
            isOneWay: tags?["oneway"] == "yes",
            hasBikeInfrastructure: hasBikeInfrastructure
        )
    }
}

// MARK: - USGS Elevation Point Query Service (EPQS)

/// Response from `https://epqs.nationalmap.gov/v1/json?x=<lon>&y=<lat>&units=Meters`.
struct EPQSResponse: Decodable {
    let value: Double

    enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // EPQS has historically flipped between numeric and string payloads.
        if let number = try? container.decode(Double.self, forKey: .value) {
            value = number
        } else {
            let string = try container.decode(String.self, forKey: .value)
            guard let parsed = Double(string) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container,
                    debugDescription: "Unparseable elevation value: \(string)"
                )
            }
            value = parsed
        }
    }
}
