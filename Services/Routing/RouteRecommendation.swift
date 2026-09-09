import Foundation

/// Picks the best-fit candidate for a rider profile.
///
/// The previous behavior was a hardcoded `strategyType == .balanced`
/// recommendation, which ignored the rider's `hillTolerance` and
/// `safetyPreference` entirely. A user who set "Avoid hills" in Settings
/// still saw Balanced (which is hill-neutral) wearing the Recommended
/// badge, and a user who set "Bring on the climbs" was steered away
/// from the genuinely fastest option.
///
/// This replaces that with a weighted blend over the candidates,
/// respecting "sacrifice a few minutes for a less steep ride" — when a
/// meaningfully flatter route exists at up to ~15% extra time, prefer it
/// for `hillTolerance: .low`; for `.high`, just pick the fastest.
enum RouteRecommendation {
    /// Returns the recommended candidate's id, or nil if candidates is empty.
    /// Multiple candidates with the same id can't happen, but if two candidates
    /// tie on the score, returns the one that appears first in the input.
    static func recommendedID(in candidates: [RouteCandidate], for profile: RiderProfile) -> UUID? {
        guard !candidates.isEmpty else { return nil }
        if candidates.count == 1 { return candidates.first?.id }

        let weights = weights(for: profile)
        let fastestETA = candidates.map(\.etaSeconds).min() ?? 0
        // Cap the time sacrifice: if the lowest-score candidate is more
        // than this fraction slower than the fastest, it stops being
        // "sacrifice a few minutes" and starts being "sacrifice half an
        // hour." Beyond that point, prefer the fastest.
        let maxTimeSacrificeFraction = 0.15

        let scored: [(UUID, Double)] = candidates.map { candidate in
            let hillBurden = hillBurdenScore(candidate)
            let timeBurden = timeBurdenScore(candidate, fastestETA: fastestETA)
            let composite = weights.hill * hillBurden + weights.time * timeBurden
            return (candidate.id, composite)
        }

        let sortedByScore = scored.sorted { $0.1 < $1.1 }
        let bestID = sortedByScore.first?.0
        let bestETA = candidates.first { $0.id == bestID }?.etaSeconds ?? 0

        // If the best-by-score candidate is too slow vs the fastest option,
        // fall back to whichever candidate has the lowest ETA. This honors
        // the "few minutes sacrifice" ceiling for hill-avoidant profiles
        // without forcing the user onto a route that's significantly longer.
        if fastestETA > 0, bestETA > fastestETA * (1 + maxTimeSacrificeFraction) {
            return candidates.min(by: { $0.etaSeconds < $1.etaSeconds })?.id
        }
        return bestID
    }

    /// Lower is better. Combines max grade (steep hills hurt disproportionately
    /// on SF terrain) with total accumulated climb (long grinding climbs).
    /// Each is normalized to a 0...1-ish band across the candidate set so
    /// the composite score stays bounded.
    private static func hillBurdenScore(_ candidate: RouteCandidate) -> Double {
        // 0...25% grade normalized: 8% = 0.32, 25% = 1.0
        let gradeComponent = min(1.0, candidate.maxGrade / 0.25)
        // 0...200m climb normalized: 100m = 0.5, 200m = 1.0
        let gainComponent = min(1.0, candidate.totalElevationGainMeters / 200.0)
        // Steep-pitch term weighted higher than accumulated climb — a single
        // 18% block hurts more than 100m of gentle 5%, matching how riders
        // experience it.
        return 0.65 * gradeComponent + 0.35 * gainComponent
    }

    /// Lower is better. 1.0 = fastest option, higher = slower. Normalizing
    /// against the fastest keeps the score bounded and makes the hill/time
    /// blend interpretable.
    private static func timeBurdenScore(_ candidate: RouteCandidate, fastestETA: Double) -> Double {
        guard fastestETA > 0 else { return 1.0 }
        return candidate.etaSeconds / fastestETA
    }

    /// Weights for the hill/time blend, derived from the rider's profile.
    /// `.low` hill tolerance gets a strong hill weight so a flatter route
    /// wins even when modestly slower; `.high` gets a near-pure time
    /// blend so the fastest option wins. `safetyPreference` boosts the
    /// hill weight slightly (avoiding hills often means quieter streets
    /// with better bike infra, so the two preferences reinforce each other
    /// for low-tolerance/high-safety riders).
    private struct Weights {
        let hill: Double
        let time: Double
    }

    private static func weights(for profile: RiderProfile) -> Weights {
        let hillBase: Double
        switch profile.hillTolerance {
        case .low: hillBase = 0.70
        case .moderate: hillBase = 0.40
        case .high: hillBase = 0.10
        }
        // Safety preference pushes the hill weight up modestly: avoiding
        // hills often correlates with using calmer streets, so a
        // hill-avoidant rider who also wants protection will weight hills
        // even more.
        let safetyBonus: Double
        switch profile.safetyPreference {
        case .low: safetyBonus = -0.05
        case .moderate: safetyBonus = 0
        case .high: safetyBonus = 0.10
        }
        let hill = min(0.85, max(0.05, hillBase + safetyBonus))
        return Weights(hill: hill, time: 1.0 - hill)
    }
}

extension Array where Element == RouteCandidate {
    /// Convenience accessor used by views that need to know which candidate
    /// is the recommendation for the current rider profile.
    func recommendedID(for profile: RiderProfile) -> UUID? {
        RouteRecommendation.recommendedID(in: self, for: profile)
    }

    /// Convenience accessor for the inverse: "is this the recommended one?"
    func isRecommended(_ candidate: RouteCandidate, for profile: RiderProfile) -> Bool {
        guard let recommendedID = RouteRecommendation.recommendedID(in: self, for: profile) else {
            return false
        }
        return recommendedID == candidate.id
    }
}
