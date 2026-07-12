import Foundation
import CoreLocation

/// Source-agnostic intermediate for one directed-or-two-way street stretch.
/// Every ingestion source (DataSF, Overpass, the bundled sample network)
/// normalizes into this before graph construction, so the fusion, elevation,
/// stress, and confidence logic runs identically for all of them.
struct RawNetworkEdge {
    var geometry: [RouteCoordinate]
    var streetName: String?
    var facilityType: BikeFacilityType = .unknown
    var protectionLevel: ProtectionLevel = .unknown
    var roadClass: RoadClass = .unknown
    var surfaceType: SurfaceType = .unknown
    var oneWay = false
    var speedLimitKmh: Double?
    var laneCount: Int?
    /// Set by the sample network, which bakes in curated stress values.
    var stressOverride: Double?
    /// How complete the source attribution is, before graph-level adjustments.
    var attributeConfidence: Double = 0.5
}

/// Fuses bikeway, street-attribute, and elevation inputs into a routable
/// `RouteGraph`:
///
/// 1. OSM ways provide full street coverage (geometry, road class, surface,
///    one-way rules).
/// 2. DataSF bikeway segments are spatially matched onto them (midpoint
///    proximity) to attach official facility class and protection level.
/// 3. Polylines are split into micro-edges between consecutive vertices and
///    endpoints are snapped to a ~6 m grid, which welds intersections shared
///    across sources into single nodes.
/// 4. Each unique node is enriched with elevation; per-edge signed grades
///    follow from node elevations.
struct NetworkGraphBuilder {
    /// Snap tolerance in degrees (~5.5 m of latitude). Vertices closer than
    /// this become one node.
    var snapPrecision: Double = 5e-5
    /// Max midpoint distance for matching a DataSF bikeway onto an OSM edge.
    var bikewayMatchToleranceMeters: Double = 25

    // MARK: Source normalization

    func rawEdges(
        from streets: [OverpassElement],
        enrichedBy bikeways: BikewayNetwork
    ) -> [RawNetworkEdge] {
        let bikewayIndex = SpatialIndex(bikeways.segments)

        return streets.compactMap { way -> RawNetworkEdge? in
            let coordinates = way.routeCoordinates
            guard coordinates.count >= 2 else { return nil }
            let attributes = way.streetAttribute

            var edge = RawNetworkEdge(
                geometry: coordinates,
                streetName: way.tags?["name"],
                roadClass: attributes.roadClass,
                surfaceType: attributes.surfaceType,
                oneWay: attributes.isOneWay,
                speedLimitKmh: attributes.speedLimitKmh,
                laneCount: attributes.laneCount
            )

            if let match = bikewayIndex.nearestSegment(
                toMidpointOf: coordinates,
                within: bikewayMatchToleranceMeters
            ) {
                // Official SFMTA facility data wins over OSM tags.
                edge.facilityType = match.facilityType
                edge.protectionLevel = match.protectionLevel
                edge.streetName = edge.streetName ?? match.streetName
                edge.attributeConfidence = 0.95
            } else if attributes.hasBikeInfrastructure {
                edge.facilityType = .bikeLane
                edge.protectionLevel = .standard
                edge.attributeConfidence = 0.8
            } else if way.tags?["highway"] == "cycleway" {
                edge.facilityType = .offStreetPath
                edge.protectionLevel = .fullyProtected
                edge.attributeConfidence = 0.85
            } else {
                edge.facilityType = .mixedTraffic
                edge.protectionLevel = ProtectionLevel.none
                edge.attributeConfidence = attributes.surfaceType == .unknown ? 0.6 : 0.75
            }
            return edge
        }
    }

    /// Fallback path when only the bikeway network is available (no OSM
    /// coverage): route over official bikeways alone.
    func rawEdges(fromBikewaysOnly bikeways: BikewayNetwork) -> [RawNetworkEdge] {
        bikeways.segments.compactMap { segment in
            guard segment.geometry.count >= 2 else { return nil }
            return RawNetworkEdge(
                geometry: segment.geometry,
                streetName: segment.streetName,
                facilityType: segment.facilityType,
                protectionLevel: segment.protectionLevel,
                roadClass: segment.facilityType == .offStreetPath ? .residential : .unknown,
                surfaceType: segment.facilityType == .offStreetPath ? .paved : .unknown,
                oneWay: segment.oneWay,
                attributeConfidence: 0.7
            )
        }
    }

    // MARK: Graph construction

    func buildGraph(
        from rawEdges: [RawNetworkEdge],
        elevationProvider: (any ElevationProviding)?
    ) async throws -> RouteGraph {
        var nodeIDsByKey: [String: Int] = [:]
        var nodes: [RouteGraph.Node] = []
        var elevations: [Int: Double] = [:]

        func nodeID(for coordinate: RouteCoordinate) -> Int {
            let key = snapKey(coordinate)
            if let existing = nodeIDsByKey[key] { return existing }
            let id = nodes.count
            nodeIDsByKey[key] = id
            nodes.append(RouteGraph.Node(id: id, coordinate: coordinate))
            if let elevation = coordinate.elevation { elevations[id] = elevation }
            return id
        }

        // Micro-edges between consecutive polyline vertices. OSM and DataSF
        // geometries include intersection vertices, so snapping these
        // endpoints is what makes cross-street connectivity work.
        struct MicroEdge {
            let from: Int
            let to: Int
            let geometry: [RouteCoordinate]
            let raw: RawNetworkEdge
        }

        var microEdges: [MicroEdge] = []
        for raw in rawEdges {
            for (a, b) in zip(raw.geometry, raw.geometry.dropFirst()) {
                let fromID = nodeID(for: a)
                let toID = nodeID(for: b)
                guard fromID != toID else { continue }
                microEdges.append(MicroEdge(from: fromID, to: toID, geometry: [a, b], raw: raw))
            }
        }

        // Elevation enrichment per unique node, in one batch: city-scale
        // graphs have tens of thousands of nodes, so per-point queries are
        // not viable on a phone. Sample-network nodes arrive with elevations
        // baked in and skip the lookup entirely.
        if let elevationProvider {
            let pending = nodes.filter { elevations[$0.id] == nil }
            if !pending.isEmpty {
                let fetched = try await elevationProvider
                    .elevationsMeters(at: pending.map(\.coordinate.clCoordinate))
                for (node, elevation) in zip(pending, fetched) {
                    if let elevation { elevations[node.id] = elevation }
                }
            }
        }

        let enrichedNodes = nodes.map { node in
            RouteGraph.Node(
                id: node.id,
                coordinate: RouteCoordinate(
                    latitude: node.coordinate.latitude,
                    longitude: node.coordinate.longitude,
                    elevation: elevations[node.id]
                )
            )
        }

        var edges: [RouteGraph.Edge] = []
        for micro in microEdges {
            let length = GeoMath.polylineLengthMeters(micro.geometry)
            guard length > 0.5 else { continue }

            let grade = signedGrade(
                from: elevations[micro.from],
                to: elevations[micro.to],
                lengthMeters: length
            )

            appendDirectedEdge(
                &edges, from: micro.from, to: micro.to,
                geometry: micro.geometry, length: length, grade: grade, raw: micro.raw
            )
            if !micro.raw.oneWay {
                appendDirectedEdge(
                    &edges, from: micro.to, to: micro.from,
                    geometry: micro.geometry.reversed(), length: length, grade: -grade, raw: micro.raw
                )
            }
        }

        return RouteGraph(nodes: enrichedNodes, edges: edges)
    }

    // MARK: Helpers

    private func appendDirectedEdge(
        _ edges: inout [RouteGraph.Edge],
        from: Int, to: Int,
        geometry: [RouteCoordinate],
        length: Double,
        grade: Double,
        raw: RawNetworkEdge
    ) {
        let stress = raw.stressOverride ?? StressModel.segmentStress(
            roadClass: raw.roadClass,
            facilityType: raw.facilityType,
            protectionLevel: raw.protectionLevel,
            speedLimitKmh: raw.speedLimitKmh,
            laneCount: raw.laneCount
        )

        edges.append(RouteGraph.Edge(
            id: edges.count,
            from: from,
            to: to,
            lengthMeters: length,
            grade: grade,
            estimatedSeconds: CyclingSpeedModel.neutralTraversalSeconds(
                lengthMeters: length, grade: grade
            ),
            facilityType: raw.facilityType,
            protectionLevel: raw.protectionLevel,
            roadClass: raw.roadClass,
            surfaceType: raw.surfaceType,
            stressScore: stress,
            confidenceScore: confidence(for: raw, hasGrade: grade != 0 || length < 30),
            streetName: raw.streetName,
            geometry: geometry
        ))
    }

    private func signedGrade(from: Double?, to: Double?, lengthMeters: Double) -> Double {
        guard let from, let to, lengthMeters > 0 else { return 0 }
        // Clamp: block-level grades beyond ±25% are data errors, not streets.
        return min(0.25, max(-0.25, (to - from) / lengthMeters))
    }

    private func confidence(for raw: RawNetworkEdge, hasGrade: Bool) -> Double {
        var confidence = raw.attributeConfidence
        if raw.surfaceType == .unknown { confidence -= 0.1 }
        if !hasGrade { confidence -= 0.1 }
        return min(1, max(0.2, confidence))
    }

    private func snapKey(_ coordinate: RouteCoordinate) -> String {
        let lat = (coordinate.latitude / snapPrecision).rounded()
        let lon = (coordinate.longitude / snapPrecision).rounded()
        return "\(Int(lat)):\(Int(lon))"
    }
}

/// Midpoint grid index for matching DataSF bikeway segments onto OSM edges.
private struct SpatialIndex {
    private let cellSizeDegrees = 3e-4 // ~33 m
    private var cells: [String: [BikewaySegment]] = [:]

    init(_ segments: [BikewaySegment]) {
        for segment in segments {
            guard let midpoint = Self.midpoint(of: segment.geometry) else { continue }
            cells[key(for: midpoint), default: []].append(segment)
        }
    }

    func nearestSegment(
        toMidpointOf geometry: [RouteCoordinate],
        within toleranceMeters: Double
    ) -> BikewaySegment? {
        guard let midpoint = Self.midpoint(of: geometry) else { return nil }

        var best: (BikewaySegment, Double)?
        for neighborKey in neighborKeys(for: midpoint) {
            for candidate in cells[neighborKey] ?? [] {
                guard let candidateMid = Self.midpoint(of: candidate.geometry) else { continue }
                let distance = GeoMath.distanceMeters(from: midpoint, to: candidateMid)
                if distance <= toleranceMeters, distance < (best?.1 ?? .infinity) {
                    best = (candidate, distance)
                }
            }
        }
        return best?.0
    }

    private static func midpoint(of geometry: [RouteCoordinate]) -> RouteCoordinate? {
        guard !geometry.isEmpty else { return nil }
        return geometry[geometry.count / 2]
    }

    private func key(for coordinate: RouteCoordinate) -> String {
        cellKey(
            Int((coordinate.latitude / cellSizeDegrees).rounded()),
            Int((coordinate.longitude / cellSizeDegrees).rounded())
        )
    }

    private func neighborKeys(for coordinate: RouteCoordinate) -> [String] {
        let latCell = Int((coordinate.latitude / cellSizeDegrees).rounded())
        let lonCell = Int((coordinate.longitude / cellSizeDegrees).rounded())
        var keys: [String] = []
        for dLat in -1...1 {
            for dLon in -1...1 {
                keys.append(cellKey(latCell + dLat, lonCell + dLon))
            }
        }
        return keys
    }

    private func cellKey(_ lat: Int, _ lon: Int) -> String { "\(lat):\(lon)" }
}
