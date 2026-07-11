import Foundation
import SwiftUI

/// Composition root. Builds the service graph once at launch; previews and
/// tests substitute mocks through the initializer. Views reach services via
/// the `\.services` environment key — observable services still drive SwiftUI
/// updates because views access their `@Observable` properties directly.
@MainActor
final class ServiceContainer {
    let geospatialService: any GeospatialDataServiceProtocol
    let routingService: any RoutingServiceProtocol
    let scoringService: any RouteScoringServiceProtocol
    let locationService: any LocationServicing
    let musicService: any MusicServicing
    let persistenceService: any PersistenceServiceProtocol

    init(
        geospatialService: (any GeospatialDataServiceProtocol)? = nil,
        routingService: (any RoutingServiceProtocol)? = nil,
        scoringService: any RouteScoringServiceProtocol = RouteScoringService(),
        locationService: (any LocationServicing)? = nil,
        musicService: (any MusicServicing)? = nil,
        persistenceService: any PersistenceServiceProtocol = PersistenceService()
    ) {
        let geospatial = geospatialService ?? GeospatialDataService()
        self.geospatialService = geospatial
        self.routingService = routingService
            ?? RoutingService(geospatialService: geospatial, scoringService: scoringService)
        self.scoringService = scoringService
        self.locationService = locationService ?? LocationService()
        self.musicService = musicService ?? AppleMusicService()
        self.persistenceService = persistenceService
    }

    static func live() -> ServiceContainer {
        ServiceContainer()
    }

    /// Mocked location + music, real routing over the bundled sample network.
    static func preview() -> ServiceContainer {
        ServiceContainer(
            locationService: MockLocationService(),
            musicService: MockMusicService()
        )
    }
}

// MARK: - Environment plumbing

private struct ServiceContainerKey: EnvironmentKey {
    static let defaultValue: ServiceContainer? = nil
}

extension EnvironmentValues {
    /// Writable storage stays private; injection goes through it directly.
    fileprivate var serviceContainerStorage: ServiceContainer? {
        get { self[ServiceContainerKey.self] }
        set { self[ServiceContainerKey.self] = newValue }
    }

    /// Get-only on purpose: keypath mutation (`environment(_:_:)`) runs the
    /// getter before the setter, so a trapping getter must never share a
    /// keypath with injection. Failing loudly here beats previews silently
    /// running against nothing.
    var services: ServiceContainer {
        guard let container = serviceContainerStorage else {
            fatalError("ServiceContainer missing — inject with .serviceContainer(_:)")
        }
        return container
    }
}

extension View {
    func serviceContainer(_ container: ServiceContainer) -> some View {
        environment(\.serviceContainerStorage, container)
    }
}
