import Foundation
import CoreLocation

// MARK: - Bike Facility & Road Enums

enum BikeFacilityType: String, Codable, CaseIterable {
    case protectedBikeLane
    case bikeLane
    case sharedLane
    case bikeRoute
    case offStreetPath
    case mixedTraffic
    case unknown
}

enum ProtectionLevel: String, Codable, CaseIterable {
    case fullyProtected     // Physical barrier
    case buffered           // Painted buffer
    case standard           // Painted line
    case sharrows           // Shared lane markings
    case none               // No bike infrastructure
    case unknown
}

enum RoadClass: String, Codable, CaseIterable {
    case residential
    case tertiary
    case secondary
    case primary
    case arterial
    case highway
    case unknown
}

enum SurfaceType: String, Codable, CaseIterable {
    case paved
    case asphalt
    case concrete
    case gravel
    case dirt
    case cobblestone
    case unknown
}

enum TurnType: String, Codable, CaseIterable {
    case straight
    case slightLeft
    case slightRight
    case left
    case right
    case sharpLeft
    case sharpRight
    case uTurn
    case unknown
}

// MARK: - RouteSegment

struct RouteSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var streetName: String?
    var geometry: [RouteCoordinate]
    var lengthMeters: Double
    var estimatedSeconds: Double
    var averageGrade: Double
    var maxGrade: Double
    var elevationGainMeters: Double
    var bikeFacilityType: BikeFacilityType
    var protectionLevel: ProtectionLevel
    var roadClass: RoadClass
    var surfaceType: SurfaceType
    var turnType: TurnType
    var intersectionStressScore: Double
    var segmentStressScore: Double
    var roadBikeSuitabilityScore: Double
    var confidenceScore: Double
    var accessRules: [String]

    init(
        id: UUID = UUID(),
        streetName: String? = nil,
        geometry: [RouteCoordinate] = [],
        lengthMeters: Double = 0,
        estimatedSeconds: Double = 0,
        averageGrade: Double = 0,
        maxGrade: Double = 0,
        elevationGainMeters: Double = 0,
        bikeFacilityType: BikeFacilityType = .unknown,
        protectionLevel: ProtectionLevel = .unknown,
        roadClass: RoadClass = .unknown,
        surfaceType: SurfaceType = .unknown,
        turnType: TurnType = .straight,
        intersectionStressScore: Double = 0.5,
        segmentStressScore: Double = 0.5,
        roadBikeSuitabilityScore: Double = 0.5,
        confidenceScore: Double = 1.0,
        accessRules: [String] = []
    ) {
        self.id = id
        self.streetName = streetName
        self.geometry = geometry
        self.lengthMeters = lengthMeters
        self.estimatedSeconds = estimatedSeconds
        self.averageGrade = averageGrade
        self.maxGrade = maxGrade
        self.elevationGainMeters = elevationGainMeters
        self.bikeFacilityType = bikeFacilityType
        self.protectionLevel = protectionLevel
        self.roadClass = roadClass
        self.surfaceType = surfaceType
        self.turnType = turnType
        self.intersectionStressScore = intersectionStressScore
        self.segmentStressScore = segmentStressScore
        self.roadBikeSuitabilityScore = roadBikeSuitabilityScore
        self.confidenceScore = confidenceScore
        self.accessRules = accessRules
    }
}

// MARK: - RouteCoordinate

struct RouteCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    var elevation: Double?

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(latitude: Double, longitude: Double, elevation: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.elevation = elevation
    }
}
