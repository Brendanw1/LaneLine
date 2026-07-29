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
        edges = try container.decode([Edge].self, forKey: .edges)
        rebuildAdjacency()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodes, forKey: .nodes)
        try container.encode(edges, forKey: .edges)
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
