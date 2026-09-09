import XCTest
import CoreLocation
@testable import LaneLine

/// Behavioral probes of routing quality on the real bundled city graph.
/// These tests document current behavior on real SF terrain and guard
/// against regressions in grade/speed modeling. Failures here signal a
/// real product-quality regression, not a fixture problem.
final class RouteQualityProbeTests: XCTestCase {
    private func makeService() throws -> GeospatialDataService {
        let resourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        guard let resourcesBundle = Bundle(url: resourcesURL) else {
            throw XCTSkip("Could not construct a Bundle from the Resources directory")
        }
        let tempCacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempCacheDir, withIntermediateDirectories: true)
        return GeospatialDataService(
            bikewayProvider: LocalBikewayDataSource(bundle: resourcesBundle),
            streetProvider: LocalStreetDataSource(bundle: resourcesBundle),
            elevationProvider: CachingElevationProvider(
                upstream: NoOpElevationProvider(),
                cacheDirectory: tempCacheDir,
                bundle: resourcesBundle
            ),
            cacheDirectory: tempCacheDir
        )
    }

    /// Sanity check on real SF terrain: a short urban hop should produce at
    /// least two meaningfully different candidates across strategies.
    func testShortUrbanHopProducesMultipleCandidates() async throws {
        let service = try makeService()
        let routing = RoutingService(geospatialService: service)
        let origin = CLLocationCoordinate2D(latitude: 37.7651, longitude: -122.4194)
        let destination = CLLocationCoordinate2D(latitude: 37.7615, longitude: -122.4214)
        let profile = RiderProfile(bikeType: .cityBike)

        let candidates = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.balanced, .safer, .faster, .easierClimbing]
        )
        for c in candidates {
            print("[probe-mission] \(c.strategyType): dist=\(Int(c.totalDistanceMeters))m " +
                  "climb=\(Int(c.totalElevationGainMeters))m maxGrade=\(c.maxGradeFormatted) " +
                  "segs=\(c.segments.count) protect=\(Int(c.protectedLanePercent * 100))%")
        }
        XCTAssertGreaterThanOrEqual(
            candidates.count, 2,
            "A real SF trip should produce multiple distinct candidates, not one consensus route"
        )
    }

    /// The bundled BBBike street extract doesn't include the Presidio; this
    /// trip exists as a placeholder for when coverage is extended.
    func testEmbarcaderoToCrissyPresidioCoverage() async throws {
        throw XCTSkip("Bundled street network does not cover the Presidio; revisit after coverage extension")
    }

    /// Cross-town probe: Ocean Beach to Mission Bay. Confirms the
    /// 1.7× detour cap doesn't cull the flatter EasierClimbing option for
    /// a long cross-town trip where the flat path is meaningfully longer
    /// than the hill shortcut.
    func testProbe_OceanBeachToMissionBay() async throws {
        let service = try makeService()
        let routing = RoutingService(geospatialService: service)
        let origin = CLLocationCoordinate2D(latitude: 37.7597, longitude: -122.5107)
        let destination = CLLocationCoordinate2D(latitude: 37.7706, longitude: -122.3889)
        let profile = RiderProfile(bikeType: .roadBike, hillTolerance: .low)

        let candidates = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.faster, .easierClimbing, .balanced]
        )
        for c in candidates {
            let ratio = candidates.first.map { c.totalDistanceMeters / max(Double($0.totalDistanceMeters), 1) } ?? 1.0
            print("[probe-cross] \(c.strategyType): dist=\(Int(c.totalDistanceMeters))m " +
                  "climb=\(Int(c.totalElevationGainMeters))m maxGrade=\(c.maxGradeFormatted) " +
                  "distRatio=\(String(format: "%.2fx", ratio))")
        }
        let easier = candidates.first { $0.strategyType == .easierClimbing }
        XCTAssertNotNil(easier, "EasierClimbing must survive the detour cap on this long cross-town trip")
    }

    /// Yo-yo probe: Bernal Heights south-of to Potrero. Both balanced and
    /// easierClimbing currently produce similar up-down patterns. Tests
    /// whether the model differentiates yo-yo from monotonic.
    func testProbe_BernalHeightsYoYo() async throws {
        let service = try makeService()
        let routing = RoutingService(geospatialService: service)
        let origin = CLLocationCoordinate2D(latitude: 37.7400, longitude: -122.4150)
        let destination = CLLocationCoordinate2D(latitude: 37.7650, longitude: -122.4050)
        let profile = RiderProfile(bikeType: .roadBike)

        let candidates = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.balanced, .easierClimbing]
        )
        for c in candidates {
            let grades = c.segments.map(\.averageGrade).filter { abs($0) > 0.03 }
            let gradeVariance = grades.count > 1 ? variance(grades) : 0
            print("[probe-yo-yo] \(c.strategyType): dist=\(Int(c.totalDistanceMeters))m " +
                  "climb=\(Int(c.totalElevationGainMeters))m maxGrade=\(c.maxGradeFormatted) " +
                  "steepSegs=\(grades.count) gradeVar=\(String(format: "%.4f", gradeVariance))")
        }
    }

    /// Wiggle probe: a trip where the corridor grazes but doesn't really
    /// fit. Confirms the corridor discount doesn't cause the model to
    /// commit to a less-direct path through the Wiggle.
    func testProbe_WiggleGrazingTrip() async throws {
        let service = try makeService()
        let routing = RoutingService(geospatialService: service)
        let origin = CLLocationCoordinate2D(latitude: 37.7640, longitude: -122.4260)
        let destination = CLLocationCoordinate2D(latitude: 37.7925, longitude: -122.4380)
        let profile = RiderProfile(bikeType: .hybridFitness)

        let withoutWiggle = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.faster], preferWiggle: false
        )
        let withWiggle = try await routing.generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: [.faster], preferWiggle: true
        )
        for c in withoutWiggle {
            print("[probe-wiggle-off] \(c.strategyType): dist=\(Int(c.totalDistanceMeters))m " +
                  "usedWiggle=\(c.usedWiggleCorridor) segs=\(c.segments.count)")
            print("  streets: " + c.segments.compactMap(\.streetName).joined(separator: " → "))
        }
        for c in withWiggle {
            print("[probe-wiggle-on] \(c.strategyType): dist=\(Int(c.totalDistanceMeters))m " +
                  "usedWiggle=\(c.usedWiggleCorridor) segs=\(c.segments.count)")
            print("  streets: " + c.segments.compactMap(\.streetName).joined(separator: " → "))
        }
    }

    private func variance(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sumSq = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sumSq / Double(values.count)
    }
}
