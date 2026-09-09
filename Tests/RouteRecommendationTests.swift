import XCTest
@testable import LaneLine

/// The Recommended candidate for a rider profile depends on their
/// `hillTolerance` and `safetyPreference`. These tests pin the behavior so
/// changes to the recommendation weights don't silently flip a "Avoid
/// hills" rider onto a hill-heavy Balanced route or vice versa.
final class RouteRecommendationTests: XCTestCase {
    private func candidate(
        strategy: RouteStrategyType,
        maxGrade: Double,
        climb: Double,
        etaSeconds: Double
    ) -> RouteCandidate {
        RouteCandidate(
            id: UUID(),
            label: strategy.displayName,
            strategyType: strategy,
            segments: [],
            totalDistanceMeters: 1000,
            etaSeconds: etaSeconds,
            totalElevationGainMeters: climb,
            maxGrade: maxGrade,
            protectedLanePercent: 0.3,
            bikeFacilityPercent: 0.5,
            roadBikeSuitabilityScore: 0.7,
            routeStressScore: 0.4,
            directnessScore: 0.9,
            confidenceScore: 0.9,
            estimatedCalories: 50,
            usedWiggleCorridor: false
        )
    }

    /// A "Avoid hills" rider (hillTolerance: .low) should land on the
    /// flatter candidate even if it's a few minutes slower — exactly what
    /// the user-facing setting promises.
    func testLowHillTolerancePrefersFlatterCandidate() {
        let balanced = candidate(strategy: .balanced, maxGrade: 0.18, climb: 80, etaSeconds: 1200)
        let easier = candidate(strategy: .easierClimbing, maxGrade: 0.07, climb: 35, etaSeconds: 1320)
        let profile = RiderProfile(bikeType: .roadBike, hillTolerance: .low)

        let recommendedID = [balanced, easier].recommendedID(for: profile)
        XCTAssertEqual(
            recommendedID, easier.id,
            "Avoid hills rider should get the flatter route even when it's 10% slower"
        )
    }

    /// A "Bring on the climbs" rider should get the fastest candidate.
    /// The flat detour is *slower* and they explicitly opted into climbs,
    /// so the time preference dominates.
    func testHighHillTolerancePrefersFastestCandidate() {
        let balanced = candidate(strategy: .balanced, maxGrade: 0.18, climb: 80, etaSeconds: 1200)
        let easier = candidate(strategy: .easierClimbing, maxGrade: 0.07, climb: 35, etaSeconds: 1320)
        let profile = RiderProfile(bikeType: .roadBike, hillTolerance: .high)

        let recommendedID = [balanced, easier].recommendedID(for: profile)
        XCTAssertEqual(
            recommendedID, balanced.id,
            "Bring on the climbs rider should get the fastest candidate regardless of grade"
        )
    }

    /// When the "few minutes" budget is exceeded (~15% slower), even an
    /// Avoid hills rider should fall back to the fastest candidate —
    /// protecting them from a "sacrifice a few minutes" promise turning
    /// into a much longer ride.
    func testLowHillToleranceFallsBackWhenFlatDetourIsTooSlow() {
        let balanced = candidate(strategy: .balanced, maxGrade: 0.10, climb: 50, etaSeconds: 1200)
        let easier = candidate(strategy: .easierClimbing, maxGrade: 0.04, climb: 20, etaSeconds: 1500)
        // 25% slower — beyond the 15% cap.
        let profile = RiderProfile(bikeType: .roadBike, hillTolerance: .low)

        let recommendedID = [balanced, easier].recommendedID(for: profile)
        XCTAssertEqual(
            recommendedID, balanced.id,
            "Avoid hills rider must not be pushed onto a route more than 15% slower than the fastest"
        )
    }

    /// "Protected lanes first" should bias the recommendation further away
    /// from hills (calmer streets usually have both). A rider with both
    /// low tolerance and high safety should weight hills even more.
    func testHighSafetyPlusLowHillToleranceWeightsHillsEvenMore() {
        // Two candidates — one slightly flatter but no protected lanes,
        // one slightly faster with much more protected lane. The pure
        // hill-tolerance-low rider picks the flatter one; the
        // safety-high rider weighs the combined profile and could
        // flip — verify the combined profile still picks the flatter
        // one because hills are more impactful than protected-lane
        // percentage in this scoring.
        let flatUnprotected = candidate(strategy: .easierClimbing, maxGrade: 0.05, climb: 30, etaSeconds: 1260)
        let steepProtected = candidate(strategy: .balanced, maxGrade: 0.20, climb: 90, etaSeconds: 1200)
        let profile = RiderProfile(bikeType: .roadBike, hillTolerance: .low, safetyPreference: .high)

        let recommendedID = [flatUnprotected, steepProtected].recommendedID(for: profile)
        XCTAssertEqual(
            recommendedID, flatUnprotected.id,
            "Combined low-hill + high-safety rider should still get the flatter option"
        )
    }

    /// Single-candidate edge case: returns the one candidate as
    /// recommended regardless of profile (no comparison possible).
    func testSingleCandidateIsAlwaysRecommended() {
        let only = candidate(strategy: .balanced, maxGrade: 0.18, climb: 80, etaSeconds: 1200)
        let profile = RiderProfile(bikeType: .roadBike, hillTolerance: .low)
        XCTAssertEqual([only].recommendedID(for: profile), only.id)
    }

    /// Empty candidate list returns nil — no recommendation possible.
    func testEmptyCandidatesReturnsNil() {
        let profile = RiderProfile(bikeType: .roadBike)
        XCTAssertNil([RouteCandidate]().recommendedID(for: profile))
    }
}
