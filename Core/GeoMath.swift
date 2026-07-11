import Foundation
import CoreLocation

/// Pure geodesic math used by the ingestion pipeline, the routing engine,
/// and ride progress tracking. Kept dependency-free so it is trivially testable.
enum GeoMath {
    static let earthRadiusMeters: Double = 6_371_000

    /// Great-circle distance between two coordinates in meters.
    static func distanceMeters(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = a.latitude.radians
        let lat2 = b.latitude.radians
        let dLat = (b.latitude - a.latitude).radians
        let dLon = (b.longitude - a.longitude).radians

        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * asin(min(1, sqrt(h)))
    }

    static func distanceMeters(from a: RouteCoordinate, to b: RouteCoordinate) -> Double {
        distanceMeters(from: a.clCoordinate, to: b.clCoordinate)
    }

    /// Total length of a polyline in meters.
    static func polylineLengthMeters(_ coordinates: [RouteCoordinate]) -> Double {
        guard coordinates.count > 1 else { return 0 }
        return zip(coordinates, coordinates.dropFirst())
            .reduce(0) { $0 + distanceMeters(from: $1.0, to: $1.1) }
    }

    /// Initial bearing from `a` to `b` in degrees, normalized to 0..<360.
    static func bearingDegrees(
        from a: CLLocationCoordinate2D,
        to b: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = a.latitude.radians
        let lat2 = b.latitude.radians
        let dLon = (b.longitude - a.longitude).radians

        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x).degrees
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Signed turn angle in degrees between two bearings, in -180...180.
    /// Negative is a left turn, positive is a right turn.
    static func turnAngleDegrees(fromBearing: Double, toBearing: Double) -> Double {
        var delta = toBearing - fromBearing
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    /// Classify the turn between an incoming and outgoing edge.
    static func turnType(fromBearing: Double, toBearing: Double) -> TurnType {
        let angle = turnAngleDegrees(fromBearing: fromBearing, toBearing: toBearing)
        switch angle {
        case -20...20: return .straight
        case 20...60: return .slightRight
        case -60 ..< -20: return .slightLeft
        case 60...130: return .right
        case -130 ..< -60: return .left
        case 130...180: return .sharpRight
        case -180 ..< -130: return .sharpLeft
        default: return .unknown
        }
    }

    /// Bounding box that contains both coordinates, padded by `paddingMeters`.
    /// Used to scope ingestion queries to the area a route could plausibly use.
    static func boundingBox(
        containing a: CLLocationCoordinate2D,
        _ b: CLLocationCoordinate2D,
        paddingMeters: Double
    ) -> BoundingBox {
        let latPadding = paddingMeters / 111_000
        let midLat = (a.latitude + b.latitude) / 2
        let lonPadding = paddingMeters / (111_000 * max(0.01, cos(midLat.radians)))

        return BoundingBox(
            minLat: min(a.latitude, b.latitude) - latPadding,
            minLon: min(a.longitude, b.longitude) - lonPadding,
            maxLat: max(a.latitude, b.latitude) + latPadding,
            maxLon: max(a.longitude, b.longitude) + lonPadding
        )
    }
}

extension BoundingBox {
    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (minLat...maxLat).contains(coordinate.latitude)
            && (minLon...maxLon).contains(coordinate.longitude)
    }

    /// The full SF peninsula — default ingestion region for v1.
    static let sanFrancisco = BoundingBox(
        minLat: 37.703, minLon: -122.515,
        maxLat: 37.812, maxLon: -122.355
    )
}

private extension Double {
    var radians: Double { self * .pi / 180 }
    var degrees: Double { self * 180 / .pi }
}
