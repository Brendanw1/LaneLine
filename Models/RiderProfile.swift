import Foundation

// MARK: - BikeType

enum BikeType: String, Codable, CaseIterable {
    case roadBike
    case hybridFitness
    case gravel
    case cityBike
    case eBike
}

// MARK: - RiderProfile

struct RiderProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var bikeType: BikeType
    var hillTolerance: HillTolerance
    var safetyPreference: SafetyPreference
    var directnessPreference: DirectnessPreference
    var surfaceSensitivity: SurfaceSensitivity
    var appleMusicEnabled: Bool
    var defaultRidePlaylistID: String?

    init(
        id: UUID = UUID(),
        name: String = "",
        bikeType: BikeType = .roadBike,
        hillTolerance: HillTolerance = .moderate,
        safetyPreference: SafetyPreference = .moderate,
        directnessPreference: DirectnessPreference = .balanced,
        surfaceSensitivity: SurfaceSensitivity = .moderate,
        appleMusicEnabled: Bool = false,
        defaultRidePlaylistID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bikeType = bikeType
        self.hillTolerance = hillTolerance
        self.safetyPreference = safetyPreference
        self.directnessPreference = directnessPreference
        self.surfaceSensitivity = surfaceSensitivity
        self.appleMusicEnabled = appleMusicEnabled
        self.defaultRidePlaylistID = defaultRidePlaylistID
    }
}

// MARK: - Preference Enums

enum HillTolerance: String, Codable, CaseIterable {
    case low
    case moderate
    case high
}

enum SafetyPreference: String, Codable, CaseIterable {
    case low
    case moderate
    case high
}

enum DirectnessPreference: String, Codable, CaseIterable {
    case direct
    case balanced
    case scenic
}
