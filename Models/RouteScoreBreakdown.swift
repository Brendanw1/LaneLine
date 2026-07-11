import Foundation

// MARK: - RouteScoreBreakdown

struct RouteScoreBreakdown: Codable, Equatable {
    var travelTimeScore: Double
    var climbPenalty: Double
    var maxGradePenalty: Double
    var protectedLaneBonus: Double
    var bikeLaneBonus: Double
    var offStreetBonus: Double
    var arterialPenalty: Double
    var roughSurfacePenalty: Double
    var crossingPenalty: Double
    var detourPenalty: Double
    var descentPenalty: Double

    /// Final weighted aggregate score (higher is better)
    var finalScore: Double {
        return travelTimeScore
            - climbPenalty
            - maxGradePenalty
            + protectedLaneBonus
            + bikeLaneBonus
            + offStreetBonus
            - arterialPenalty
            - roughSurfacePenalty
            - crossingPenalty
            - detourPenalty
            - descentPenalty
    }

    /// Human-readable breakdown of the score
    var description: String {
        var parts: [String] = []

        if travelTimeScore > 0 { parts.append("Travel time: +\(format(travelTimeScore))") }
        if climbPenalty > 0 { parts.append("Climbing: -\(format(climbPenalty))") }
        if maxGradePenalty > 0 { parts.append("Max grade: -\(format(maxGradePenalty))") }
        if protectedLaneBonus > 0 { parts.append("Protected lanes: +\(format(protectedLaneBonus))") }
        if bikeLaneBonus > 0 { parts.append("Bike lanes: +\(format(bikeLaneBonus))") }
        if offStreetBonus > 0 { parts.append("Off-street: +\(format(offStreetBonus))") }
        if arterialPenalty > 0 { parts.append("Arterial roads: -\(format(arterialPenalty))") }
        if roughSurfacePenalty > 0 { parts.append("Rough surface: -\(format(roughSurfacePenalty))") }
        if crossingPenalty > 0 { parts.append("Crossings: -\(format(crossingPenalty))") }
        if detourPenalty > 0 { parts.append("Detour: -\(format(detourPenalty))") }
        if descentPenalty > 0 { parts.append("Descent: -\(format(descentPenalty))") }

        return parts.joined(separator: "\n")
    }

    private func format(_ value: Double) -> String {
        return String(format: "%.1f", value)
    }
}
