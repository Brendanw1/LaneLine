import Foundation
import CoreLocation

/// The routable street network: a weighted directed graph produced by
/// `NetworkGraphBuilder`. Two-way streets are represented as two directed
/// edges with mirrored grades and reversed geometry.
///
/// Edges carry raw physical/infrastructure attributes only. Rider- and
/// strategy-specific costs are computed at query time by `RoutingCostModel`,
/// so one graph serves every bike type and preference profile.
struct RouteGraph: Codable {
    struct Node: Identifiable, Codable, Equatable {
        let id: Int
        /// Includes elevation (meters) when the elevation provider resolved it.
        let coordinate: RouteCoordinate
    }

    struct Edge: Identifiable, Codable, Equatable {
        let id: Int
        let from: Int
        let to: Int
        let lengthMeters: Double
        /// Signed decimal grade in travel direction (0.06 = 6% climb).
        let grade: Double
        /// Neutral-rider traversal estimate; per-rider ETAs are recomputed
        /// by `RouteMetricsCalculator` using the rider's bike type.
        let estimatedSeconds: Double
        let facilityType: BikeFacilityType
        let protectionLevel: ProtectionLevel
        let roadClass: RoadClass
        let surfaceType: SurfaceType
        /// 0...1 traffic-stress proxy (see `StressModel`).
        let stressScore: Double
        /// 0...1 attribute completeness from the ingestion sources.
        let confidenceScore: Double
        let streetName: String?
        let geometry: [RouteCoordinate]
        /// Whether this edge is part of San Francisco's real "Wiggle"
        /// corridor. See `WiggleCorridor`.
        let isWiggleCorridor: Bool
        /// 0...1 grade-variance proxy: how much the surrounding grades
        /// differ from a flat reference, computed at graph build time from
        /// a sliding window of nearby edges. A monotonic climb on flat
        /// terrain scores near 0; a yo-yo (climb-descent-climb pattern)
        /// scores high. Used by `RoutingCostModel` to penalize routes
        /// that flip direction more than the terrain requires, distinct
        /// from peak grade which only catches the worst single edge.
        let smoothnessPenalty: Double

        var elevationGainMeters: Double { max(0, grade * lengthMeters) }
    }

    let nodes: [Node]
    let edges: [Edge]

    /// node id -> outgoing edge ids. Rebuilt on decode; not serialized.
    private var adjacency: [[Int]] = []

    init(nodes: [Node], edges: [Edge]) {
        self.nodes = nodes
        self.edges = edges
        rebuildAdjacency()
    }

    enum CodingKeys: String, CodingKey {
        case nodes, edges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nodes = try container.decode([Node].self, forKey: .nodes)
        // Custom decode for edges so a graph persisted before
        // `smoothnessPenalty` existed on `Edge` still loads — the field
        // defaults to 0 (no penalty), and the next live ingestion or
        // `Fetch live SF bike network` rebuilds with real values.
        edges = try Self.decodeEdges(from: container, forKey: .edges)
        rebuildAdjacency()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
    }

    /// Decode edges with a backward-compatible default for the
    /// `smoothnessPenalty` field. Older on-disk caches don't have it;
    /// treat that as 0 (no penalty) and let the next graph rebuild
    /// populate it for real.
    private static func decodeEdges(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> [Edge] {
        // Decode into a generic shape, fill in the default for missing
        // smoothnessPenalty, then return as [Edge].
        struct RawEdge: Decodable {
            let id: Int
            let from: Int
            let to: Int
            let lengthMeters: Double
            let grade: Double
            let estimatedSeconds: Double
            let facilityType: BikeFacilityType
            let protectionLevel: ProtectionLevel
            let roadClass: RoadClass
            let surfaceType: SurfaceType
            let stressScore: Double
            let confidenceScore: Double
            let streetName: String?
            let geometry: [RouteCoordinate]
            let isWiggleCorridor: Bool
            let smoothnessPenalty: Double?
        }
        let raws = try container.decode([RawEdge].self, forKey: key)
        return raws.map { raw in
            Edge(
                id: raw.id, from: raw.from, to: raw.to,
                lengthMeters: raw.lengthMeters, grade: raw.grade,
                estimatedSeconds: raw.estimatedSeconds,
                facilityType: raw.facilityType, protectionLevel: raw.protectionLevel,
                roadClass: raw.roadClass, surfaceType: raw.surfaceType,
                stressScore: raw.stressScore, confidenceScore: raw.confidenceScore,
                streetName: raw.streetName, geometry: raw.geometry,
                isWiggleCorridor: raw.isWiggleCorridor,
                smoothnessPenalty: raw.smoothnessPenalty ?? 0
            )
        }
    }

    private mutating func rebuildAdjacency() {
        var lists = [[Int]](repeating: [], count: nodes.count)
        for edge in edges where edge.from < lists.count {
            lists[edge.from].append(edge.id)
        }
        adjacency = lists
    }

    var isEmpty: Bool { nodes.isEmpty || edges.isEmpty }

    func node(_ id: Int) -> Node? {
        guard nodes.indices.contains(id) else { return nil }
        return nodes[id]
    }

    func outgoingEdges(from nodeID: Int) -> [Edge] {
        guard adjacency.indices.contains(nodeID) else { return [] }
        return adjacency[nodeID].map { edges[$0] }
    }

    /// Nearest graph node to an arbitrary coordinate (route endpoints are
    /// snapped onto the network here). Linear scan is fine at the v1 network
    /// sizes we route over; swap in a grid index before city-scale graphs.
    func nearestNode(to coordinate: CLLocationCoordinate2D) -> Node? {
        nodes.min(by: {
            GeoMath.distanceMeters(from: $0.coordinate.clCoordinate, to: coordinate)
                < GeoMath.distanceMeters(from: $1.coordinate.clCoordinate, to: coordinate)
        })
    }

    static let empty = RouteGraph(nodes: [], edges: [])
}
