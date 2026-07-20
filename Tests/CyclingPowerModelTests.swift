import XCTest
@testable import LaneLine

final class CyclingPowerModelTests: XCTestCase {
    // 20 km/h on the flat, 75 kg rider on a road bike: rolling + aero only,
    // should land in the easy-spin band.
    func testFlatCruisePowerIsPlausible() {
        let watts = CyclingPowerModel.mechanicalWatts(
            speedMs: 20 / 3.6, gradeDecimal: 0, riderKg: 75, bikeType: .roadBike
        )
        XCTAssertGreaterThan(watts, 40)
        XCTAssertLessThan(watts, 80)
    }

    // 8 km/h up an 8% grade: climbing power dominates.
    func testClimbingPowerIsPlausible() {
        let watts = CyclingPowerModel.mechanicalWatts(
            speedMs: 8 / 3.6, gradeDecimal: 0.08, riderKg: 75, bikeType: .roadBike
        )
        XCTAssertGreaterThan(watts, 120)
        XCTAssertLessThan(watts, 220)
    }

    // Steep descent demands no pedaling.
    func testDescendingPowerIsZero() {
        let watts = CyclingPowerModel.mechanicalWatts(
            speedMs: 30 / 3.6, gradeDecimal: -0.08, riderKg: 75, bikeType: .roadBike
        )
        XCTAssertEqual(watts, 0)
    }

    // The motor shoulders half the load on an e-bike.
    func testEBikeRiderPowerIsBelowCityBike() {
        let ebike = CyclingPowerModel.mechanicalWatts(
            speedMs: 20 / 3.6, gradeDecimal: 0, riderKg: 75, bikeType: .eBike
        )
        let city = CyclingPowerModel.mechanicalWatts(
            speedMs: 20 / 3.6, gradeDecimal: 0, riderKg: 75, bikeType: .cityBike
        )
        XCTAssertLessThan(ebike, city * 0.7)
    }

    // ~1 kJ of mechanical work ≈ 1 kcal metabolic (the classic cycling rule).
    func testKilocalorieConversion() {
        XCTAssertEqual(CyclingPowerModel.kilocalories(mechanicalJoules: 1004.16), 1, accuracy: 0.01)
    }

    // Profiles saved before weightKg existed must decode with the default.
    func testLegacyProfileDecodesWithDefaultWeight() throws {
        let legacy = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"B","bikeType":"roadBike",
         "hillTolerance":"moderate","safetyPreference":"moderate",
         "directnessPreference":"balanced","surfaceSensitivity":"moderate",
         "appleMusicEnabled":false}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(RiderProfile.self, from: legacy)
        XCTAssertEqual(profile.weightKg, 75)
        XCTAssertEqual(profile.name, "B")
    }

    func testProfileWeightRoundTrips() throws {
        var profile = RiderProfile()
        profile.weightKg = 82
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(RiderProfile.self, from: data)
        XCTAssertEqual(decoded.weightKg, 82)
    }
}
