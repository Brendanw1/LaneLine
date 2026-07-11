import Foundation

// MARK: - Persistence Service Protocol

protocol PersistenceServiceProtocol {
    /// Save rider profile
    func saveProfile(_ profile: RiderProfile) async throws

    /// Load rider profile
    func loadProfile() async throws -> RiderProfile?

    /// Save a saved place
    func savePlace(_ place: SavedPlace) async throws

    /// Load all saved places
    func loadPlaces() async throws -> [SavedPlace]

    /// Delete a saved place
    func deletePlace(id: UUID) async throws

    /// Save ride screen customization
    func saveRideCustomization(_ customization: RideScreenCustomization) async throws

    /// Load ride screen customization
    func loadRideCustomization() async throws -> RideScreenCustomization

    /// Save route settings
    func saveRoutePreferences(_ preferences: RoutePreferenceProfile) async throws

    /// Load route settings
    func loadRoutePreferences() async throws -> RoutePreferenceProfile?

    /// Record a destination search (most recent first, capped)
    func recordRecentDestination(_ destination: RecentDestination) async throws

    /// Load recent destinations, most recent first
    func loadRecentDestinations() async throws -> [RecentDestination]

    /// Persist whether onboarding has been completed
    func saveOnboardingComplete(_ complete: Bool) async

    /// Whether onboarding has been completed
    func loadOnboardingComplete() async -> Bool
}

// MARK: - Persistence Service (UserDefaults-based)

actor PersistenceService: PersistenceServiceProtocol {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let profile = "laneLine_riderProfile"
        static let places = "laneLine_savedPlaces"
        static let customization = "laneLine_rideCustomization"
        static let routePreferences = "laneLine_routePreferences"
        static let recentDestinations = "laneLine_recentDestinations"
        static let onboardingComplete = "laneLine_onboardingComplete"
    }

    private let maxRecentDestinations = 12

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func saveProfile(_ profile: RiderProfile) async throws {
        let data = try encoder.encode(profile)
        defaults.set(data, forKey: Keys.profile)
    }

    func loadProfile() async throws -> RiderProfile? {
        guard let data = defaults.data(forKey: Keys.profile) else { return nil }
        return try decoder.decode(RiderProfile.self, from: data)
    }

    func savePlace(_ place: SavedPlace) async throws {
        var places = try await loadPlaces()
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index] = place
        } else {
            places.append(place)
        }
        let data = try encoder.encode(places)
        defaults.set(data, forKey: Keys.places)
    }

    func loadPlaces() async throws -> [SavedPlace] {
        guard let data = defaults.data(forKey: Keys.places) else { return [] }
        return try decoder.decode([SavedPlace].self, from: data)
    }

    func deletePlace(id: UUID) async throws {
        var places = try await loadPlaces()
        places.removeAll { $0.id == id }
        let data = try encoder.encode(places)
        defaults.set(data, forKey: Keys.places)
    }

    func saveRideCustomization(_ customization: RideScreenCustomization) async throws {
        let data = try encoder.encode(customization)
        defaults.set(data, forKey: Keys.customization)
    }

    func loadRideCustomization() async throws -> RideScreenCustomization {
        guard let data = defaults.data(forKey: Keys.customization) else {
            return .default
        }
        return (try? decoder.decode(RideScreenCustomization.self, from: data)) ?? .default
    }

    func saveRoutePreferences(_ preferences: RoutePreferenceProfile) async throws {
        let data = try encoder.encode(preferences)
        defaults.set(data, forKey: Keys.routePreferences)
    }

    func loadRoutePreferences() async throws -> RoutePreferenceProfile? {
        guard let data = defaults.data(forKey: Keys.routePreferences) else { return nil }
        return try decoder.decode(RoutePreferenceProfile.self, from: data)
    }

    func recordRecentDestination(_ destination: RecentDestination) async throws {
        var recents = try await loadRecentDestinations()
        // Same place searched again just moves to the top.
        recents.removeAll {
            $0.name == destination.name && abs($0.latitude - destination.latitude) < 1e-6
        }
        recents.insert(destination, at: 0)
        recents = Array(recents.prefix(maxRecentDestinations))
        let data = try encoder.encode(recents)
        defaults.set(data, forKey: Keys.recentDestinations)
    }

    func loadRecentDestinations() async throws -> [RecentDestination] {
        guard let data = defaults.data(forKey: Keys.recentDestinations) else { return [] }
        return try decoder.decode([RecentDestination].self, from: data)
    }

    func saveOnboardingComplete(_ complete: Bool) async {
        defaults.set(complete, forKey: Keys.onboardingComplete)
    }

    func loadOnboardingComplete() async -> Bool {
        defaults.bool(forKey: Keys.onboardingComplete)
    }
}
