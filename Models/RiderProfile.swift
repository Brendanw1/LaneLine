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
    /// Used for calorie estimation; kilograms.
    var weightKg: Double

    init(
        id: UUID = UUID(),
        name: String = "",
        bikeType: BikeType = .roadBike,
        hillTolerance: HillTolerance = .moderate,
        safetyPreference: SafetyPreference = .moderate,
        directnessPreference: DirectnessPreference = .balanced,
        surfaceSensitivity: SurfaceSensitivity = .moderate,
        appleMusicEnabled: Bool = false,
        defaultRidePlaylistID: String? = nil,
        weightKg: Double = 75
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
        self.weightKg = weightKg
    }

    /// Custom decoding so profiles saved before `weightKg` existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bikeType = try c.decode(BikeType.self, forKey: .bikeType)
        hillTolerance = try c.decode(HillTolerance.self, forKey: .hillTolerance)
        safetyPreference = try c.decode(SafetyPreference.self, forKey: .safetyPreference)
        directnessPreference = try c.decode(DirectnessPreference.self, forKey: .directnessPreference)
        surfaceSensitivity = try c.decode(SurfaceSensitivity.self, forKey: .surfaceSensitivity)
        appleMusicEnabled = try c.decode(Bool.self, forKey: .appleMusicEnabled)
        defaultRidePlaylistID = try c.decodeIfPresent(String.self, forKey: .defaultRidePlaylistID)
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg) ?? 75
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
