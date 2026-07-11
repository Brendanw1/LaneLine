import Foundation
import Observation

/// App-level state: the rider's profile, preferences, saved data, and which
/// top-level surface is showing. Persists through `PersistenceService` on
/// every mutation so state survives relaunch.
@MainActor
@Observable
final class AppModel {
    var riderProfile = RiderProfile()
    var rideCustomization = RideScreenCustomization.default
    var savedPlaces: [SavedPlace] = []
    var recentDestinations: [RecentDestination] = []
    var onboardingComplete = false
    var isLoaded = false

    /// Non-nil while a ride is active; drives the full-screen ride cover.
    var activeRoute: RouteCandidate?

    private let persistence: any PersistenceServiceProtocol

    init(persistence: any PersistenceServiceProtocol) {
        self.persistence = persistence
    }

    // MARK: Lifecycle

    func load() async {
        onboardingComplete = await persistence.loadOnboardingComplete()
        if let profile = try? await persistence.loadProfile() {
            riderProfile = profile
        }
        if let customization = try? await persistence.loadRideCustomization() {
            rideCustomization = customization
        }
        savedPlaces = (try? await persistence.loadPlaces()) ?? []
        recentDestinations = (try? await persistence.loadRecentDestinations()) ?? []
        isLoaded = true
    }

    // MARK: Mutations (persist-through)

    func updateProfile(_ profile: RiderProfile) {
        riderProfile = profile
        Task { try? await persistence.saveProfile(profile) }
    }

    func updateCustomization(_ customization: RideScreenCustomization) {
        rideCustomization = customization
        Task { try? await persistence.saveRideCustomization(customization) }
    }

    func completeOnboarding() {
        onboardingComplete = true
        Task {
            await persistence.saveOnboardingComplete(true)
            try? await persistence.saveProfile(riderProfile)
        }
    }

    func savePlace(_ place: SavedPlace) {
        if let index = savedPlaces.firstIndex(where: { $0.id == place.id }) {
            savedPlaces[index] = place
        } else {
            savedPlaces.append(place)
        }
        Task { try? await persistence.savePlace(place) }
    }

    func deletePlace(_ place: SavedPlace) {
        savedPlaces.removeAll { $0.id == place.id }
        Task { try? await persistence.deletePlace(id: place.id) }
    }

    func recordRecentDestination(_ destination: RecentDestination) {
        recentDestinations.removeAll {
            $0.name == destination.name && abs($0.latitude - destination.latitude) < 1e-6
        }
        recentDestinations.insert(destination, at: 0)
        recentDestinations = Array(recentDestinations.prefix(12))
        Task { try? await persistence.recordRecentDestination(destination) }
    }

    // MARK: Ride lifecycle

    func startRide(_ route: RouteCandidate) {
        activeRoute = route
    }

    func endRide() {
        activeRoute = nil
    }
}
