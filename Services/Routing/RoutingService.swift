import Foundation
import CoreLocation

/// Graph-based route planner. For each strategy it resolves a rider- and
/// strategy-specific cost model, runs A* over the ingested street graph, and
/// assembles explainable candidates. Nothing here is hardcoded to any
/// particular route — outputs change whenever the underlying data does.
actor RoutingService: RoutingServiceProtocol {
    private let geospatialService: any GeospatialDataServiceProtocol
    private let scoringService: any RouteScoringServiceProtocol
    private let metricsCalculator = RouteMetricsCalculator()
    private let explanationBuilder = RouteExplanationBuilder()

    /// Endpoints farther than this from any graph node are off-network.
    private let maxSnapDistanceMeters: Double = 800
    /// Candidates sharing more than this fraction of edges are duplicates.
    private let duplicateOverlapThreshold: Double = 0.9
    /// Candidates longer than this multiple of the shortest option are
    /// discarded as unreasonable detours.
    private let maxDetourFactor: Double = 1.7
    /// Cost multiplier on consensus-path edges when searching for an
    /// alternative after all strategies converge (penalty method).
    private let alternativePenaltyFactor: Double = 1.6

    init(
        geospatialService: any GeospatialDataServiceProtocol,
        scoringService: any RouteScoringServiceProtocol = RouteScoringService()
    ) {
        self.geospatialService = geospatialService
        self.scoringService = scoringService
    }

    // MARK: RoutingServiceProtocol

    func generateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: RiderProfile
    ) async throws -> [RouteCandidate] {
        try await generateRoutes(
            from: origin,
            to: destination,
            profile: profile,
            strategies: [.balanced, .safer, .faster, .easierClimbing]
        )
    }

    func generateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: RiderProfile,
        strategies: [RouteStrategyType]
    ) async throws -> [RouteCandidate] {
        try await generateRoutes(
            from: origin, to: destination, profile: profile,
            strategies: strategies, preferWiggle: false
        )
    }

    func generateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        profile: RiderProfile,
        strategies: [RouteStrategyType],
        preferWiggle: Bool
    ) async throws -> [RouteCandidate] {
        let bounds = GeoMath.boundingBox(containing: origin, destination, paddingMeters: 1500)
        let graph = try await geospatialService.routeGraph(covering: bounds)

        guard let start = graph.nearestNode(to: origin),
              GeoMath.distanceMeters(from: start.coordinate.clCoordinate, to: origin)
                <= maxSnapDistanceMeters else {
            throw RoutingError.originOffNetwork
        }
        guard let goal = graph.nearestNode(to: destination),
              GeoMath.distanceMeters(from: goal.coordinate.clCoordinate, to: destination)
                <= maxSnapDistanceMeters else {
            throw RoutingError.destinationOffNetwork
        }

        var paths: [(strategy: RouteStrategyType, edges: [RouteGraph.Edge])] = []
        for strategy in strategies {
            let costModel = RoutingCostModel(profile: profile, strategy: strategy, preferWiggle: preferWiggle)
            if let edges = shortestPath(in: graph, from: start.id, to: goal.id, costModel: costModel),
               !edges.isEmpty {
                paths.append((strategy, edges))
            }
        }
        guard !paths.isEmpty else { throw RoutingError.noPathFound }

        var distinctPaths = deduplicate(paths)

        // When one corridor dominates under every strategy, riders still
        // deserve a real choice: penalize the consensus edges and re-run the
        // remaining strategies to surface a genuinely different alternative.
        if distinctPaths.count == 1, strategies.count > 1,
           let alternative = alternativePath(
               in: graph,
               from: start.id,
               to: goal.id,
               profile: profile,
               strategies: strategies.filter { $0 != distinctPaths[0].strategy },
               avoiding: distinctPaths[0].edges,
               preferWiggle: preferWiggle
           ) {
            distinctPaths.append(alternative)
        }

        var candidates = distinctPaths.map { path in
            metricsCalculator.candidate(
                from: path.edges,
                strategy: path.strategy,
                profile: profile,
                origin: origin,
                destination: destination
            )
        }

        candidates = capDetours(candidates)
        candidates = Array(candidates.prefix(3))
        candidates = explanationBuilder.annotate(candidates, profile: profile)

        for index in candidates.indices {
            candidates[index].scoreBreakdown =
                try await scoreRoute(candidates[index], profile: profile)
        }
        return candidates
    }

    func scoreRoute(
        _ route: RouteCandidate,
        profile: RiderProfile
    ) async throws -> RouteScoreBreakdown {
        let preferences = RoutePreferenceProfile.default(for: profile.bikeType)
        let segmentScores = route.segments.map {
            scoringService.scoreSegment($0, profile: profile, preferences: preferences)
        }
        let directnessRatio = route.directnessScore > 0 ? 1.0 / route.directnessScore : 1.0
        return scoringService.computeRouteScore(
            segments: route.segments,
            segmentScores: segmentScores,
            directnessRatio: directnessRatio
        )
    }

    // MARK: A*

    /// Best distinct path once the consensus corridor is made expensive.
    /// Tries each remaining strategy so the alternative keeps an honest
    /// strategy label with metrics to match.
    private func alternativePath(
        in graph: RouteGraph,
        from start: Int,
        to goal: Int,
        profile: RiderProfile,
        strategies: [RouteStrategyType],
        avoiding primary: [RouteGraph.Edge],
        preferWiggle: Bool
    ) -> (strategy: RouteStrategyType, edges: [RouteGraph.Edge])? {
        let penalized = Set(primary.map(\.id))
        for strategy in strategies {
            let costModel = RoutingCostModel(profile: profile, strategy: strategy, preferWiggle: preferWiggle)
            guard let edges = shortestPath(
                in: graph, from: start, to: goal,
                costModel: costModel, penalizing: penalized
            ), !edges.isEmpty else { continue }

            let edgeSet = Set(edges.map(\.id))
            let union = penalized.union(edgeSet).count
            guard union > 0 else { continue }
            let overlap = Double(penalized.intersection(edgeSet).count) / Double(union)
            if overlap < duplicateOverlapThreshold {
                return (strategy, edges)
            }
        }
        return nil
    }

    private func shortestPath(
        in graph: RouteGraph,
        from start: Int,
        to goal: Int,
        costModel: RoutingCostModel,
        penalizing penalized: Set<Int> = []
    ) -> [RouteGraph.Edge]? {
        guard let goalNode = graph.node(goal) else { return nil }
        guard start != goal else { return [] }

        var open = BinaryHeap()
        var gScore: [Int: Double] = [start: 0]
        var cameFrom: [Int: RouteGraph.Edge] = [:]
        var closed = Set<Int>()

        open.push(nodeID: start, priority: 0)

        while let current = open.pop() {
            if current == goal { break }
            guard closed.insert(current).inserted else { continue }
            let currentG = gScore[current] ?? .infinity

            for edge in graph.outgoingEdges(from: current) where !closed.contains(edge.to) {
                var edgeCost = costModel.cost(of: edge)
                if penalized.contains(edge.id) {
                    edgeCost *= alternativePenaltyFactor
                }
                let tentative = currentG + edgeCost
                if tentative < (gScore[edge.to] ?? .infinity) {
                    gScore[edge.to] = tentative
                    cameFrom[edge.to] = edge
                    let remaining = GeoMath.distanceMeters(
                        from: graph.node(edge.to)?.coordinate.clCoordinate
                            ?? goalNode.coordinate.clCoordinate,
                        to: goalNode.coordinate.clCoordinate
                    )
                    open.push(
                        nodeID: edge.to,
                        priority: tentative + costModel.heuristicCost(distanceMeters: remaining)
                    )
                }
            }
        }

        guard cameFrom[goal] != nil else { return nil }
        var path: [RouteGraph.Edge] = []
        var cursor = goal
        while cursor != start, let edge = cameFrom[cursor] {
            path.append(edge)
            cursor = edge.from
        }
        return path.reversed()
    }

    // MARK: Candidate hygiene

    private func deduplicate(
        _ paths: [(strategy: RouteStrategyType, edges: [RouteGraph.Edge])]
    ) -> [(strategy: RouteStrategyType, edges: [RouteGraph.Edge])] {
        var kept: [(strategy: RouteStrategyType, edges: [RouteGraph.Edge])] = []
        var keptEdgeSets: [Set<Int>] = []

        for path in paths {
            let edgeSet = Set(path.edges.map(\.id))
            let isDuplicate = keptEdgeSets.contains { existing in
                let union = existing.union(edgeSet).count
                guard union > 0 else { return true }
                return Double(existing.intersection(edgeSet).count) / Double(union)
                    >= duplicateOverlapThreshold
            }
            if !isDuplicate {
                kept.append(path)
                keptEdgeSets.append(edgeSet)
            }
        }
        return kept
    }

    private func capDetours(_ candidates: [RouteCandidate]) -> [RouteCandidate] {
        guard let shortest = candidates.map(\.totalDistanceMeters).min(),
              shortest > 0 else { return candidates }
        let capped = candidates.filter {
            $0.totalDistanceMeters <= shortest * maxDetourFactor
        }
        return capped.isEmpty ? candidates : capped
    }
}

/// Minimal binary min-heap keyed by f-score for A*'s open set.
private struct BinaryHeap {
    private var storage: [(nodeID: Int, priority: Double)] = []

    mutating func push(nodeID: Int, priority: Double) {
        storage.append((nodeID, priority))
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard storage[child].priority < storage[parent].priority else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Int? {
        guard let top = storage.first else { return nil }
        storage.swapAt(0, storage.count - 1)
        storage.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < storage.count, storage[left].priority < storage[smallest].priority {
                smallest = left
            }
            if right < storage.count, storage[right].priority < storage[smallest].priority {
                smallest = right
            }
            guard smallest != parent else { break }
            storage.swapAt(parent, smallest)
            parent = smallest
        }
        return top.nodeID
    }
}
