import Foundation

/// Turns route metrics into the plain-language reasons, tradeoffs, and
/// preference hints the product promises. Works purely off computed metrics —
/// never invents claims the numbers don't support.
struct RouteExplanationBuilder {
    /// Populates `recommendationReason` and `cautionNotes` for each candidate
    /// in the context of its alternatives.
    func annotate(
        _ candidates: [RouteCandidate],
        profile: RiderProfile
    ) -> [RouteCandidate] {
        candidates.map { candidate in
            var annotated = candidate
            annotated.recommendationReason = reason(for: candidate, among: candidates, profile: profile)
            annotated.cautionNotes = cautions(for: candidate, among: candidates)
            return annotated
        }
    }

    /// The "why this route" paragraph plus how-to-change-it hint shown on the
    /// detail screen.
    func detailExplanation(for candidate: RouteCandidate, profile: RiderProfile) -> String {
        var sentences: [String] = [candidate.recommendationReason]

        let hardSegments = candidate.segments.filter { $0.maxGrade > 0.08 }
        if let hardest = hardSegments.max(by: { $0.maxGrade < $1.maxGrade }) {
            let name = hardest.streetName ?? "one stretch"
            sentences.append(
                "The toughest part is \(name), which peaks at \(RideFormat.grade(hardest.maxGrade))."
            )
        } else {
            sentences.append("No segment exceeds an 8% grade.")
        }

        let stressful = candidate.segments.filter { $0.segmentStressScore > 0.55 }
        if let worst = stressful.max(by: { $0.segmentStressScore < $1.segmentStressScore }) {
            sentences.append(
                "Expect heavier traffic on \(worst.streetName ?? "a short connector") — there's no bike facility there."
            )
        }

        sentences.append(preferenceHint(for: candidate, profile: profile))
        return sentences.joined(separator: " ")
    }

    // MARK: Reasons

    private func reason(
        for candidate: RouteCandidate,
        among candidates: [RouteCandidate],
        profile: RiderProfile
    ) -> String {
        switch candidate.strategyType {
        case .balanced:
            return balancedReason(candidate, among: candidates, profile: profile)
        case .safer:
            return "Maximizes separation from traffic: \(RideFormat.percent(candidate.protectedLanePercent)) "
                + "of the ride is on protected lanes or paths"
                + comparativeSuffix(candidate, among: candidates)
        case .faster:
            return "The most direct option — \(RideFormat.duration(candidate.etaSeconds)) and "
                + "\(RideFormat.distance(candidate.totalDistanceMeters)), trading some calmer streets for time."
        case .easierClimbing:
            return "The gentlest climb profile: \(RideFormat.elevation(candidate.totalElevationGainMeters)) of "
                + "total gain with nothing steeper than \(RideFormat.grade(candidate.maxGrade))."
        }
    }

    private func balancedReason(
        _ candidate: RouteCandidate,
        among candidates: [RouteCandidate],
        profile: RiderProfile
    ) -> String {
        var parts: [String] = []
        parts.append(
            "Best overall fit for your \(bikeName(profile.bikeType)): "
            + "\(RideFormat.percent(candidate.bikeFacilityPercent)) on bike infrastructure"
        )
        if let fastest = candidates.first(where: { $0.strategyType == .faster }),
           fastest.id != candidate.id {
            let extra = candidate.etaSeconds - fastest.etaSeconds
            if extra > 45 {
                parts.append(
                    "about \(RideFormat.duration(extra)) slower than the direct option, "
                    + "in exchange for calmer streets and less climbing"
                )
            } else {
                parts.append("with essentially no time penalty versus the direct option")
            }
        }
        return parts.joined(separator: ", ") + "."
    }

    private func comparativeSuffix(
        _ candidate: RouteCandidate,
        among candidates: [RouteCandidate]
    ) -> String {
        guard let fastest = candidates.first(where: { $0.strategyType == .faster }),
              fastest.id != candidate.id, fastest.etaSeconds > 0 else { return "." }
        let extraFraction = (candidate.etaSeconds - fastest.etaSeconds) / fastest.etaSeconds
        guard extraFraction > 0.03 else { return "." }
        return ", about \(Int((extraFraction * 100).rounded()))% slower than the direct route."
    }

    // MARK: Cautions

    private func cautions(
        for candidate: RouteCandidate,
        among candidates: [RouteCandidate]
    ) -> [String] {
        var notes: [String] = []

        for segment in candidate.segments where segment.maxGrade > 0.08 {
            notes.append(
                "\(segment.streetName ?? "One segment") climbs at up to \(RideFormat.grade(segment.maxGrade))."
            )
        }

        let unprotected = candidate.segments.filter {
            $0.segmentStressScore > 0.55 && $0.lengthMeters > 150
        }
        for segment in unprotected.prefix(2) {
            notes.append(
                "\(segment.streetName ?? "A connector") carries heavier traffic with no protected lane."
            )
        }

        for segment in candidate.segments
        where segment.intersectionStressScore > 0.7 && segment.turnType != .straight {
            notes.append(
                "Busy crossing where you turn onto \(segment.streetName ?? "the next street")."
            )
        }

        if let shortest = candidates.min(by: { $0.totalDistanceMeters < $1.totalDistanceMeters }),
           shortest.id != candidate.id, shortest.totalDistanceMeters > 0 {
            let detour = candidate.totalDistanceMeters / shortest.totalDistanceMeters - 1
            if detour > 0.12 {
                notes.append("About \(Int((detour * 100).rounded()))% longer than the shortest option.")
            }
        }

        if candidate.confidenceScore < 0.7 {
            notes.append("Parts of this route have incomplete surface or lane data.")
        }

        return Array(notes.prefix(4))
    }

    // MARK: Preference hints

    private func preferenceHint(for candidate: RouteCandidate, profile: RiderProfile) -> String {
        if candidate.totalElevationGainMeters > 60 && profile.hillTolerance != .low {
            return "Prefer a flatter ride? Lower your hill tolerance in Settings and LaneLine will trade distance for grade."
        }
        if candidate.routeStressScore > 0.45 && profile.safetyPreference != .high {
            return "Raising your safety preference in Settings will weight protected lanes even harder."
        }
        if candidate.directnessScore < 0.7 && profile.directnessPreference != .direct {
            return "If this feels like a detour, set directness to \u{201C}direct\u{201D} in Settings for straighter routes."
        }
        return "Tune bike type, hill tolerance, and safety preference in Settings to reshape these routes."
    }

    private func bikeName(_ bikeType: BikeType) -> String {
        switch bikeType {
        case .roadBike: return "road bike"
        case .hybridFitness: return "hybrid"
        case .gravel: return "gravel bike"
        case .cityBike: return "city bike"
        case .eBike: return "e-bike"
        }
    }
}
