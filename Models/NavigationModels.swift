import Foundation

// MARK: - Music Tray State

enum MusicTrayState: String, Codable {
    case hidden
    case compact
    case expanded
}

// MARK: - Layout Mode

enum LayoutMode: String, Codable, CaseIterable {
    case standard
    case largerControls
}

// MARK: - Metrics Priority

enum MetricsPriority: String, Codable, CaseIterable {
    case distance
    case time
    case climb
}

// MARK: - Camera Orientation

/// How the follow camera orients the ride map: rotating with travel
/// (heading-up, "up = where I'm going") or fixed north-up. North-up trades
/// the moving map for stable, always-readable streets — worth having when
/// stopped at a light studying the route.
enum CameraOrientation: String, Codable, CaseIterable {
    case headingUp
    case northUp
}

// MARK: - RideNavigationState

struct RideNavigationState: Identifiable, Codable, Equatable {
    let id: UUID
    var activeRouteID: UUID?
    var currentSegmentIndex: Int
    var nextManeuver: String?
    var distanceToNextTurnMeters: Double?
    var currentStreet: String?
    var upcomingStreet: String?
    var remainingDistanceMeters: Double
    var eta: Date?
    var currentGrade: Double?
    var climbRemainingMeters: Double
    var routeQualityIndicator: Double
    var routeConfidenceIndicator: Double
    var musicTrayState: MusicTrayState

    init(
        id: UUID = UUID(),
        activeRouteID: UUID? = nil,
        currentSegmentIndex: Int = 0,
        nextManeuver: String? = nil,
        distanceToNextTurnMeters: Double? = nil,
        currentStreet: String? = nil,
        upcomingStreet: String? = nil,
        remainingDistanceMeters: Double = 0,
        eta: Date? = nil,
        currentGrade: Double? = nil,
        climbRemainingMeters: Double = 0,
        routeQualityIndicator: Double = 1.0,
        routeConfidenceIndicator: Double = 1.0,
        musicTrayState: MusicTrayState = .compact
    ) {
        self.id = id
        self.activeRouteID = activeRouteID
        self.currentSegmentIndex = currentSegmentIndex
        self.nextManeuver = nextManeuver
        self.distanceToNextTurnMeters = distanceToNextTurnMeters
        self.currentStreet = currentStreet
        self.upcomingStreet = upcomingStreet
        self.remainingDistanceMeters = remainingDistanceMeters
        self.eta = eta
        self.currentGrade = currentGrade
        self.climbRemainingMeters = climbRemainingMeters
        self.routeQualityIndicator = routeQualityIndicator
        self.routeConfidenceIndicator = routeConfidenceIndicator
        self.musicTrayState = musicTrayState
    }
}

// MARK: - RideScreenCustomization

struct RideScreenCustomization: Codable, Equatable {
    var layoutMode: LayoutMode
    var largerControlsEnabled: Bool
    var highContrastEnabled: Bool
    var metricsPriority: MetricsPriority
    var musicTrayDefaultExpanded: Bool
    var visibleSecondaryMetrics: Set<SecondaryMetric>
    var dataPages: [RideDataPage]
    var cameraOrientation: CameraOrientation

    static let maxDataPages = 3

    enum SecondaryMetric: String, Codable, CaseIterable {
        case currentGrade
        case climbRemaining
        case routeQuality
        case currentSpeed
        case averageSpeed
        case heartRate
    }

    init(
        layoutMode: LayoutMode,
        largerControlsEnabled: Bool,
        highContrastEnabled: Bool,
        metricsPriority: MetricsPriority,
        musicTrayDefaultExpanded: Bool,
        visibleSecondaryMetrics: Set<SecondaryMetric>,
        dataPages: [RideDataPage] = [.defaultPage()],
        cameraOrientation: CameraOrientation = .headingUp
    ) {
        self.layoutMode = layoutMode
        self.largerControlsEnabled = largerControlsEnabled
        self.highContrastEnabled = highContrastEnabled
        self.metricsPriority = metricsPriority
        self.musicTrayDefaultExpanded = musicTrayDefaultExpanded
        self.visibleSecondaryMetrics = visibleSecondaryMetrics
        self.dataPages = dataPages
        self.cameraOrientation = cameraOrientation
    }

    /// Custom decoding so customizations saved before `dataPages` existed
    /// still load (the store falls back to `.default` on decode failure,
    /// which would silently reset the rider's other choices).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layoutMode = try c.decode(LayoutMode.self, forKey: .layoutMode)
        largerControlsEnabled = try c.decode(Bool.self, forKey: .largerControlsEnabled)
        highContrastEnabled = try c.decode(Bool.self, forKey: .highContrastEnabled)
        metricsPriority = try c.decode(MetricsPriority.self, forKey: .metricsPriority)
        musicTrayDefaultExpanded = try c.decode(Bool.self, forKey: .musicTrayDefaultExpanded)
        visibleSecondaryMetrics = try c.decode(Set<SecondaryMetric>.self, forKey: .visibleSecondaryMetrics)
        dataPages = try c.decodeIfPresent([RideDataPage].self, forKey: .dataPages) ?? [.defaultPage()]
        cameraOrientation = try c.decodeIfPresent(CameraOrientation.self, forKey: .cameraOrientation) ?? .headingUp
        // The heart-rate chip postdates the original metric set: a rider
        // who never touched the customization (still byte-equal to the old
        // default) gets the new chip; anyone who curated their own set
        // keeps exactly what they chose.
        if visibleSecondaryMetrics == Self.legacyDefaultVisibleSecondaryMetrics {
            visibleSecondaryMetrics = Self.default.visibleSecondaryMetrics
        }
    }

    /// `.default`'s secondary set before `heartRate` existed.
    private static let legacyDefaultVisibleSecondaryMetrics: Set<SecondaryMetric> = [
        .currentGrade, .climbRemaining,
    ]

    static let `default` = RideScreenCustomization(
        layoutMode: .standard,
        largerControlsEnabled: false,
        highContrastEnabled: false,
        metricsPriority: .time,
        musicTrayDefaultExpanded: false,
        visibleSecondaryMetrics: [.currentGrade, .climbRemaining, .heartRate],
        cameraOrientation: .headingUp
    )
}

// MARK: - RecentDestination

struct RecentDestination: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var searchedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        latitude: Double,
        longitude: Double,
        searchedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.searchedAt = searchedAt
    }
}

// MARK: - SavedPlace

struct SavedPlace: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var placeType: PlaceType

    enum PlaceType: String, Codable, CaseIterable {
        case home
        case work
        case frequent
        case custom
    }
}
