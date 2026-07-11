import Foundation
import CoreLocation

// MARK: - Routing Service Protocol

protocol RoutingServiceProtocol: Sendable {
    /// Generate candidate routes with distinct tradeoff profiles for the
    /// rider, routed over the ingested street graph.
    func generateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: RiderProfile
    ) async throws -> [RouteCandidate]

    /// Generate routes for specific strategies only.
    func generateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: RiderProfile,
        strategies: [RouteStrategyType]
    ) async throws -> [RouteCandidate]

    /// Score a single route candidate against the rider profile.
    func scoreRoute(
        _ route: RouteCandidate,
        profile: RiderProfile
    ) async throws -> RouteScoreBreakdown
}

enum RoutingError: Error, LocalizedError {
    case originOffNetwork
    case destinationOffNetwork
    case noPathFound

    var errorDescription: String? {
        switch self {
        case .originOffNetwork:
            return "Your start point is outside the routable network."
        case .destinationOffNetwork:
            return "That destination is outside the routable network."
        case .noPathFound:
            return "No rideable route connects these points yet."
        }
    }
}

// MARK: - Route Scoring Service Protocol

protocol RouteScoringServiceProtocol: Sendable {
    /// Score a segment based on rider profile and preferences.
    func scoreSegment(
        _ segment: RouteSegment,
        profile: RiderProfile,
        preferences: RoutePreferenceProfile
    ) -> SegmentScore

    /// Compute a full route score breakdown from scored segments.
    func computeRouteScore(
        segments: [RouteSegment],
        segmentScores: [SegmentScore],
        directnessRatio: Double
    ) -> RouteScoreBreakdown
}

// MARK: - Supporting Types

struct BoundingBox: Codable, Equatable, Sendable {
    let minLat: Double
    let minLon: Double
    let maxLat: Double
    let maxLon: Double
}

struct BikewayNetwork: Codable {
    let segments: [BikewaySegment]
    let metadata: BikewayMetadata
}

struct BikewaySegment: Codable, Identifiable {
    let id: String
    let geometry: [RouteCoordinate]
    let facilityType: BikeFacilityType
    let protectionLevel: ProtectionLevel
    let streetName: String?
    let oneWay: Bool
    let widthMeters: Double?
    let sourceDate: Date?
}

struct BikewayMetadata: Codable {
    let source: String
    let lastUpdated: Date
    let totalSegments: Int
}

struct StreetAttribute: Codable, Identifiable {
    let id: String
    let roadClass: RoadClass
    let surfaceType: SurfaceType
    let speedLimitKmh: Double?
    let laneCount: Int?
    let isOneWay: Bool
    let hasBikeInfrastructure: Bool
}

struct SegmentScore: Codable {
    let travelTimeScore: Double
    let climbPenalty: Double
    let maxGradePenalty: Double
    let facilityBonus: Double
    let protectionBonus: Double
    let arterialPenalty: Double
    let surfacePenalty: Double
    let crossingPenalty: Double
    let turnPenalty: Double
    let totalScore: Double
}
