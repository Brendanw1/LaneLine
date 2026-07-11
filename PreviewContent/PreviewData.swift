import Foundation
import CoreLocation

/// Fixtures for SwiftUI previews only. Everything here uses the same models
/// the real pipeline produces; nothing in the app's runtime path references
/// this type. At runtime, candidates come from `RoutingService` over the
/// ingested graph — run the app to see live-planned routes.
enum PreviewData {
    // MARK: Rider

    static let riderProfile = RiderProfile(
        name: "Alex",
        bikeType: .roadBike,
        hillTolerance: .moderate,
        safetyPreference: .high,
        directnessPreference: .balanced,
        surfaceSensitivity: .high,
        appleMusicEnabled: true,
        defaultRidePlaylistID: "pl.mock-commute"
    )

    static let savedPlaces: [SavedPlace] = [
        SavedPlace(
            id: UUID(), name: "Home", address: "Valencia St & 24th St, San Francisco",
            latitude: 37.75215, longitude: -122.42060, placeType: .home
        ),
        SavedPlace(
            id: UUID(), name: "Work", address: "Ferry Building, San Francisco",
            latitude: 37.79550, longitude: -122.39370, placeType: .work
        ),
        SavedPlace(
            id: UUID(), name: "Golden Gate Park", address: "JFK Promenade, San Francisco",
            latitude: 37.77250, longitude: -122.46030, placeType: .frequent
        ),
    ]

    static let missionOrigin = CLLocationCoordinate2D(latitude: 37.75215, longitude: -122.42060)

    static var ferryBuildingDestination: SelectedDestination {
        SelectedDestination(
            name: "Ferry Building",
            address: "1 Ferry Building, San Francisco",
            coordinate: CLLocationCoordinate2D(latitude: 37.79550, longitude: -122.39370)
        )
    }

    @MainActor
    static func appModel() -> AppModel {
        let model = AppModel(persistence: PersistenceService())
        model.riderProfile = riderProfile
        model.savedPlaces = savedPlaces
        model.onboardingComplete = true
        model.isLoaded = true
        return model
    }

    // MARK: Sample candidates (preview-only)

    static let sampleCandidates: [RouteCandidate] = [balancedCandidate, fasterCandidate]

    private static let balancedCandidate: RouteCandidate = {
        let segments = [
            segment(
                street: "Valencia St",
                from: (37.75215, -122.42060, 19), to: (37.77100, -122.42260, 16),
                facility: .protectedBikeLane, protection: .fullyProtected,
                roadClass: .secondary, turn: .straight, stress: 0.18
            ),
            segment(
                street: "Market St",
                from: (37.77100, -122.42260, 16), to: (37.77970, -122.41270, 11),
                facility: .bikeLane, protection: .buffered,
                roadClass: .primary, turn: .right, stress: 0.38
            ),
            segment(
                street: "Market St",
                from: (37.77970, -122.41270, 11), to: (37.79550, -122.39370, 3),
                facility: .protectedBikeLane, protection: .fullyProtected,
                roadClass: .primary, turn: .straight, stress: 0.22
            ),
        ]
        return candidate(
            strategy: .balanced,
            segments: segments,
            reason: "Best overall fit for your road bike: 92% on bike infrastructure, with essentially no time penalty versus the direct option.",
            cautions: ["Busy crossing where you turn onto Market St."]
        )
    }()

    private static let fasterCandidate: RouteCandidate = {
        let segments = [
            segment(
                street: "Mission St",
                from: (37.75230, -122.41860, 18), to: (37.77000, -122.42030, 12),
                facility: .mixedTraffic, protection: ProtectionLevel.none,
                roadClass: .arterial, turn: .straight, stress: 0.72
            ),
            segment(
                street: "11th St",
                from: (37.77000, -122.42030, 12), to: (37.77400, -122.41540, 12),
                facility: .bikeLane, protection: .standard,
                roadClass: .secondary, turn: .right, stress: 0.4
            ),
            segment(
                street: "Folsom St",
                from: (37.77400, -122.41540, 12), to: (37.79020, -122.38970, 3),
                facility: .bikeLane, protection: .buffered,
                roadClass: .secondary, turn: .slightRight, stress: 0.35
            ),
        ]
        return candidate(
            strategy: .faster,
            segments: segments,
            reason: "The most direct option — 18 min and 4.4 km, trading some calmer streets for time.",
            cautions: ["Mission St carries heavier traffic with no protected lane."]
        )
    }()

    // MARK: Builders

    private static func segment(
        street: String,
        from: (Double, Double, Double),
        to: (Double, Double, Double),
        facility: BikeFacilityType,
        protection: ProtectionLevel,
        roadClass: RoadClass,
        turn: TurnType,
        stress: Double
    ) -> RouteSegment {
        let start = RouteCoordinate(latitude: from.0, longitude: from.1, elevation: from.2)
        let end = RouteCoordinate(latitude: to.0, longitude: to.1, elevation: to.2)
        let length = GeoMath.distanceMeters(from: start, to: end)
        let grade = length > 0 ? (to.2 - from.2) / length : 0

        return RouteSegment(
            streetName: street,
            geometry: [start, end],
            lengthMeters: length,
            estimatedSeconds: CyclingSpeedModel.traversalSeconds(
                lengthMeters: length, grade: grade, bikeType: .roadBike
            ),
            averageGrade: grade,
            maxGrade: max(0, grade),
            elevationGainMeters: max(0, to.2 - from.2),
            bikeFacilityType: facility,
            protectionLevel: protection,
            roadClass: roadClass,
            surfaceType: .asphalt,
            turnType: turn,
            intersectionStressScore: min(0.95, stress + 0.1),
            segmentStressScore: stress,
            roadBikeSuitabilityScore: max(0.1, 1 - stress * 0.6),
            confidenceScore: 0.9
        )
    }

    private static func candidate(
        strategy: RouteStrategyType,
        segments: [RouteSegment],
        reason: String,
        cautions: [String]
    ) -> RouteCandidate {
        let length = segments.reduce(0) { $0 + $1.lengthMeters }
        let seconds = segments.reduce(0) { $0 + $1.estimatedSeconds }
        let gain = segments.reduce(0) { $0 + $1.elevationGainMeters }
        let protected = segments
            .filter { $0.protectionLevel == .fullyProtected || $0.protectionLevel == .buffered }
            .reduce(0) { $0 + $1.lengthMeters }
        let facility = segments
            .filter { $0.bikeFacilityType != .mixedTraffic && $0.bikeFacilityType != .unknown }
            .reduce(0) { $0 + $1.lengthMeters }
        let stress = length > 0
            ? segments.reduce(0) { $0 + $1.segmentStressScore * $1.lengthMeters } / length
            : 0

        return RouteCandidate(
            label: strategy.displayName,
            strategyType: strategy,
            segments: segments,
            totalDistanceMeters: length,
            etaSeconds: seconds + Double(segments.count - 1) * 8,
            totalElevationGainMeters: gain,
            maxGrade: segments.map(\.maxGrade).max() ?? 0,
            protectedLanePercent: length > 0 ? protected / length : 0,
            bikeFacilityPercent: length > 0 ? facility / length : 0,
            roadBikeSuitabilityScore: length > 0
                ? segments.reduce(0) { $0 + $1.roadBikeSuitabilityScore * $1.lengthMeters } / length
                : 0,
            routeStressScore: stress,
            directnessScore: 0.85,
            confidenceScore: 0.9,
            recommendationReason: reason,
            cautionNotes: cautions
        )
    }
}
