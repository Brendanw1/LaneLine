import Foundation
import CoreLocation
@testable import LaneLine

// Shared fixtures for routing tests. Synthetic graphs are built through the
// real NetworkGraphBuilder so tests exercise the production pipeline.

struct StubGeospatialService: GeospatialDataServiceProtocol {
    let graph: RouteGraph

    func routeGraph(covering bounds: BoundingBox) async throws -> RouteGraph { graph }
    func ingestLiveNetwork(
        in bounds: BoundingBox,
        onProgress: @escaping @Sendable (NetworkIngestionPhase) -> Void = { _ in }
    ) async throws -> RouteGraph { graph }
    var currentSource: NetworkSource {
        get async { .bundledSample }
    }
}

enum TestGraphs {
    static func coordinate(_ lat: Double, _ lon: Double, _ elevation: Double) -> RouteCoordinate {
        RouteCoordinate(latitude: lat, longitude: lon, elevation: elevation)
    }

    static func rawEdge(
        from: RouteCoordinate,
        to: RouteCoordinate,
        street: String,
        facility: BikeFacilityType = .mixedTraffic,
        protection: ProtectionLevel = .none,
        roadClass: RoadClass = .residential,
        surface: SurfaceType = .asphalt,
        oneWay: Bool = false
    ) -> RawNetworkEdge {
        RawNetworkEdge(
            geometry: [from, to],
            streetName: street,
            facilityType: facility,
            protectionLevel: protection,
            roadClass: roadClass,
            surfaceType: surface,
            oneWay: oneWay,
            attributeConfidence: 0.9
        )
    }

    static func build(_ edges: [RawNetworkEdge]) async throws -> RouteGraph {
        try await NetworkGraphBuilder().buildGraph(from: edges, elevationProvider: nil)
    }

    // MARK: Stress-tradeoff graph
    // Direct flat arterial (O→D, ~1.8 km) vs calm protected detour via N
    // (~2.3 km, ×1.30). Both flat: the only tradeoff is traffic stress.

    static let stressOrigin = CLLocationCoordinate2D(latitude: 37.7600, longitude: -122.4200)
    static let stressDestination = CLLocationCoordinate2D(latitude: 37.7600, longitude: -122.4000)

    static func stressTradeoffGraph() async throws -> RouteGraph {
        let o = coordinate(37.7600, -122.4200, 10)
        let d = coordinate(37.7600, -122.4000, 10)
        let n = coordinate(37.7665, -122.4100, 10)
        return try await build([
            rawEdge(from: o, to: d, street: "Direct St", roadClass: .arterial),
            rawEdge(
                from: o, to: n, street: "Calm Way",
                facility: .protectedBikeLane, protection: .fullyProtected
            ),
            rawEdge(
                from: n, to: d, street: "Calm Way",
                facility: .protectedBikeLane, protection: .fullyProtected
            ),
        ])
    }

    // MARK: Hill-tradeoff graph
    // Steep shortcut over a 45 m hill (grades ~±10%) vs a flat detour ~60%
    // longer. Road bikes should detour; e-bikes should take the hill.

    static let hillOrigin = CLLocationCoordinate2D(latitude: 37.7700, longitude: -122.4200)
    static let hillDestination = CLLocationCoordinate2D(latitude: 37.7700, longitude: -122.4120)

    static func hillTradeoffGraph() async throws -> RouteGraph {
        let o = coordinate(37.7700, -122.4200, 10)
        let d = coordinate(37.7700, -122.4120, 10)
        let hilltop = coordinate(37.7700, -122.4160, 45)
        let flatApex = coordinate(37.7740, -122.4160, 10)
        return try await build([
            rawEdge(from: o, to: hilltop, street: "Hill St", facility: .sharedLane, protection: .sharrows),
            rawEdge(from: hilltop, to: d, street: "Hill St", facility: .sharedLane, protection: .sharrows),
            rawEdge(from: o, to: flatApex, street: "Flat Ave", facility: .bikeLane, protection: .standard),
            rawEdge(from: flatApex, to: d, street: "Flat Ave", facility: .bikeLane, protection: .standard),
        ])
    }

    // MARK: One-way graph
    // A→B is one-way; the only legal B→A path loops through C.

    static let oneWayA = CLLocationCoordinate2D(latitude: 37.7800, longitude: -122.4200)
    static let oneWayB = CLLocationCoordinate2D(latitude: 37.7800, longitude: -122.4150)

    static func oneWayGraph() async throws -> RouteGraph {
        let a = coordinate(37.7800, -122.4200, 10)
        let b = coordinate(37.7800, -122.4150, 10)
        let c = coordinate(37.7830, -122.4175, 10)
        return try await build([
            rawEdge(from: a, to: b, street: "OneWay St", oneWay: true),
            rawEdge(from: a, to: c, street: "Loop Rd"),
            rawEdge(from: c, to: b, street: "Loop Rd"),
        ])
    }
}

extension RouteCandidate {
    var streetNames: Set<String> {
        Set(segments.compactMap(\.streetName))
    }
}

extension RiderProfile {
    static func testProfile(bikeType: BikeType) -> RiderProfile {
        RiderProfile(
            name: "Test",
            bikeType: bikeType,
            hillTolerance: .moderate,
            safetyPreference: .moderate,
            directnessPreference: .balanced,
            surfaceSensitivity: .moderate
        )
    }
}
